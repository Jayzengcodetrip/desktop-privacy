import AppKit

private func printJSON(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}

@MainActor private func smokeTest() {
    do {
        let configuration = try AppConfiguration.current()
        let service = try configuration.makeService(layout: FinderLayoutProvider())
        // Initialization creates/loads only this edition's state. It never hides,
        // restores, enumerates desktop contents, or asks Finder to move anything.
        try service.initialize()
        printJSON([
            "ok": true,
            "bundleIdentifier": AppConfiguration.bundleIdentifier,
            "initialTargetCount": 0,
            "targetCount": service.presentation.count,
            "dataDirectory": configuration.dataRoot.path,
            "desktopDirectory": configuration.desktopURL.path,
            "desktopFilesChanged": false
        ])
    } catch {
        printJSON(["ok": false, "error": error.localizedDescription,
                   "bundleIdentifier": AppConfiguration.bundleIdentifier])
        exit(1)
    }
}

@MainActor private func launch() {
    if CommandLine.arguments.contains("--smoke-test") {
        smokeTest()
        return
    }
    let app = NSApplication.shared
    do {
        let configuration = try AppConfiguration.current()
        let service = try configuration.makeService(layout: FinderLayoutProvider())
        let delegate = PrivacyAppDelegate(service: service, desktopURL: configuration.desktopURL)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    } catch {
        let alert = NSAlert()
        alert.messageText = "\(AppConfiguration.displayName)无法启动"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }
}

MainActor.assumeIsolated { launch() }
