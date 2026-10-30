import Foundation
import Darwin

enum PrivacyMode: Equatable { case visible, hidden, recovery, blocked }
struct PrivacyPresentation {
    let mode: PrivacyMode
    let count: Int
    let names: [String]
    let detail: String
}
protocol PrivacyService: AnyObject {
    var presentation: PrivacyPresentation { get }
    func initialize() throws
    func hide() throws
    func restore() throws
    func validate() throws
    func addTargets(_ urls: [URL]) throws
    func removeTargets(named: [String]) throws
}
struct PrivacyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct FileIdentity: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino
        birthSeconds = Int64(s.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(s.st_birthtimespec.tv_nsec)
    }
}
struct TargetFile: Codable { let name: String; let identity: FileIdentity }
struct FixedManifest: Codable {
    let schema: Int
    let desktop: String
    let desktopIdentity: FileIdentity
    let targets: [TargetFile]
}
struct DesktopPoint: Codable, Equatable { let x: Int; let y: Int }
struct DesktopLayout: Codable {
    let arrangement: String
    let configuration: String
    let positions: [String: DesktopPoint]
}
protocol LayoutProvider {
    func snapshot(names: [String]) throws -> DesktopLayout
    func setPositions(_ positions: [String: DesktopPoint], expected: DesktopLayout) throws
    func refresh() throws
    func checkVisibilitySettings() throws
    func setPositionsSafely(_ placements: [VerifiedPlacement], expected: DesktopLayout) throws
}
struct VerifiedPlacement {
    let name: String
    let identity: FileIdentity
    let position: DesktopPoint
    let desktop: String
}
extension LayoutProvider {
    func setPositionsSafely(_ placements: [VerifiedPlacement], expected: DesktopLayout) throws {
        try setPositions(Dictionary(uniqueKeysWithValues: placements.map { ($0.name, $0.position) }), expected: expected)
    }
}
struct SavedTarget: Codable {
    let target: TargetFile
    let originalFlags: UInt32
    let position: DesktopPoint
}
struct RecoverySession: Codable {
    let schema: Int
    let created: Date
    var phase: String
    let layout: DesktopLayout
    let targets: [SavedTarget]
    let observers: [SavedObserver]
    var restoreObservers: [SavedObserver]?
    var rollback: Bool
}
struct SavedObserver: Codable { let target: TargetFile; let position: DesktopPoint }
struct DiskItem {
    let name: String
    let identity: FileIdentity
    let flags: UInt32
    let mode: mode_t
}

