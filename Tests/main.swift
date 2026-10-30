import Foundation
import Darwin

// The entire suite uses a unique temporary tree. It never resolves the real
// Desktop directory or the current user's Application Support directory.
let fm = FileManager.default
let fixtureBase = fm.temporaryDirectory
    .appendingPathComponent("desktop-privacy-tests-" + UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: fixtureBase, withIntermediateDirectories: false,
                       attributes: [.posixPermissions: 0o700])

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message) }
}

func expectError(_ label: String, _ body: () throws -> Void) throws {
    var didThrow = false
    do { try body() } catch { didThrow = true }
    try require(didThrow, "Expected error: \(label)")
}

func fileStat(_ url: URL) throws -> stat {
    var result = stat()
    guard lstat(url.path, &result) == 0 else {
        throw TestFailure("lstat failed for fixture: \(url.lastPathComponent)")
    }
    return result
}

func isHidden(_ url: URL) throws -> Bool { try fileStat(url).st_flags & UInt32(UF_HIDDEN) != 0 }

func setFixtureFlags(_ url: URL, _ flags: UInt32) throws {
    guard url.path.hasPrefix(fixtureBase.path + "/"), chflags(url.path, flags) == 0 else {
        throw TestFailure("Could not set fixture flags")
    }
}

final class FakeLayout: LayoutProvider {
    var arrangement = "narr"
    var configuration = "fixture-display-1440x900"
    var positions: [String: DesktopPoint]
    var visibilityAllowed = true
    var refreshCount = 0
    var setPositionCalls: [[String: DesktopPoint]] = []
    var positionWriteFailuresRemaining = 0
    var onRefresh: ((FakeLayout) throws -> Void)?

    init(positions: [String: DesktopPoint]) { self.positions = positions }

    func snapshot(names: [String]) throws -> DesktopLayout {
        var selected: [String: DesktopPoint] = [:]
        for name in names {
            guard let position = positions[name] else { throw TestFailure("Fixture has no position for \(name)") }
            selected[name] = position
        }
        return DesktopLayout(arrangement: arrangement, configuration: configuration, positions: selected)
    }

    func setPositions(_ changed: [String: DesktopPoint], expected: DesktopLayout) throws {
        guard arrangement == expected.arrangement, configuration == expected.configuration else {
            throw TestFailure("Fixture layout configuration changed")
        }
        setPositionCalls.append(changed)
        if positionWriteFailuresRemaining > 0 {
            positionWriteFailuresRemaining -= 1
            throw TestFailure("Injected position write failure")
        }
        for (name, point) in changed { positions[name] = point }
    }

    func refresh() throws {
        refreshCount += 1
        try onRefresh?(self)
    }

    func checkVisibilitySettings() throws {
        guard visibilityAllowed else { throw TestFailure("Fixture show-hidden-files setting blocks hiding") }
    }
}

final class Fixture {
    let root: URL
    let desktop: URL
    let data: URL
    let layout: FakeLayout
    let manifest: FixedManifest
    let service: DesktopPrivacyService
    let first = "私密资料.txt"
    let folder = "项目文件夹"
    let other = "演示.txt"
    let originalPoints: [String: DesktopPoint]

    var journal: URL { data.appendingPathComponent("recovery.json") }
    func url(_ name: String) -> URL { desktop.appendingPathComponent(name) }

    init(_ label: String) throws {
        root = fixtureBase.appendingPathComponent(label + "-" + UUID().uuidString, isDirectory: true)
        desktop = root.appendingPathComponent("FakeDesktop", isDirectory: true)
        data = root.appendingPathComponent("State", isDirectory: true)
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data("private file\n".utf8).write(to: desktop.appendingPathComponent(first))
        try fm.createDirectory(at: desktop.appendingPathComponent(folder), withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop.appendingPathComponent(folder + "/nested"), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3, 254, 255]).write(to: desktop.appendingPathComponent(folder + "/nested/child.bin"))
        try Data("public demonstration\n".utf8).write(to: desktop.appendingPathComponent(other))
        originalPoints = [
            first: DesktopPoint(x: 100, y: 200),
            folder: DesktopPoint(x: 400, y: 300),
            other: DesktopPoint(x: 650, y: 150)
        ]
        layout = FakeLayout(positions: originalPoints)
        let targetRoot = desktop
        let targetNames = [first, folder]
        let targets = try targetNames.map {
            TargetFile(name: $0, identity: FileIdentity(try fileStat(targetRoot.appendingPathComponent($0))))
        }
        manifest = FixedManifest(schema: 1, desktop: desktop.path, desktopIdentity: FileIdentity(try fileStat(desktop)), targets: targets)
        service = DesktopPrivacyService(manifest: manifest, dataRoot: data, layout: layout)
        try service.initialize()
    }

    func cleanup() throws {
        guard root.path.hasPrefix(fixtureBase.path + "/"), root.deletingLastPathComponent().path == fixtureBase.path else {
            throw TestFailure("Refusing unsafe fixture cleanup")
        }
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
    }

    func withCleanup(_ body: (Fixture) throws -> Void) throws {
        do { try body(self); try cleanup() }
        catch { try? cleanup(); throw error }
    }
}

// A file-tree snapshot checks that list editing is metadata-only and never
// moves, deletes, rewrites, or recursively hides the real desktop items.
struct FixtureFileRecord: Equatable {
    let identity: FileIdentity
    let flags: UInt32
    let mode: mode_t
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let contents: Data?
}

func fileTreeSnapshot(_ directory: URL) throws -> [String: FixtureFileRecord] {
    let relativePaths = ["."] + (try fm.subpathsOfDirectory(atPath: directory.path)).sorted()
    var records: [String: FixtureFileRecord] = [:]
    for relative in relativePaths {
        let url = relative == "." ? directory : directory.appendingPathComponent(relative)
        let item = try fileStat(url)
        let bytes: Data?
        if item.st_mode & S_IFMT == S_IFREG { bytes = try Data(contentsOf: url) }
        else if item.st_mode & S_IFMT == S_IFLNK {
            bytes = Data(try fm.destinationOfSymbolicLink(atPath: url.path).utf8)
        } else { bytes = nil }
        records[relative] = .init(identity: FileIdentity(item), flags: item.st_flags,
                                  mode: item.st_mode, size: item.st_size,
                                  modificationSeconds: Int64(item.st_mtimespec.tv_sec),
                                  modificationNanoseconds: Int64(item.st_mtimespec.tv_nsec),
                                  contents: bytes)
    }
    return records
}

