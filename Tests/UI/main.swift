import AppKit
import Darwin

// This executable deliberately excludes Sources/main.swift and FinderLayout.swift.
// Its desktop, journal and observation file all live beside the temporary app.
final class PreviewLayout: LayoutProvider {
    private var positions: [String: DesktopPoint] = [
        "样例文稿.txt": .init(x: 100, y: 120),
        "样例图片.txt": .init(x: 260, y: 120),
        "样例文件夹": .init(x: 420, y: 120)
    ]

    func snapshot(names: [String]) throws -> DesktopLayout {
        var requested: [String: DesktopPoint] = [:]
        for name in names {
            if positions[name] == nil { positions[name] = .init(x: 100 + positions.count * 120, y: 300) }
            requested[name] = positions[name]
        }
        return .init(arrangement: "narr", configuration: "isolated-ui-preview", positions: requested)
    }

    func setPositions(_ changed: [String: DesktopPoint], expected: DesktopLayout) throws {
        guard expected.arrangement == "narr", expected.configuration == "isolated-ui-preview" else {
            throw PrivacyError("隔离预览布局不匹配。")
        }
        positions.merge(changed) { _, new in new }
    }

    func refresh() throws {}
    func checkVisibilitySettings() throws {}
}

final class ObservedPreviewService: PrivacyService {
    let wrapped: DesktopPrivacyService
    let root: URL
    let desktop: URL
    private var operation = 0

    var presentation: PrivacyPresentation { wrapped.presentation }

    init(wrapped: DesktopPrivacyService, root: URL, desktop: URL) {
        self.wrapped = wrapped; self.root = root; self.desktop = desktop
    }

    private func record(_ name: String, action: () throws -> Void) throws {
        operation += 1
        do {
            try action()
            try observe(name, error: nil)
        } catch {
            try? observe(name, error: error.localizedDescription)
            throw error
        }
    }

    private func observe(_ name: String, error: String?) throws {
        let state = presentation
        let items = try FileManager.default.contentsOfDirectory(atPath: desktop.path).sorted().map { name -> [String: Any] in
            var info = stat()
            guard lstat(desktop.appendingPathComponent(name).path, &info) == 0 else {
                throw PrivacyError("无法读取隔离样例文件。")
            }
            return ["name": name, "hidden": info.st_flags & UInt32(UF_HIDDEN) != 0,
                    "inode": info.st_ino, "flags": info.st_flags]
        }
        var observation: [String: Any] = [
            "operationNumber": operation, "operation": name,
            "mode": String(describing: state.mode), "count": state.count,
            "manualNames": state.names, "items": items,
            "scope": state.scope?.rawValue ?? "none",
            "recoveryExists": FileManager.default.fileExists(atPath: root.appendingPathComponent("State/recovery.json").path),
            "usesRealDesktop": false, "usesFinder": false
        ]
        if let error { observation["error"] = error }
        try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("observation.json"), options: .atomic)
    }

    func initialize() throws { try record("initialize") { try wrapped.initialize() } }
    func hide() throws { try record("hideSelected") { try wrapped.hide() } }
    func hideAll() throws { try record("hideAll") { try wrapped.hideAll() } }
    func restore() throws { try record("restore") { try wrapped.restore() } }
    func validate() throws { try record("validate") { try wrapped.validate() } }
    func addTargets(_ urls: [URL]) throws { try record("addTargets") { try wrapped.addTargets(urls) } }
    func removeTargets(named names: [String]) throws { try record("removeTargets") { try wrapped.removeTargets(named: names) } }
}

private func identity(_ url: URL) throws -> FileIdentity {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw PrivacyError("隔离样例文件不存在。") }
    return FileIdentity(info)
}

@MainActor private func launchPreview() throws {
    let fileManager = FileManager.default
    let root = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    let temporary = fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard Bundle.main.bundleIdentifier == "io.github.jayzengcodetrip.desktop-privacy.ui-preview",
          root.deletingLastPathComponent() == temporary,
          root.lastPathComponent.hasPrefix("desktop-privacy-ui."),
          fileManager.fileExists(atPath: root.appendingPathComponent(".isolated-ui-fixture").path) else {
        throw PrivacyError("UI 预览只能从脚本建立的独立临时目录运行。")
    }
    let desktop = root.appendingPathComponent("FakeDesktop", isDirectory: true)
    let data = root.appendingPathComponent("State", isDirectory: true)
    if !fileManager.fileExists(atPath: desktop.path) {
        guard !fileManager.fileExists(atPath: data.path) else { throw PrivacyError("隔离桌面缺失；请重新构建预览。") }
        try fileManager.createDirectory(at: desktop.appendingPathComponent("样例文件夹"), withIntermediateDirectories: true)
        try Data("synthetic document\n".utf8).write(to: desktop.appendingPathComponent("样例文稿.txt"))
        try Data("synthetic image placeholder\n".utf8).write(to: desktop.appendingPathComponent("样例图片.txt"))
        try Data("nested content stays untouched\n".utf8).write(to: desktop.appendingPathComponent("样例文件夹/内部样例.txt"))
    }
    let manifest = FixedManifest(schema: 1, desktop: desktop.path, desktopIdentity: try identity(desktop),
                                 targets: [.init(name: "样例文稿.txt", identity: try identity(desktop.appendingPathComponent("样例文稿.txt")))])
    let wrapped = DesktopPrivacyService(manifest: manifest, dataRoot: data, layout: PreviewLayout())
    let service = ObservedPreviewService(wrapped: wrapped, root: root, desktop: desktop)
    let app = NSApplication.shared
    let delegate = PrivacyAppDelegate(service: service, desktopURL: desktop)
    app.delegate = delegate
    DispatchQueue.main.async {
        for window in app.windows where window.title == AppConfiguration.displayName {
            window.title = AppConfiguration.displayName + " · 隔离 UI 测试"
        }
    }
    app.run()
    withExtendedLifetime(delegate) {}
}

MainActor.assumeIsolated {
    do { try launchPreview() }
    catch {
        fputs("Isolated UI preview failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