final class DesktopPrivacyService: PrivacyService {
    private(set) var manifest: FixedManifest
    let dataRoot: URL
    let layout: any LayoutProvider
    private var session: RecoverySession?
    private var ready = false
    private var detail = "固定名单内的文件会临时隐藏，其他文件保持原样。"
    // Injection is used only by isolated tests, never by the app.
    var afterFlagChangeForTest: ((Int) throws -> Void)?
    private var stateURL: URL { dataRoot.appendingPathComponent("recovery.json") }
    var presentation: PrivacyPresentation {
        let mode: PrivacyMode = !ready ? .blocked : (session == nil ? .visible : (session!.phase == "hidden" ? .hidden : .recovery))
        return .init(mode: mode, count: manifest.targets.count, names: manifest.targets.map(\.name), detail: detail)
    }
    init(manifest: FixedManifest, dataRoot: URL, layout: any LayoutProvider) {
        self.manifest = manifest; self.dataRoot = dataRoot; self.layout = layout
    }
    func initialize() throws {
        do {
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try locked {
                let storedManifest = dataRoot.appendingPathComponent("manifest.json")
                if FileManager.default.fileExists(atPath: storedManifest.path) {
                    let loaded = try JSONDecoder().decode(FixedManifest.self, from: Data(contentsOf: storedManifest))
                    guard loaded.desktop == manifest.desktop, loaded.desktopIdentity == manifest.desktopIdentity else { throw PrivacyError("保存的名单不属于此桌面，已停止操作。") }
                    manifest = loaded
                }
                guard manifest.schema == 1,
                      Set(manifest.targets.map(\.name)).count == manifest.targets.count,
                      manifest.targets.allSatisfy({ validName($0.name) }) else { throw PrivacyError("固定名单损坏，已停止操作。") }
                try checkDesktop()
                try reloadSession()
                if !FileManager.default.fileExists(atPath: storedManifest.path) { try atomicWrite(manifest, to: storedManifest) }
                ready = true
                detail = session == nil ? "固定名单已就绪。隐藏前会保存位置，恢复后会逐项核对。" : "已找到上次保存的恢复记录，可继续恢复文件和位置。"
            }
        } catch { ready = false; detail = error.localizedDescription; throw error }
    }
    func validate() throws {
        if !ready { try initialize() }
        try locked {
            try checkDesktop(); try reloadSession()
            let items = try inventory()
            for target in manifest.targets { _ = try resolve(target, items: items) }
            if session == nil {
                try layout.checkVisibilitySettings()
                _ = try layout.snapshot(names: visibleNames(items))
            }
            detail = session == nil ? "\(manifest.targets.count) 项固定名单及桌面布局检查通过，可以隐藏。" : "恢复记录可用；点击恢复即可继续。"
        }
    }
    func hide() throws {
        guard ready else { throw PrivacyError("请先重新打开工具完成检查。") }
        try locked {
            try checkDesktop(); try reloadSession()
            guard session == nil else { throw PrivacyError("还有尚未完成的恢复记录，请先恢复。") }
            guard !manifest.targets.isEmpty else { throw PrivacyError("名单为空，请先添加要隐藏的桌面文件。") }
            try layout.checkVisibilitySettings()
            let items = try inventory()
            let resolved = try manifest.targets.map { try resolve($0, items: items) }
            guard resolved.allSatisfy({ $0.flags & UInt32(UF_HIDDEN) == 0 }) else {
                throw PrivacyError("名单中有文件已被其他方式隐藏。为避免改变原状态，请先恢复这些文件。")
            }
            let before = try layout.snapshot(names: visibleNames(items))
            guard before.arrangement == "narr" || before.arrangement == "grda" else {
                throw PrivacyError("桌面启用了自动排序。为保留布局，本工具不会改变排序设置，也不会开始隐藏。")
            }
            let saved = try resolved.map { item -> SavedTarget in
                guard let p = before.positions[item.name] else { throw PrivacyError("无法读取“\(item.name)”的位置，未隐藏任何文件。") }
                return SavedTarget(target: .init(name: item.name, identity: item.identity), originalFlags: item.flags, position: p)
            }
            let targetIDs = Set(saved.map { $0.target.identity })
            let observers = items.compactMap { item -> SavedObserver? in
                guard !targetIDs.contains(item.identity), let point = before.positions[item.name] else { return nil }
                return SavedObserver(target: .init(name: item.name, identity: item.identity), position: point)
            }
            let recovery = RecoverySession(schema: 1, created: Date(), phase: "hiding", layout: before, targets: saved, observers: observers, restoreObservers: nil, rollback: false)
            try save(recovery) // Durable journal exists before the first attribute mutation.
            do {
                for (index, item) in saved.enumerated() {
                    try setHidden(item.target, hidden: true)
                    try afterFlagChangeForTest?(index)
                }
                try layout.refresh()
                let afterItems = try inventory()
                for target in saved {
                    guard try resolve(target.target, items: afterItems).flags & UInt32(UF_HIDDEN) != 0 else { throw PrivacyError("隐藏状态校验失败。") }
                }
                let others = visibleNames(afterItems)
                let after = try layout.snapshot(names: others)
                try checkConfiguration(before, after)
                for name in others {
                    if let old = before.positions[name], after.positions[name] != old {
                        throw PrivacyError("Finder 改变了名单外项目的位置，已停止隐藏并尝试恢复。")
                    }
                }
                var completed = recovery; completed.phase = "hidden"; try save(completed)
                detail = "已隐藏 \(saved.count) 项。其他桌面文件仍然可用，位置恢复记录已保存。"
            } catch {
                let cause = error.localizedDescription
                do {
                    if var interrupted = session { interrupted.rollback = true; try save(interrupted) }
                    try restoreLocked(); detail = "隐藏未完成，已恢复：\(cause)"
                }
                catch { detail = "隐藏未完成，恢复记录已保留。\(error.localizedDescription)" }
                throw PrivacyError(detail)
            }
        }
    }
    func addTargets(_ urls: [URL]) throws {
        guard ready else { throw PrivacyError("请先完成初始化。") }
        try locked {
            try checkDesktop(); try reloadSession()
            guard session == nil else { throw PrivacyError("请先恢复当前隐藏的文件，再编辑名单。") }
            let items = try inventory()
            let desktop = URL(fileURLWithPath: manifest.desktop, isDirectory: true).standardizedFileURL
            var targets = manifest.targets
            for url in urls {
                let normalized = url.standardizedFileURL
                guard normalized.deletingLastPathComponent() == desktop, validName(normalized.lastPathComponent),
                      !normalized.lastPathComponent.hasPrefix("."),
                      let raw = items.first(where: { $0.name == normalized.lastPathComponent }) else { throw PrivacyError("只能添加桌面顶层的文件或文件夹。") }
                let item = try safeItem(raw)
                guard item.flags & UInt32(UF_HIDDEN) == 0 else { throw PrivacyError("请先让“\(item.name)”正常显示，再加入名单。") }
                guard !targets.contains(where: { $0.name == item.name && $0.identity != item.identity }) else { throw PrivacyError("名单里已有旧的“\(item.name)”。请先移除旧记录，再添加当前文件。") }
                if !targets.contains(where: { $0.identity == item.identity }) { targets.append(.init(name: item.name, identity: item.identity)) }
            }
            try replaceTargets(targets)
        }
    }
    func removeTargets(named names: [String]) throws {
        guard ready else { throw PrivacyError("请先完成初始化。") }
        try locked {
            try checkDesktop(); try reloadSession()
            guard session == nil else { throw PrivacyError("请先恢复当前隐藏的文件，再编辑名单。") }
            try replaceTargets(manifest.targets.filter { !names.contains($0.name) })
        }
    }
    private func replaceTargets(_ targets: [TargetFile]) throws {
        let changed = FixedManifest(schema: 1, desktop: manifest.desktop, desktopIdentity: manifest.desktopIdentity, targets: targets)
        try atomicWrite(changed, to: dataRoot.appendingPathComponent("manifest.json"))
        manifest = changed
        detail = "名单已保存，共 \(targets.count) 项。从名单移除不会删除真实文件。"
    }
    func restore() throws {
        guard ready else { throw PrivacyError("请重新打开工具后恢复。") }
        try locked { try checkDesktop(); try reloadSession(); try restoreLocked() }
    }
    private func restoreLocked() throws {
        guard var recovery = session else { detail = "文件已经处于显示状态。"; return }
        // A process termination does not enter hide()'s catch block. Its unfinished
        // journal must still use the pre-hide observer positions for rollback.
        if recovery.phase == "hiding" { recovery.rollback = true }
        // Check before unhiding: automatic sorting could otherwise shift unrelated icons.
        let beforeItems = try inventory()
        let beforeRestore = try layout.snapshot(names: visibleNames(beforeItems))
        try checkConfiguration(recovery.layout, beforeRestore)
        let targetIDs = Set(recovery.targets.map { $0.target.identity })
        let currentObservers: [SavedObserver] = beforeItems.compactMap { item in
            guard !targetIDs.contains(item.identity), let point = beforeRestore.positions[item.name] else { return nil }
            return SavedObserver(target: .init(name: item.name, identity: item.identity), position: point)
        }
        let pendingObservers = recovery.restoreObservers ?? (recovery.rollback ? recovery.observers : [])
        let pendingIDs = Set(pendingObservers.map { $0.target.identity })
        // Keep only genuinely unfinished repairs from an earlier attempt. All
        // other observers use their latest position at the start of this attempt.
        recovery.restoreObservers = pendingObservers + currentObservers.filter { !pendingIDs.contains($0.target.identity) }
        recovery.rollback = false
        recovery.phase = "restoring"; try save(recovery)
        var problems: [String] = []
        var restored: [(SavedTarget, DiskItem)] = []
        // Restore every resolvable original independently, even when one was moved away.
        for saved in recovery.targets {
            do {
                try setHidden(saved.target, hidden: saved.originalFlags & UInt32(UF_HIDDEN) != 0)
                restored.append((saved, try resolve(saved.target, items: inventory())))
            } catch { problems.append(error.localizedDescription) }
        }
        do { try layout.refresh() }
        catch { problems.append(error.localizedDescription) }
        do {
            let current = try layout.snapshot(names: restored.map { $0.1.name })
            try checkConfiguration(recovery.layout, current)
            var changed: [VerifiedPlacement] = []
            for (saved, _) in restored {
                let item = try resolve(saved.target, items: inventory())
                if current.positions[item.name] != saved.position {
                    changed.append(.init(name: item.name, identity: item.identity, position: saved.position, desktop: manifest.desktop))
                }
            }
            if !changed.isEmpty { try layout.setPositionsSafely(changed, expected: recovery.layout) }
            for (saved, _) in restored {
                let item = try resolve(saved.target, items: inventory())
                let verified = try layout.snapshot(names: [item.name])
                guard verified.positions[item.name] == saved.position else { throw PrivacyError("“\(item.name)”的位置尚未恢复，记录会保留，可再次点击恢复。") }
                let disk = try resolve(saved.target, items: inventory())
                guard (disk.flags & UInt32(UF_HIDDEN)) == (saved.originalFlags & UInt32(UF_HIDDEN)) else { throw PrivacyError("“\(item.name)”的显示状态尚未恢复。") }
            }
        } catch { problems.append(error.localizedDescription) }
        // Observer repair is independent of target repair. A failed target write
        // must not leave unrelated icons displaced, nor freeze an already-correct
        // observer position across retries after the user deliberately moves it.
        let observers = recovery.restoreObservers ?? []
        var unfinishedObservers: [SavedObserver] = []
        var completedObservers: [SavedObserver] = []
        for observer in observers {
            do {
                let item = try resolve(observer.target, items: inventory())
                let now = try layout.snapshot(names: [item.name])
                try checkConfiguration(recovery.layout, now)
                if now.positions[item.name] != observer.position {
                    try layout.setPositionsSafely([
                        .init(name: item.name, identity: item.identity, position: observer.position, desktop: manifest.desktop)
                    ], expected: recovery.layout)
                }
                let verifiedItem = try resolve(observer.target, items: inventory())
                let verified = try layout.snapshot(names: [verifiedItem.name])
                guard verified.positions[verifiedItem.name] == observer.position else { throw PrivacyError("名单外文件“\(verifiedItem.name)”的位置需要恢复，记录已保留。") }
                completedObservers.append(observer)
            } catch {
                unfinishedObservers.append(observer)
                problems.append(error.localizedDescription)
            }
        }
        // A later placement can affect an earlier one under some Finder layouts.
        // Retain only observers that still need repair after the complete batch.
        for observer in completedObservers {
            do {
                let item = try resolve(observer.target, items: inventory())
                let verified = try layout.snapshot(names: [item.name])
                try checkConfiguration(recovery.layout, verified)
                guard verified.positions[item.name] == observer.position else { throw PrivacyError("名单外文件“\(item.name)”的位置需要恢复，记录已保留。") }
            } catch {
                unfinishedObservers.append(observer)
                problems.append(error.localizedDescription)
            }
        }
        recovery.restoreObservers = unfinishedObservers.isEmpty ? nil : unfinishedObservers
        try save(recovery)
        guard problems.isEmpty else {
            recovery.phase = "recovery"; try save(recovery)
            detail = "恢复尚未全部完成，记录已保留。\n" + problems.joined(separator: "\n")
            throw PrivacyError(detail)
        }
        recovery.phase = "restored"
        try atomicWrite(recovery, to: dataRoot.appendingPathComponent("last-restored.json"))
        try FileManager.default.removeItem(at: stateURL)
        syncDirectory(dataRoot)
        session = nil
        detail = "已恢复 \(restored.count) 项，逐项确认位置与隐藏前一致。"
    }
    private func checkConfiguration(_ a: DesktopLayout, _ b: DesktopLayout) throws {
        guard a.arrangement == b.arrangement, a.configuration == b.configuration else {
            throw PrivacyError("显示器、分辨率或桌面显示设置发生了变化。文件可恢复显示，但请还原录制前的显示设置，再点击恢复以核对原位置。")
        }
    }
    private func reloadSession() throws {
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let loaded = try JSONDecoder().decode(RecoverySession.self, from: Data(contentsOf: stateURL))
            guard loaded.schema == 1, loaded.targets.count == manifest.targets.count,
                  Set(loaded.targets.map { $0.target.identity }).count == manifest.targets.count,
                  loaded.targets.allSatisfy({ s in manifest.targets.contains { $0.identity == s.target.identity } && validName(s.target.name) }) else {
                throw PrivacyError("恢复记录与固定名单不符，已停止操作，未改动文件。")
            }
            session = loaded
        } else { session = nil }
    }
    private func save(_ value: RecoverySession) throws { try atomicWrite(value, to: stateURL); session = value }
    private func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") }
    private func checkDesktop() throws {
        var s = stat()
        guard lstat(manifest.desktop, &s) == 0, s.st_mode & S_IFMT == S_IFDIR,
              FileIdentity(s) == manifest.desktopIdentity else { throw PrivacyError("桌面目录发生变化，已停止操作。") }
    }
    func inventory() throws -> [DiskItem] {
        try FileManager.default.contentsOfDirectory(atPath: manifest.desktop).map { name in
            var s = stat(); let path = URL(fileURLWithPath: manifest.desktop).appendingPathComponent(name).path
            guard lstat(path, &s) == 0 else { throw PrivacyError("无法读取桌面项目“\(name)”。") }
            return DiskItem(name: name, identity: .init(s), flags: s.st_flags, mode: s.st_mode)
        }
    }
    private func visibleNames(_ items: [DiskItem]) -> [String] {
        items.filter { !$0.name.hasPrefix(".") && $0.flags & UInt32(UF_HIDDEN) == 0 }.map(\.name).sorted()
    }
    private func resolve(_ target: TargetFile, items: [DiskItem]) throws -> DiskItem {
        if let exact = items.first(where: { $0.name == target.name && $0.identity == target.identity }) { return try safeItem(exact) }
        let matches = items.filter { $0.identity == target.identity }
        guard matches.count == 1, let renamed = matches.first else {
            throw PrivacyError("“\(target.name)”已被移走或替换。本工具不会处理同名的新文件，请将原文件放回桌面后重试。")
        }
        return try safeItem(renamed)
    }
    private func safeItem(_ item: DiskItem) throws -> DiskItem {
        guard item.mode & S_IFMT == S_IFREG || item.mode & S_IFMT == S_IFDIR else { throw PrivacyError("“\(item.name)”不是普通文件或文件夹，已停止操作。") }
        return item
    }
    private func setHidden(_ target: TargetFile, hidden: Bool) throws {
        let found = try resolve(target, items: inventory())
        let path = URL(fileURLWithPath: manifest.desktop).appendingPathComponent(found.name).path
        let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PrivacyError("无法打开“\(found.name)”的文件属性：\(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, FileIdentity(s) == target.identity else { throw PrivacyError("“\(found.name)”在操作期间被替换，已停止。") }
        let flags = hidden ? s.st_flags | UInt32(UF_HIDDEN) : s.st_flags & ~UInt32(UF_HIDDEN)
        if flags != s.st_flags, fchflags(fd, flags) != 0 { throw PrivacyError("无法改变“\(found.name)”的显示状态：\(String(cString: strerror(errno)))") }
        var after = stat()
        guard fstat(fd, &after) == 0, (after.st_flags & UInt32(UF_HIDDEN)) == (flags & UInt32(UF_HIDDEN)) else { throw PrivacyError("“\(found.name)”的显示状态校验失败。") }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let path = dataRoot.appendingPathComponent("operation.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PrivacyError("无法创建操作锁。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw PrivacyError("另一次隐藏或恢复正在进行，请稍后再试。") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
extension FileIdentity: Hashable {}
func syncDirectory(_ url: URL) {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC)
    if fd >= 0 { _ = fsync(fd); close(fd) }
}
func atomicWrite<T: Encodable>(_ object: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(object)
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw PrivacyError("无法保存恢复记录。") }
    var complete = false
    defer { close(fd); if !complete { unlink(temporary.path) } }
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            guard n > 0 else { throw PrivacyError("保存恢复记录失败。") }; offset += n
        }
    }
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw PrivacyError("保存恢复记录失败，未继续操作。") }
    complete = true; syncDirectory(url.deletingLastPathComponent())
}