func storedManifestBytes(_ fixture: Fixture) throws -> Data {
    try Data(contentsOf: fixture.data.appendingPathComponent("manifest.json"))
}

var passed = 0
var failures: [String] = []
func test(_ title: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(title)") }
    catch { failures.append("\(title): \(error)"); print("FAIL \(title): \(error)") }
}

test("hide/restore repairs target positions and preserves unrelated item") {
    try Fixture("normal").withCleanup { f in
        let otherIdentity = FileIdentity(try fileStat(f.url(f.other)))
        let otherData = try Data(contentsOf: f.url(f.other))
        f.layout.onRefresh = { layout in
            // Simulate Finder moving only the disappearing/reappearing target icons.
            layout.positions[f.first] = DesktopPoint(x: 1200, y: 800)
            layout.positions[f.folder] = DesktopPoint(x: 1100, y: 700)
        }
        try f.service.hide()
        try require(try isHidden(f.url(f.first)), "First target should be hidden")
        try require(try isHidden(f.url(f.folder)), "Folder target should be hidden")
        try require(!(try isHidden(f.url(f.other))), "Unlisted file was hidden")
        try require(f.service.presentation.mode == .hidden, "Service must report hidden")
        try f.service.restore()
        try require(!(try isHidden(f.url(f.first))), "First target did not restore")
        try require(!(try isHidden(f.url(f.folder))), "Folder target did not restore")
        try require(f.layout.positions == f.originalPoints, "Positions did not return exactly")
        try require(f.layout.setPositionCalls.allSatisfy { $0[f.other] == nil }, "Unrelated item's position was written")
        try require(FileIdentity(try fileStat(f.url(f.other))) == otherIdentity, "Unrelated file identity changed")
        try require(try Data(contentsOf: f.url(f.other)) == otherData, "Unrelated file data changed")
        try require(!fm.fileExists(atPath: f.journal.path), "Recovery journal should be cleared")
        try require(f.service.presentation.mode == .visible, "Service must report visible")
    }
}

test("new desktop file never joins fixed manifest") {
    try Fixture("new-file").withCleanup { f in
        try f.service.hide()
        let newName = "新演示文件.txt"
        let contents = Data("created while recording".utf8)
        try contents.write(to: f.url(newName))
        f.layout.positions[newName] = DesktopPoint(x: 800, y: 90)
        let identity = FileIdentity(try fileStat(f.url(newName)))
        try f.service.restore()
        try f.service.hide()
        try require(!(try isHidden(f.url(newName))), "New file was hidden")
        try require(FileIdentity(try fileStat(f.url(newName))) == identity, "New file was replaced")
        try require(try Data(contentsOf: f.url(newName)) == contents, "New file changed")
        try require(f.layout.positions[newName] == DesktopPoint(x: 800, y: 90), "New file moved")
        try f.service.restore()
    }
}

test("renamed original is located by identity and restored") {
    try Fixture("rename").withCleanup { f in
        try f.service.hide()
        let renamed = "改名后的私密资料.txt"
        try fm.moveItem(at: f.url(f.first), to: f.url(renamed))
        f.layout.positions.removeValue(forKey: f.first)
        f.layout.positions[renamed] = DesktopPoint(x: 1100, y: 600)
        try f.service.restore()
        try require(!(try isHidden(f.url(renamed))), "Renamed original remains hidden")
        try require(f.layout.positions[renamed] == f.originalPoints[f.first], "Renamed original position not restored")
        try require(!fm.fileExists(atPath: f.url(f.first).path), "Tool recreated old filename")
        try require(!fm.fileExists(atPath: f.journal.path), "Rename should not leave unresolved journal")
    }
}

test("same-name replacement is refused before hiding any file") {
    try Fixture("replacement").withCleanup { f in
        let parked = f.root.appendingPathComponent("OriginalParked.txt")
        try fm.moveItem(at: f.url(f.first), to: parked)
        let replacement = Data("this is a different file".utf8)
        try replacement.write(to: f.url(f.first))
        try expectError("same-name replacement") { try f.service.hide() }
        try require(!(try isHidden(f.url(f.first))), "Replacement was hidden")
        try require(!(try isHidden(f.url(f.folder))), "Other target mutated despite preflight failure")
        try require(try Data(contentsOf: f.url(f.first)) == replacement, "Replacement contents changed")
        try require(!fm.fileExists(atPath: f.journal.path), "Preflight failure should not create journal")
    }
}

test("moved original does not prevent restoring other targets and journal stays") {
    try Fixture("moved").withCleanup { f in
        try f.service.hide()
        let moved = f.root.appendingPathComponent("MovedOriginal.txt")
        try fm.moveItem(at: f.url(f.first), to: moved)
        f.layout.positions.removeValue(forKey: f.first)
        try expectError("missing original during restore") { try f.service.restore() }
        try require(!(try isHidden(f.url(f.folder))), "Resolvable folder was not restored")
        try require(try isHidden(moved), "Tool reached outside its desktop scope")
        try require(fm.fileExists(atPath: f.journal.path), "Unresolved recovery record was lost")
        try require(f.service.presentation.mode == .recovery, "Unresolved restore must report recovery")
        try fm.moveItem(at: moved, to: f.url(f.first))
        f.layout.positions[f.first] = DesktopPoint(x: 900, y: 700)
        try f.service.restore()
        try require(!(try isHidden(f.url(f.first))), "Returned original did not restore")
        try require(!fm.fileExists(atPath: f.journal.path), "Completed recovery record not cleared")
    }
}

