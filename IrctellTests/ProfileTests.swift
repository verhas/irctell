import XCTest
@testable import Irctell

/// Profiles in a temporary home; deleting moves them to a folder of the
/// test's own, never to the user's Trash.
final class ProfileTests: XCTestCase {
    private var root: URL!
    private var trash: URL!
    private var profiles: Profiles!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString)")
        trash = root.appending(path: "trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        profiles = Profiles(root: root)
        profiles.discard = { [trash] in
            try FileManager.default.moveItem(at: $0, to: trash!.appending(path: $0.lastPathComponent))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheMainProfileIsTheHomeUntilAnotherIsChosen() throws {
        XCTAssertNil(profiles.current())
        XCTAssertEqual(profiles.names(), [])
        try profiles.create("work")
        try profiles.create("Anon")
        XCTAssertEqual(profiles.names(), ["Anon", "work"])
        XCTAssertNil(profiles.current(), "Creating one does not choose it")

        try profiles.choose("work")
        XCTAssertEqual(profiles.current(), "work")
        XCTAssertEqual(profiles.directory(of: "work").path, root.appending(path: "profiles/work").path)
        try profiles.choose(nil)
        XCTAssertNil(profiles.current())
        XCTAssertFalse(FileManager.default.fileExists(atPath: profiles.currentFile.path))
    }

    func testAChosenProfileThatIsGoneMeansTheMainOne() throws {
        try profiles.create("work")
        try profiles.choose("work")
        try FileManager.default.removeItem(at: profiles.directory(of: "work"))
        XCTAssertNil(profiles.current())
    }

    func testNamesThatCannotBeAFoldersAreRefused() throws {
        for name in ["", "  ", " work", "a/b", "a:b", ".hidden", "main", "Main", String(repeating: "x", count: 65)] {
            XCTAssertNotNil(Profiles.problem(with: name), name)
            XCTAssertThrowsError(try profiles.create(name), name)
        }
        XCTAssertNil(Profiles.problem(with: "Work – Libera"))
        try profiles.create("work")
        XCTAssertThrowsError(try profiles.create("Work"), "Folders do not differ by case")
    }

    func testDeletingMovesTheProfileAwayButNotTheOneInUse() throws {
        try profiles.create("work")
        try profiles.create("play")
        try Data("x".utf8).write(to: profiles.directory(of: "play").appending(path: "settings.plist"))

        XCTAssertThrowsError(try profiles.delete("work", inUse: "work"))
        XCTAssertThrowsError(try profiles.delete("nothing", inUse: nil))
        try profiles.delete("play", inUse: "work")
        XCTAssertEqual(profiles.names(), ["work"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appending(path: "play/settings.plist").path),
                      "Kept, to be put back")
    }

    func testDeletingTheChosenOneFromAnotherLaunchFallsBackToMain() throws {
        try profiles.create("work")
        try profiles.choose("work")
        try profiles.delete("work", inUse: nil)
        XCTAssertNil(profiles.current())
        XCTAssertFalse(FileManager.default.fileExists(atPath: profiles.currentFile.path))
    }
}
