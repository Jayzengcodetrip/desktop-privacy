import Foundation
import Darwin

/// Public-edition identity and storage are independent from other editions.
/// Inject the two directories in tests; only current() resolves user locations.
struct AppConfiguration {
    static let bundleIdentifier = "io.github.jayzengcodetrip.desktop-privacy"
    static let displayName = "桌面文件一键隐身"

    let desktopURL: URL
    let dataRoot: URL

    init(desktopURL: URL, applicationSupportURL: URL) {
        self.desktopURL = desktopURL.standardizedFileURL.resolvingSymlinksInPath()
        self.dataRoot = applicationSupportURL.standardizedFileURL
            .appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
    }

    static func current(fileManager: FileManager = .default) throws -> AppConfiguration {
        let desktop = try fileManager.url(for: .desktopDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false)
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false)
        return AppConfiguration(desktopURL: desktop, applicationSupportURL: support)
    }

    func makeEmptyManifest() throws -> FixedManifest {
        var info = stat()
        guard desktopURL.isFileURL, lstat(desktopURL.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw PrivacyError("无法找到当前用户的桌面目录，请确认桌面可访问后重试。")
        }
        return FixedManifest(schema: 1, desktop: desktopURL.path,
                             desktopIdentity: FileIdentity(info), targets: [])
    }

    func makeService(layout: any LayoutProvider) throws -> DesktopPrivacyService {
        DesktopPrivacyService(manifest: try makeEmptyManifest(), dataRoot: dataRoot, layout: layout)
    }
}