test("mid-hide failure rolls back flags and saved positions") {
    try Fixture("rollback").withCleanup { f in
        var observedJournalBeforeMutationCompleted = false
        f.service.afterFlagChangeForTest = { index in
            observedJournalBeforeMutationCompleted = fm.fileExists(atPath: f.journal.path)
            _ = try JSONDecoder().decode(RecoverySession.self, from: Data(contentsOf: f.journal))
            if index == 0 { throw TestFailure("Injected failure after first flag change") }
        }
        try expectError("injected mutation failure") { try f.service.hide() }
        try require(observedJournalBeforeMutationCompleted, "No durable recovery record before mutations")
        try require(!(try isHidden(f.url(f.first))), "Partially hidden file was not rolled back")
        try require(!(try isHidden(f.url(f.folder))), "Unchanged folder unexpectedly hidden")
        try require(f.layout.positions == f.originalPoints, "Rollback changed positions")
        try require(!fm.fileExists(atPath: f.journal.path), "Successful rollback left active journal")
        try require(f.service.presentation.mode == .visible, "Successful rollback must report visible")
    }
}

test("non-hidden flags survive hide and restore including intervening additions") {
    try Fixture("flags").withCleanup { f in
        let firstFlags = try fileStat(f.url(f.first)).st_flags | UInt32(UF_NODUMP)
        try setFixtureFlags(f.url(f.first), firstFlags)
        try f.service.hide()
        try require(try fileStat(f.url(f.first)).st_flags & UInt32(UF_NODUMP) != 0, "Original nodump flag was lost on hide")
        let folderFlags = try fileStat(f.url(f.folder)).st_flags | UInt32(UF_NODUMP)
        try setFixtureFlags(f.url(f.folder), folderFlags)
        try f.service.restore()
        try require(try fileStat(f.url(f.first)).st_flags == firstFlags, "Original unrelated flags changed")
        try require(try fileStat(f.url(f.folder)).st_flags & UInt32(UF_NODUMP) != 0, "Intervening unrelated flag was removed")
        try require(!(try isHidden(f.url(f.folder))), "Hidden flag not cleared")
    }
}

test("folder descendants and contents are untouched") {
    try Fixture("folder").withCleanup { f in
        let child = f.url(f.folder + "/nested/child.bin")
        let nested = f.url(f.folder + "/nested")
        let childBefore = try fileStat(child)
        let nestedBefore = try fileStat(nested)
        let bytes = try Data(contentsOf: child)
        let tree = try fm.subpathsOfDirectory(atPath: f.url(f.folder).path).sorted()
        try f.service.hide()
        try require(!(try isHidden(nested)), "Nested folder's flag was modified")
        try require(!(try isHidden(child)), "Nested file's flag was modified")
        try f.service.restore()
        try require(FileIdentity(try fileStat(child)) == FileIdentity(childBefore), "Child identity changed")
        try require(FileIdentity(try fileStat(nested)) == FileIdentity(nestedBefore), "Nested folder identity changed")
        try require(try fileStat(child).st_flags == childBefore.st_flags, "Child flags changed")
        try require(try Data(contentsOf: child) == bytes, "Child contents changed")
        try require(try fm.subpathsOfDirectory(atPath: f.url(f.folder).path).sorted() == tree, "Folder structure changed")
    }
}

test("automatic sorting blocks hide without changing sorting") {
    try Fixture("sorting").withCleanup { f in
        f.layout.arrangement = "nama"
        try expectError("auto sorting") { try f.service.hide() }
        try require(f.layout.arrangement == "nama", "Tool changed sorting preference")
        try require(!(try isHidden(f.url(f.first))), "File was hidden despite automatic sorting")
        try require(!(try isHidden(f.url(f.folder))), "Folder was hidden despite automatic sorting")
        try require(!fm.fileExists(atPath: f.journal.path), "Unsafe preflight created journal")
    }
}

test("corrupt journal blocks further changes and remains recoverable") {
    try Fixture("corrupt").withCleanup { f in
        try f.service.hide()
        let validJournal = try Data(contentsOf: f.journal)
        let brokenJournal = Data("{this is not valid JSON".utf8)
        try brokenJournal.write(to: f.journal)
        let reopened = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try expectError("corrupt journal initialization") { try reopened.initialize() }
        try expectError("hide after corrupt initialization") { try reopened.hide() }
        try require(try isHidden(f.url(f.first)), "Corrupt journal caused untracked mutation")
        try require(try Data(contentsOf: f.journal) == brokenJournal, "Corrupt journal was overwritten")
        try validJournal.write(to: f.journal)
        let recovered = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try recovered.initialize()
        try recovered.restore()
        try require(!(try isHidden(f.url(f.first))), "Valid restored journal could not recover file")
    }
}

test("fresh process restores a persisted hidden session") {
    try Fixture("restart").withCleanup { f in
        try f.service.hide()
        f.layout.positions[f.first] = DesktopPoint(x: 1000, y: 500)
        let reopened = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try reopened.initialize()
        try require(reopened.presentation.mode == .hidden, "Persisted session was not loaded")
        try reopened.restore()
        try require(!(try isHidden(f.url(f.first))), "Restart restore left file hidden")
        try require(f.layout.positions == f.originalPoints, "Restart restore lost original positions")
    }
}

test("show-hidden-files mode blocks hide before any mutation") {
    try Fixture("show-hidden").withCleanup { f in
        f.layout.visibilityAllowed = false
        try expectError("Finder visibility setting") { try f.service.hide() }
        try require(!(try isHidden(f.url(f.first))), "Visibility preflight failure changed a file")
        try require(!fm.fileExists(atPath: f.journal.path), "Visibility preflight created journal")
    }
}

