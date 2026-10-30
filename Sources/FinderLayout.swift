import AppKit
import Carbon
import Darwin

final class FinderLayoutProvider: LayoutProvider {
    func checkVisibilitySettings() throws {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        let prefs = UserDefaults(suiteName: "com.apple.finder")
        if prefs?.bool(forKey: "AppleShowAllFiles") == true {
            throw PrivacyError("Finder 已开启“显示隐藏文件”。请先在 Finder 中按 Command + Shift + . 关闭，再使用隐藏功能。工具不会替你改变这个全局设置。")
        }
        if let enabled = prefs?.object(forKey: "CreateDesktop") as? Bool, !enabled {
            throw PrivacyError("桌面图标已被整体关闭。请先退出其他隐藏桌面工具，再使用本工具。")
        }
        if let settings = prefs?.dictionary(forKey: "DesktopViewSettings"), let group = settings["GroupBy"] as? String, group.lowercased() != "none" {
            throw PrivacyError("桌面启用了叠放分组。为保持位置，本工具不会改动叠放或排序设置，请先恢复原来的手动布局。")
        }
    }
    func snapshot(names: [String]) throws -> DesktopLayout {
        let literals = names.map(appleString).joined(separator: ", ")
        let source = """
        with timeout of 15 seconds
        tell application "Finder"
            set rows to {}
            repeat with targetName in {\(literals)}
                set targetName to contents of targetName
                set xy to desktop position of item targetName of desktop
                set end of rows to {targetName, item 1 of xy, item 2 of xy}
            end repeat
            return rows
        end tell
        end timeout
        """
        let rows = try execute(source)
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        guard let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any],
              let icon = settings["IconViewSettings"] as? [String: Any],
              let arrangeBy = icon["arrangeBy"] as? String else {
            throw PrivacyError("Finder 尚未提供可确认的桌面排序设置，未改动文件。请在桌面空白处右键，将“排序方式”设为“无”后重试；若已是“无”，可打开桌面“显示查看选项”确认设置后重试。")
        }
        // Read Finder's persisted desktop view settings. On this macOS version,
        // the advertised AppleScript desktop-window icon-view-options object is absent.
        let mode = arrangeBy.lowercased() == "none" ? "narr" : "automatic"
        let layoutKeys = ["iconSize", "textSize", "labelOnBottom", "showItemInfo", "gridSpacing", "gridOffsetX", "gridOffsetY"]
        let config = layoutKeys.map { "\($0)=\(icon[$0] ?? "default")" }.joined(separator: ",")
        var positions: [String: DesktopPoint] = [:]
        if rows.numberOfItems > 0 {
            for i in 1...rows.numberOfItems {
                guard let row = rows.atIndex(i), row.numberOfItems == 3, let name = row.atIndex(1)?.stringValue,
                      let x = row.atIndex(2), let y = row.atIndex(3) else { throw PrivacyError("桌面图标位置不可用。") }
                let point = DesktopPoint(x: Int(x.int32Value), y: Int(y.int32Value))
                guard abs(point.x) < 100_000, abs(point.y) < 100_000, positions[name] == nil else { throw PrivacyError("桌面图标位置无效。") }
                positions[name] = point
            }
        }
        guard Set(positions.keys) == Set(names) else { throw PrivacyError("无法读取全部桌面位置，未继续操作。") }
        let screens = NSScreen.screens.map { screen -> String in
            let f = screen.frame
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return "\(id?.uint32Value ?? 0):\(f.origin.x),\(f.origin.y),\(f.width),\(f.height):\(screen.backingScaleFactor)"
        }.sorted().joined(separator: "|")
        let grouping = String(describing: settings["GroupBy"] ?? "None")
        return DesktopLayout(arrangement: mode, configuration: config + ";" + screens + ";" + grouping, positions: positions)
    }
    func setPositions(_ positions: [String: DesktopPoint], expected: DesktopLayout) throws {
        let current = try snapshot(names: Array(positions.keys).sorted())
        guard current.configuration == expected.configuration, current.arrangement == expected.arrangement else {
            throw PrivacyError("桌面显示设置已经变化，未改动图标位置。恢复记录会保留。")
        }
        let commands = positions.sorted(by: { $0.key < $1.key }).map {
            "set desktop position of item \(appleString($0.key)) of desktop to {\($0.value.x), \($0.value.y)}"
        }.joined(separator: "\n")
        _ = try execute("with timeout of 15 seconds\ntell application \"Finder\"\n" + commands + "\nend tell\nend timeout")
    }
    /// Unlike the compatibility method above, this path never carries a file name
    /// across Finder calls as the writable reference. A concrete Finder alias is
    /// retained, resolved, and identity-checked before and after each mutation.
    func setPositionsSafely(_ placements: [VerifiedPlacement], expected: DesktopLayout) throws {
        let handlerSource = """
        on captureTarget(targetPath)
            return (POSIX file targetPath) as alias
        end captureTarget

        on inspectTarget(targetAlias)
            with timeout of 15 seconds
                set actualPath to POSIX path of targetAlias
                tell application "Finder"
                    set xy to desktop position of targetAlias
                end tell
                return {actualPath, item 1 of xy, item 2 of xy}
            end timeout
        end inspectTarget

        on placeTarget(targetAlias, targetX, targetY, expectedMode)
            with timeout of 15 seconds
                tell application "Finder"
                    if expectedMode is not "narr" then error "Unsupported desktop arrangement" number 1004
                    set desktop position of targetAlias to {targetX, targetY}
                    set xy to desktop position of targetAlias
                end tell
                return {POSIX path of targetAlias, item 1 of xy, item 2 of xy}
            end timeout
        end placeTarget
        """
        guard let script = NSAppleScript(source: handlerSource) else {
            throw PrivacyError("无法准备安全的 Finder 位置恢复。")
        }
        var compilationError: NSDictionary?
        guard script.compileAndReturnError(&compilationError) else {
            try throwScriptError(compilationError)
            throw PrivacyError("无法编译安全的 Finder 位置恢复。")
        }
        for placement in placements {
            try requireConfiguration(expected)
            let fileURL = try locateOriginal(placement)
            try requireIdentity(at: fileURL, placement: placement)
            let fd = open(fileURL.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PrivacyError("无法安全访问“\(placement.name)”的位置。") }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, FileIdentity(opened) == placement.identity else {
                throw PrivacyError("“\(placement.name)”在位置恢复前被替换，已停止。")
            }
            let alias = try invoke(script, handler: "capturetarget", arguments: [.init(string: fileURL.path)])
            guard alias.descriptorType == typeAlias else {
                throw PrivacyError("Finder 未返回“\(placement.name)”的稳定引用，未改动位置。")
            }
            // Check both the acquisition path and the path to which the alias
            // actually resolves. This also rejects an alias that rebound by name.
            try requireIdentity(at: fileURL, placement: placement)
            let captured = try inspectAlias(alias, script: script)
            try requireIdentity(at: captured.url, placement: placement)
            try requireConfiguration(expected)
            let immediatelyBefore = try inspectAlias(alias, script: script)
            try requireIdentity(at: immediatelyBefore.url, placement: placement)
            guard abs(placement.position.x) < 100_000, abs(placement.position.y) < 100_000 else {
                throw PrivacyError("“\(placement.name)”保存的位置无效，未改动位置。")
            }
            let written = try invoke(script, handler: "placetarget", arguments: [
                alias,
                .init(int32: Int32(placement.position.x)),
                .init(int32: Int32(placement.position.y)),
                .init(string: expected.arrangement)
            ])
            let writeResult = try decodedAliasResult(written)
            try requireIdentity(at: writeResult.url, placement: placement)
            let readBack = try inspectAlias(alias, script: script)
            try requireIdentity(at: readBack.url, placement: placement)
            guard writeResult.point == placement.position, readBack.point == placement.position else {
                throw PrivacyError("“\(placement.name)”的位置尚未恢复，记录会保留，可再次点击恢复。")
            }
            try requireConfiguration(expected)
        }
    }

    private func requireConfiguration(_ expected: DesktopLayout) throws {
        let current = try snapshot(names: [])
        guard current.configuration == expected.configuration, current.arrangement == expected.arrangement else {
            throw PrivacyError("桌面显示设置已经变化，未继续改动图标位置。恢复记录会保留。")
        }
    }

    private func locateOriginal(_ placement: VerifiedPlacement) throws -> URL {
        let directory = URL(fileURLWithPath: placement.desktop, isDirectory: true).standardizedFileURL
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var matches: [URL] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            var item = stat()
            if lstat(url.path, &item) == 0, FileIdentity(item) == placement.identity {
                matches.append(url)
            }
        }
        guard matches.count == 1, let url = matches.first else {
            throw PrivacyError("“\(placement.name)”已被移走或替换，未改动任何同名文件的位置。")
        }
        return url
    }

    private func requireIdentity(at url: URL, placement: VerifiedPlacement) throws {
        // Finder may return the logical Desktop path while the configured
        // directory is canonical. Resolve only the parent, never the item.
        let actual = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
        let desktop = URL(fileURLWithPath: placement.desktop, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var item = stat()
        guard actual.deletingLastPathComponent() == desktop,
              lstat(actual.path, &item) == 0,
              item.st_mode & S_IFMT == S_IFREG || item.st_mode & S_IFMT == S_IFDIR,
              FileIdentity(item) == placement.identity else {
            throw PrivacyError("“\(placement.name)”的位置引用已经变化，已停止，未继续处理同名文件。")
        }
    }

    private func inspectAlias(_ alias: NSAppleEventDescriptor, script: NSAppleScript) throws -> (url: URL, point: DesktopPoint) {
        try decodedAliasResult(invoke(script, handler: "inspecttarget", arguments: [alias]))
    }

    private func decodedAliasResult(_ result: NSAppleEventDescriptor) throws -> (url: URL, point: DesktopPoint) {
        guard result.numberOfItems == 3,
              let path = result.atIndex(1)?.stringValue,
              path.hasPrefix("/"),
              let x = result.atIndex(2), let y = result.atIndex(3) else {
            throw PrivacyError("Finder 未返回完整的身份与位置结果，恢复记录会保留。")
        }
        let point = DesktopPoint(x: Int(x.int32Value), y: Int(y.int32Value))
        guard abs(point.x) < 100_000, abs(point.y) < 100_000 else {
            throw PrivacyError("Finder 返回的位置无效，恢复记录会保留。")
        }
        return (URL(fileURLWithPath: path), point)
    }

    private func invoke(_ script: NSAppleScript, handler: String, arguments: [NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                          eventID: AEEventID(kASSubroutineEvent),
                                          targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(.init(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() { parameters.insert(argument, at: index + 1) }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        try throwScriptError(error)
        return result
    }

    private func throwScriptError(_ error: NSDictionary?) throws {
        guard let error else { return }
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        if code == -1743 {
            throw PrivacyError("需要允许“桌面文件隐身”控制 Finder，才能保存和恢复图标位置。请到 系统设置 → 隐私与安全性 → 自动化，为“桌面文件隐身”打开 Finder，然后重试。")
        }
        throw PrivacyError("无法读取或恢复 Finder 桌面布局（\(code)）。\(error[NSAppleScript.errorMessage] as? String ?? "请稍后重试。")")
    }

    func refresh() throws {
        _ = try execute("with timeout of 10 seconds\ntell application \"Finder\" to update desktop registering applications false\nend timeout")
        // Bounded refresh settling for Finder, with no relaunch or global settings changes.
        Thread.sleep(forTimeInterval: 0.3)
    }
    private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw PrivacyError("无法准备 Finder 位置操作。") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw PrivacyError("需要允许“桌面文件隐身”控制 Finder，才能保存和恢复图标位置。请到 系统设置 → 隐私与安全性 → 自动化，为“桌面文件隐身”打开 Finder，然后重试。")
            }
            throw PrivacyError("无法读取或恢复 Finder 桌面布局（\(code)）。\(error[NSAppleScript.errorMessage] as? String ?? "请稍后重试。")")
        }
        return result
    }
}
func appleString(_ value: String) -> String {
    // Escape identifiers as data, including line breaks and literal backslashes.
    let parts = value.components(separatedBy: "\n").map { part in
        "\"" + part.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    return "(" + parts.joined(separator: " & character id 10 & ") + ")"
}