test("sorting changed while hidden blocks restore before any hidden flag changes") {
    try Fixture("restore-sorting").withCleanup { f in
        try f.service.hide()
        let firstFlags = try fileStat(f.url(f.first)).st_flags
        let folderFlags = try fileStat(f.url(f.folder)).st_flags
        let refreshCount = f.layout.refreshCount
        let points = f.layout.positions
        f.layout.arrangement = "nama"
        try expectError("sorting changed during hidden interval") { try f.service.restore() }
        try require(try fileStat(f.url(f.first)).st_flags == firstFlags, "Restore changed first target flags before rejecting sorting")
        try require(try fileStat(f.url(f.folder)).st_flags == folderFlags, "Restore changed folder flags before rejecting sorting")
        try require(try isHidden(f.url(f.first)), "Target became visible despite sorting preflight failure")
        try require(f.layout.refreshCount == refreshCount, "Restore refreshed Finder before sorting preflight completed")
        try require(f.layout.positions == points, "Sorting preflight changed a position")
        try require(fm.fileExists(atPath: f.journal.path), "Sorting preflight lost recovery record")
        try require(f.layout.arrangement == "nama", "Tool changed the user's sorting setting")
        f.layout.arrangement = "narr"
        try f.service.restore()
        try require(f.service.presentation.mode == .visible, "Restore did not recover after restoring original sort mode")
    }
}

test("display configuration changed while hidden blocks restore before any flags change") {
    try Fixture("restore-display").withCleanup { f in
        try f.service.hide()
        let firstFlags = try fileStat(f.url(f.first)).st_flags
        let folderFlags = try fileStat(f.url(f.folder)).st_flags
        let refreshCount = f.layout.refreshCount
        let originalConfiguration = f.layout.configuration
        f.layout.configuration = "fixture-display-1920x1080"
        try expectError("display configuration changed during hidden interval") { try f.service.restore() }
        try require(try fileStat(f.url(f.first)).st_flags == firstFlags, "Display preflight changed first target flags")
        try require(try fileStat(f.url(f.folder)).st_flags == folderFlags, "Display preflight changed folder flags")
        try require(f.layout.refreshCount == refreshCount, "Display preflight performed a refresh")
        try require(f.layout.setPositionCalls.isEmpty, "Display preflight wrote icon positions")
        try require(fm.fileExists(atPath: f.journal.path), "Display preflight lost recovery record")
        f.layout.configuration = originalConfiguration
        try f.service.restore()
        try require(f.service.presentation.mode == .visible, "Restore failed after restoring original display configuration")
    }
}

test("hide-induced unrelated icon drift is rolled back and hide still reports failure") {
    try Fixture("hide-observer-drift").withCleanup { f in
        let otherIdentity = FileIdentity(try fileStat(f.url(f.other)))
        let otherFlags = try fileStat(f.url(f.other)).st_flags
        f.layout.onRefresh = { layout in
            if layout.refreshCount == 1 { layout.positions[f.other] = DesktopPoint(x: 900, y: 850) }
        }
        try expectError("hide must not report success after unrelated icon drift") { try f.service.hide() }
        try require(f.layout.positions == f.originalPoints, "Rollback did not return unrelated icon to original position")
        try require(f.layout.setPositionCalls.contains { $0[f.other] == f.originalPoints[f.other] }, "Unrelated icon repair was not attempted")
        try require(!(try isHidden(f.url(f.first))) && !(try isHidden(f.url(f.folder))), "Rollback left target hidden")
        try require(FileIdentity(try fileStat(f.url(f.other))) == otherIdentity, "Unrelated file identity changed during rollback")
        try require(try fileStat(f.url(f.other)).st_flags == otherFlags, "Unrelated file flags changed during rollback")
        try require(f.service.presentation.mode == .visible, "Completed rollback must return to visible state")
        try require(f.service.presentation.detail.contains("隐藏未完成"), "Failure was mislabeled as a completed hide")
        try require(!fm.fileExists(atPath: f.journal.path), "Successful observer rollback left active journal")
    }
}

test("user's unrelated icon movement while hidden survives a normal restore") {
    try Fixture("user-observer-move").withCleanup { f in
        try f.service.hide()
        let userPosition = DesktopPoint(x: 900, y: 450)
        f.layout.positions[f.other] = userPosition
        try f.service.restore()
        try require(f.layout.positions[f.other] == userPosition, "Restore overwrote user's unrelated icon movement")
        try require(f.layout.setPositionCalls.allSatisfy { $0[f.other] == nil }, "Normal restore unnecessarily wrote unrelated icon")
        try require(f.layout.positions[f.first] == f.originalPoints[f.first], "Target original position was lost")
        try require(f.layout.positions[f.folder] == f.originalPoints[f.folder], "Folder original position was lost")
    }
}

test("restore-induced unrelated icon drift is repaired to the position before restore") {
    try Fixture("restore-observer-drift").withCleanup { f in
        try f.service.hide()
        let userPosition = DesktopPoint(x: 900, y: 450)
        f.layout.positions[f.other] = userPosition
        f.layout.onRefresh = { layout in
            if layout.refreshCount == 2 { layout.positions[f.other] = DesktopPoint(x: 1200, y: 850) }
        }
        try f.service.restore()
        try require(f.layout.positions[f.other] == userPosition, "Restore-induced drift was not repaired to latest user position")
        try require(f.layout.positions[f.other] != f.originalPoints[f.other], "Repair incorrectly used pre-hide observer position")
        try require(f.layout.setPositionCalls.contains { $0[f.other] == userPosition }, "Repair did not write pre-restore observer position")
        try require(f.service.presentation.mode == .visible, "Observer repair did not finish restore")
        try require(!fm.fileExists(atPath: f.journal.path), "Successful observer repair left active journal")
    }
}

test("position write failure keeps journal and permits successful retry after reopening") {
    try Fixture("position-retry").withCleanup { f in
        try f.service.hide()
        let wrongPosition = DesktopPoint(x: 1100, y: 750)
        f.layout.positions[f.first] = wrongPosition
        f.layout.positionWriteFailuresRemaining = 1
        try expectError("injected target position write failure") { try f.service.restore() }
        try require(!(try isHidden(f.url(f.first))), "Resolvable file should have recovered visibility")
        try require(f.layout.positions[f.first] == wrongPosition, "Failed write unexpectedly changed position")
        try require(fm.fileExists(atPath: f.journal.path), "Position failure lost recovery journal")
        try require(f.service.presentation.mode == .recovery, "Incomplete position restore did not report recovery")
        let pending = try JSONDecoder().decode(RecoverySession.self, from: Data(contentsOf: f.journal))
        try require(pending.phase == "recovery", "Journal does not record incomplete recovery")
        let reopened = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try reopened.initialize()
        try reopened.restore()
        try require(f.layout.positions == f.originalPoints, "Retry failed to restore original positions")
        try require(reopened.presentation.mode == .visible, "Successful retry did not report visible")
        try require(!fm.fileExists(atPath: f.journal.path), "Successful retry did not clear recovery journal")
    }
}

test("each hide captures the latest target positions after the user rearranges them") {
    try Fixture("latest-layout").withCleanup { f in
        try f.service.hide()
        f.layout.positions[f.first] = DesktopPoint(x: 1100, y: 700)
        try f.service.restore()
        try require(f.layout.positions == f.originalPoints, "First cycle did not restore original layout")

        let latestFirst = DesktopPoint(x: 250, y: 410)
        let latestFolder = DesktopPoint(x: 530, y: 580)
        f.layout.positions[f.first] = latestFirst
        f.layout.positions[f.folder] = latestFolder
        let expectedLatest = f.layout.positions
        try f.service.hide()
        let secondJournal = try JSONDecoder().decode(RecoverySession.self, from: Data(contentsOf: f.journal))
        try require(secondJournal.targets.first { $0.target.name == f.first }?.position == latestFirst,
                    "Second journal reused stale first-target coordinates")
        try require(secondJournal.targets.first { $0.target.name == f.folder }?.position == latestFolder,
                    "Second journal reused stale folder coordinates")
        f.layout.positions[f.first] = DesktopPoint(x: 1300, y: 800)
        f.layout.positions[f.folder] = DesktopPoint(x: 1200, y: 900)
        try f.service.restore()
        try require(f.layout.positions == expectedLatest, "Second cycle restored an older layout")
        try require(f.layout.positions[f.first] != f.originalPoints[f.first], "User's newer target position was lost")
    }
}

test("adding and removing list entries preserves all real files and nested structure") {
    try Fixture("edit-no-file-mutations").withCleanup { f in
        let addedFolder = "新加入的文件夹"
        try fm.createDirectory(at: f.url(addedFolder + "/二级/三级"), withIntermediateDirectories: true)
        try Data("nested text remains unchanged\n".utf8).write(to: f.url(addedFolder + "/二级/三级/资料.txt"))
        f.layout.positions[addedFolder] = DesktopPoint(x: 850, y: 550)
        let before = try fileTreeSnapshot(f.desktop)
        let points = f.layout.positions
        try f.service.addTargets([f.url(f.other), f.url(addedFolder)])
        try require(Set(f.service.presentation.names) == Set([f.first, f.folder, f.other, addedFolder]),
                    "New candidates were not added to list")
        try require(try fileTreeSnapshot(f.desktop) == before, "Adding list entries changed real desktop files")
        try f.service.removeTargets(named: [f.first, f.folder])
        try require(Set(f.service.presentation.names) == Set([f.other, addedFolder]), "Removal did not edit the list")
        try require(try fileTreeSnapshot(f.desktop) == before, "Removing list entries deleted or changed real files")
        try require(f.layout.positions == points && f.layout.setPositionCalls.isEmpty, "Editing the list moved icons")
        try f.service.hide()
        try require(try isHidden(f.url(f.other)) && isHidden(f.url(addedFolder)), "Added targets were not hidden")
        try require(!(try isHidden(f.url(f.first))) && !(try isHidden(f.url(f.folder))), "Removed targets were still hidden")
        try require(!(try isHidden(f.url(addedFolder + "/二级/三级/资料.txt"))), "Added folder's child was recursively hidden")
        try f.service.restore()
        try require(try fileTreeSnapshot(f.desktop) == before, "Hide/restore after editing changed file tree or contents")
        try require(f.layout.positions == points, "Edited list restored incorrect positions")
    }
}

test("edited fixed list persists across reopening and replaces bootstrap targets") {
    try Fixture("manifest-reopen").withCleanup { f in
        try f.service.addTargets([f.url(f.other)])
        try f.service.removeTargets(named: [f.folder])
        let persisted = try storedManifestBytes(f)
        let reopened = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try reopened.initialize()
        try require(Set(reopened.presentation.names) == Set([f.first, f.other]), "Reopen restored stale bootstrap list")
        try require(reopened.presentation.count == 2, "Reopen changed target count")
        try require(try storedManifestBytes(f) == persisted, "Reopen rewrote edited manifest")
        try reopened.hide()
        try require(try isHidden(f.url(f.first)) && isHidden(f.url(f.other)), "Persisted new targets were not hidden")
        try require(!(try isHidden(f.url(f.folder))), "Persisted removed target was hidden")
        try reopened.restore()
        try require(f.layout.positions == f.originalPoints, "Reopened list lost saved layout")
    }
}

test("hidden session rejects list edits without altering manifest journal or files") {
    try Fixture("edit-hidden").withCleanup { f in
        try f.service.hide()
        let manifestBytes = try storedManifestBytes(f)
        let journalBytes = try Data(contentsOf: f.journal)
        let files = try fileTreeSnapshot(f.desktop)
        try expectError("add during hidden session") { try f.service.addTargets([f.url(f.other)]) }
        try expectError("remove during hidden session") { try f.service.removeTargets(named: [f.first]) }
        try require(try storedManifestBytes(f) == manifestBytes, "Hidden edit changed persisted list")
        try require(try Data(contentsOf: f.journal) == journalBytes, "Hidden edit changed recovery journal")
        try require(try fileTreeSnapshot(f.desktop) == files, "Hidden edit changed actual files")
        try require(f.service.presentation.count == 2 && f.service.presentation.mode == .hidden, "Hidden edit changed in-memory state")
        try f.service.restore()
    }
}

test("incomplete recovery rejects list edits until coordinates are restored") {
    try Fixture("edit-recovery").withCleanup { f in
        try f.service.hide()
        f.layout.positions[f.first] = DesktopPoint(x: 1400, y: 850)
        f.layout.positionWriteFailuresRemaining = 1
        try expectError("injected recovery failure") { try f.service.restore() }
        try require(f.service.presentation.mode == .recovery, "Fixture did not enter recovery state")
        let manifestBytes = try storedManifestBytes(f)
        let journalBytes = try Data(contentsOf: f.journal)
        let files = try fileTreeSnapshot(f.desktop)
        try expectError("add during recovery") { try f.service.addTargets([f.url(f.other)]) }
        try expectError("remove during recovery") { try f.service.removeTargets(named: [f.folder]) }
        try require(try storedManifestBytes(f) == manifestBytes, "Recovery edit changed persisted list")
        try require(try Data(contentsOf: f.journal) == journalBytes, "Recovery edit changed unfinished journal")
        try require(try fileTreeSnapshot(f.desktop) == files, "Recovery edit touched actual files")
        try require(f.service.presentation.mode == .recovery, "Rejected edit cleared recovery state")
        try f.service.restore()
        try f.service.addTargets([f.url(f.other)])
        try require(f.service.presentation.count == 3, "Completed recovery did not re-enable list management")
    }
}

test("empty persisted list can reopen and be managed but cannot hide") {
    try Fixture("empty-list").withCleanup { f in
        let before = try fileTreeSnapshot(f.desktop)
        try f.service.removeTargets(named: [f.first, f.folder])
        try require(f.service.presentation.count == 0, "All entries were not removed")
        let emptyManifest = try storedManifestBytes(f)
        let reopened = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try reopened.initialize()
        try require(reopened.presentation.mode == .visible && reopened.presentation.count == 0, "Empty list cannot reopen for management")
        try reopened.validate()
        try expectError("hide with empty list") { try reopened.hide() }
        try require(!fm.fileExists(atPath: f.journal.path), "Empty hide created recovery journal")
        try require(try storedManifestBytes(f) == emptyManifest, "Empty hide changed manifest")
        try require(try fileTreeSnapshot(f.desktop) == before, "Empty list management changed files")
        try reopened.addTargets([f.url(f.other)])
        try require(reopened.presentation.names == [f.other], "Cannot add after reopening an empty list")
        try reopened.hide()
        try require(try isHidden(f.url(f.other)), "New singleton target was not hidden")
        try require(!(try isHidden(f.url(f.first))) && !(try isHidden(f.url(f.folder))), "Empty-list bootstrap targets reappeared")
        try reopened.restore()
        try require(try fileTreeSnapshot(f.desktop) == before, "Empty-list recovery changed file structure")
    }
}

test("outside-desktop and nested non-top-level files cannot be added") {
    try Fixture("reject-outside").withCleanup { f in
        let outside = f.root.appendingPathComponent("桌面外.txt")
        let outsideBytes = Data("out of scope".utf8)
        try outsideBytes.write(to: outside)
        let outsideBefore = try fileStat(outside)
        let before = try fileTreeSnapshot(f.desktop)
        let manifestBytes = try storedManifestBytes(f)
        try expectError("outside-desktop add") { try f.service.addTargets([outside]) }
        try expectError("nested file add") { try f.service.addTargets([f.url(f.folder + "/nested/child.bin")]) }
        try require(try storedManifestBytes(f) == manifestBytes && f.service.presentation.count == 2, "Rejected paths changed manifest")
        try require(try fileTreeSnapshot(f.desktop) == before, "Rejected paths changed desktop tree")
        try require(FileIdentity(try fileStat(outside)) == FileIdentity(outsideBefore), "Outside file was replaced")
        try require(try fileStat(outside).st_flags == outsideBefore.st_flags, "Outside file flags changed")
        try require(try Data(contentsOf: outside) == outsideBytes, "Outside file contents changed")
    }
}

test("desktop symbolic links cannot add their desktop or outside targets") {
    try Fixture("reject-symlinks").withCleanup { f in
        let outside = f.root.appendingPathComponent("外部文件.txt")
        try Data("outside target".utf8).write(to: outside)
        let desktopLink = f.url("桌面内链接")
        let outsideLink = f.url("桌面外链接")
        try fm.createSymbolicLink(at: desktopLink, withDestinationURL: f.url(f.other))
        try fm.createSymbolicLink(at: outsideLink, withDestinationURL: outside)
        let before = try fileTreeSnapshot(f.desktop)
        let outsideBefore = try fileStat(outside)
        let manifestBytes = try storedManifestBytes(f)
        try expectError("symlink to desktop file") { try f.service.addTargets([desktopLink]) }
        try expectError("symlink to outside file") { try f.service.addTargets([outsideLink]) }
        try require(try storedManifestBytes(f) == manifestBytes && f.service.presentation.count == 2, "Symlink added a target")
        try require(try fileTreeSnapshot(f.desktop) == before, "Rejected symlink changed a file or link")
        try require(FileIdentity(try fileStat(outside)) == FileIdentity(outsideBefore), "Outside symlink target identity changed")
        try require(try fileStat(outside).st_flags == outsideBefore.st_flags, "Outside symlink target flags changed")
    }
}

test("batch add with an invalid later path is atomic in memory and on disk") {
    try Fixture("batch-add-invalid").withCleanup { f in
        let outside = f.root.appendingPathComponent("无效候选.txt")
        try Data("outside candidate".utf8).write(to: outside)
        let before = try fileTreeSnapshot(f.desktop)
        let manifestBytes = try storedManifestBytes(f)
        let oldNames = f.service.presentation.names
        try expectError("valid candidate followed by invalid path") {
            try f.service.addTargets([f.url(f.other), outside])
        }
        try require(f.service.presentation.names == oldNames, "Failed batch partially committed in memory")
        try require(try storedManifestBytes(f) == manifestBytes, "Failed batch partially committed to disk")
        try require(try fileTreeSnapshot(f.desktop) == before, "Failed batch changed actual files")
        let reopened = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try reopened.initialize()
        try reopened.hide()
        try require(!(try isHidden(f.url(f.other))), "Valid prefix of rejected batch leaked into restarted manifest")
        try reopened.restore()
    }
}

test("adding an existing target twice never duplicates its identity") {
    try Fixture("duplicate-add").withCleanup { f in
        let before = try fileTreeSnapshot(f.desktop)
        try f.service.addTargets([f.url(f.first), f.url(f.other), f.url(f.other)])
        try require(f.service.presentation.count == 3, "Duplicate candidate created duplicate target records")
        try require(Set(f.service.manifest.targets.map(\.identity)).count == 3, "Manifest contains duplicate identities")
        try require(try fileTreeSnapshot(f.desktop) == before, "Deduplicating candidates touched files")
        try f.service.hide()
        try f.service.restore()
        try require(f.layout.positions == f.originalPoints, "Duplicate add broke normal recovery")
    }
}

test("target write failure still repairs observers and retry preserves later user movement") {
    try Fixture("retry-latest-observer").withCleanup { f in
        try f.service.hide()
        f.layout.positions[f.first] = DesktopPoint(x: 1200, y: 750)
        f.layout.positionWriteFailuresRemaining = 1
        f.layout.onRefresh = { layout in
            if layout.refreshCount == 2 { layout.positions[f.other] = DesktopPoint(x: 1000, y: 800) }
        }
        try expectError("target write fails but observer repair should still run") { try f.service.restore() }
        try require(f.layout.positions[f.other] == f.originalPoints[f.other], "Target failure prevented independent observer repair")
        try require(f.layout.setPositionCalls.contains { $0[f.other] == f.originalPoints[f.other] }, "Observer repair was skipped after target failure")
        try require(fm.fileExists(atPath: f.journal.path), "Unfinished target recovery lost its journal")
        let pending = try JSONDecoder().decode(RecoverySession.self, from: Data(contentsOf: f.journal))
        try require(pending.phase == "recovery", "Unfinished target recovery has wrong phase")
        try require(pending.restoreObservers == nil, "Completed observer baseline was incorrectly frozen across retries")
        try require(!pending.rollback, "Completed rollback baseline should not be reused")

        let movedByUser = DesktopPoint(x: 850, y: 420)
        f.layout.positions[f.other] = movedByUser
        let callsBeforeRetry = f.layout.setPositionCalls.count
        let reopened = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try reopened.initialize()
        try reopened.restore()
        try require(f.layout.positions[f.other] == movedByUser, "Retry overwrote user's movement after the first failure")
        try require(f.layout.setPositionCalls.dropFirst(callsBeforeRetry).allSatisfy { $0[f.other] == nil }, "Retry wrote a completed observer's stale baseline")
        try require(f.layout.positions[f.first] == f.originalPoints[f.first], "Retry did not finish original target position")
        try require(reopened.presentation.mode == .visible, "Retry did not finish recovery")
        try require(!fm.fileExists(atPath: f.journal.path), "Successful retry left active journal")
    }
}

test("process interruption during hiding rolls back pre-hide observer positions") {
    try Fixture("interrupted-hiding").withCleanup { f in
        try f.service.hide()
        // Recreate the durable journal and on-disk flags of a process that exited
        // during hiding without executing hide()'s catch block.
        var interrupted = try JSONDecoder().decode(RecoverySession.self, from: Data(contentsOf: f.journal))
        interrupted.phase = "hiding"
        interrupted.rollback = false
        interrupted.restoreObservers = nil
        try atomicWrite(interrupted, to: f.journal)
        let folderFlags = try fileStat(f.url(f.folder)).st_flags & ~UInt32(UF_HIDDEN)
        try setFixtureFlags(f.url(f.folder), folderFlags)
        f.layout.positions[f.other] = DesktopPoint(x: 1000, y: 800)
        f.layout.positions[f.first] = DesktopPoint(x: 1100, y: 750)
        let reopened = DesktopPrivacyService(manifest: f.manifest, dataRoot: f.data, layout: f.layout)
        try reopened.initialize()
        try require(reopened.presentation.mode == .recovery, "Unfinished hiding was not recognized as recovery")
        try reopened.restore()
        try require(!(try isHidden(f.url(f.first))), "Interrupted first target remained hidden")
        try require(!(try isHidden(f.url(f.folder))), "Already-visible second target changed to hidden")
        try require(f.layout.positions == f.originalPoints, "Process interruption adopted drifted observer position instead of pre-hide position")
        try require(f.layout.setPositionCalls.contains { $0[f.other] == f.originalPoints[f.other] }, "Interrupted hiding did not repair original observer layout")
        try require(!fm.fileExists(atPath: f.journal.path), "Successful interrupted-hide rollback left journal")
        try require(reopened.presentation.mode == .visible, "Interrupted hide recovery did not complete")
    }
}

test("public first launch initializes an empty manifest without a bundled personal list") {
    try Fixture("public-first-launch").withCleanup { f in
        let support = f.root.appendingPathComponent("FirstLaunchSupport", isDirectory: true)
        let config = AppConfiguration(desktopURL: f.desktop, applicationSupportURL: support)
        let manifestURL = config.dataRoot.appendingPathComponent("manifest.json")
        let filesBefore = try fileTreeSnapshot(f.desktop)
        try require(!fm.fileExists(atPath: manifestURL.path), "First-launch fixture already contains a manifest")
        let empty = try config.makeEmptyManifest()
        try require(empty.targets.isEmpty, "Public configuration contains preselected targets")
        try require(empty.desktopIdentity == FileIdentity(try fileStat(f.desktop)), "Public manifest uses the wrong desktop identity")
        let service = try config.makeService(layout: f.layout)
        try service.initialize()
        try require(service.presentation.mode == .visible && service.presentation.count == 0, "Public first launch did not start empty")
        let stored = try JSONDecoder().decode(FixedManifest.self, from: Data(contentsOf: manifestURL))
        try require(stored.targets.isEmpty, "First launch persisted unexpected targets")
        try require(stored.desktop == config.desktopURL.path, "First launch persisted another desktop path")
        try expectError("public empty first launch cannot hide") { try service.hide() }
        try require(try fileTreeSnapshot(f.desktop) == filesBefore, "Empty first launch changed actual files")
    }
}

test("separate simulated users have independent empty lists and recovery sessions") {
    try Fixture("public-user-a").withCleanup { a in
        try Fixture("public-user-b").withCleanup { b in
            let configA = AppConfiguration(desktopURL: a.desktop,
                                           applicationSupportURL: a.root.appendingPathComponent("ApplicationSupport"))
            let configB = AppConfiguration(desktopURL: b.desktop,
                                           applicationSupportURL: b.root.appendingPathComponent("ApplicationSupport"))
            let serviceA = try configA.makeService(layout: a.layout)
            let serviceB = try configB.makeService(layout: b.layout)
            try serviceA.initialize(); try serviceB.initialize()
            try require(configA.dataRoot != configB.dataRoot, "Different users share the same state directory")
            try require(serviceA.presentation.count == 0 && serviceB.presentation.count == 0, "A fresh simulated user inherited targets")
            try serviceA.addTargets([a.url(a.first)])
            try serviceA.hide()
            try require(serviceB.presentation.count == 0, "User B inherited user A's target list")
            try require(!(try isHidden(b.url(b.first))), "User A hid user B's same-named file")
            try require(!fm.fileExists(atPath: configB.dataRoot.appendingPathComponent("recovery.json").path), "User A created user B's recovery record")
            try serviceB.addTargets([b.url(b.folder)])
            try serviceB.hide()
            try serviceA.restore()
            try require(try isHidden(b.url(b.folder)), "User A's restore changed user B's hidden session")
            try require(serviceB.presentation.mode == .hidden, "User A changed user B's presentation state")
            try serviceB.restore()
            try require(a.layout.positions == a.originalPoints && b.layout.positions == b.originalPoints, "Independent user restores lost a layout")
        }
    }
}

test("public initialization does not import or alter unrelated older application storage") {
    try Fixture("public-ignore-legacy").withCleanup { f in
        let support = f.root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        // A synthetic decoy represents an older product's private storage. No
        // real product identifier, home path, or personal target list is used.
        let legacy = support.appendingPathComponent("older-product-fixture", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try JSONEncoder().encode(f.manifest).write(to: legacy.appendingPathComponent("manifest.json"))
        try Data("unrelated and deliberately invalid recovery data".utf8)
            .write(to: legacy.appendingPathComponent("recovery.json"))
        let legacyBefore = try fileTreeSnapshot(legacy)
        let filesBefore = try fileTreeSnapshot(f.desktop)
        let config = AppConfiguration(desktopURL: f.desktop, applicationSupportURL: support)
        try require(config.dataRoot != legacy, "Public state location aliases the legacy fixture")
        let service = try config.makeService(layout: f.layout)
        try service.initialize()
        try require(service.presentation.count == 0, "Public edition imported an older target list")
        try require(service.presentation.mode == .visible, "Older recovery data influenced public startup")
        try service.addTargets([f.url(f.other)])
        try service.hide(); try service.restore()
        try require(try fileTreeSnapshot(legacy) == legacyBefore, "Public operation modified older storage")
        try require(try fileTreeSnapshot(f.desktop) == filesBefore, "Public operation changed file contents or structure")
    }
}

test("public reopening loads only its own saved list instead of resetting to empty") {
    try Fixture("public-reopen-own-state").withCleanup { f in
        let support = f.root.appendingPathComponent("PublicSupport", isDirectory: true)
        let config = AppConfiguration(desktopURL: f.desktop, applicationSupportURL: support)
        let service = try config.makeService(layout: f.layout)
        try service.initialize()
        try service.addTargets([f.url(f.other)])
        try service.hide()
        let reopened = try AppConfiguration(desktopURL: f.desktop, applicationSupportURL: support)
            .makeService(layout: f.layout)
        try reopened.initialize()
        try require(reopened.presentation.names == [f.other], "Public reopening lost its saved target list")
        try require(reopened.presentation.mode == .hidden, "Public reopening did not load its own recovery session")
        try reopened.restore()
        try require(!(try isHidden(f.url(f.other))), "Public reopened session did not restore the selected file")
        try require(!(try isHidden(f.url(f.first))) && !(try isHidden(f.url(f.folder))), "Public reopening affected unselected synthetic files")
        try require(f.layout.positions == f.originalPoints, "Public reopened session lost layout")
    }
}

test("public configuration refuses a missing desktop without creating or selecting another folder") {
    try Fixture("public-missing-desktop").withCleanup { f in
        let missing = f.root.appendingPathComponent("MissingDesktop", isDirectory: true)
        let support = f.root.appendingPathComponent("UnusedSupport", isDirectory: true)
        let before = try fileTreeSnapshot(f.desktop)
        let config = AppConfiguration(desktopURL: missing, applicationSupportURL: support)
        try expectError("missing injected desktop") { _ = try config.makeEmptyManifest() }
        try expectError("missing desktop service creation") { _ = try config.makeService(layout: f.layout) }
        try require(!fm.fileExists(atPath: missing.path), "Configuration created a missing desktop")
        try require(!fm.fileExists(atPath: config.dataRoot.path), "Invalid desktop created persistent state")
        try require(try fileTreeSnapshot(f.desktop) == before, "Invalid configuration touched another desktop")
    }
}

do { try fm.removeItem(at: fixtureBase) }
catch { failures.append("Temporary fixture cleanup failed: \(error)") }

print("\n\(passed) passed; \(failures.count) failed")
if !failures.isEmpty {
    for failure in failures { print("- \(failure)") }
    exit(1)
}
