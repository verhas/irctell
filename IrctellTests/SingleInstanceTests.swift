import XCTest
@testable import Irctell

final class SingleInstanceTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appending(path: "irctell-lock-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private var lockFile: URL { folder.appending(path: SingleInstance.fileName) }

    func testSecondClaimIsTurnedAwayAndToldWhoHasIt() throws {
        guard case .acquired(let fd) = SingleInstance.lock(at: lockFile, pid: 4242, path: "/Applications/Irctell.app") else {
            return XCTFail("the first claim should get the lock")
        }
        defer { close(fd) }

        // flock locks belong to the open file, so a second open in this same
        // process conflicts just as another process would.
        XCTAssertEqual(SingleInstance.lock(at: lockFile, pid: 7, path: "/tmp/Debug/Irctell.app"),
                       .held(by: .init(pid: 4242, path: "/Applications/Irctell.app")))
    }

    func testLockIsFreeAgainOnceTheHolderGoes() {
        guard case .acquired(let fd) = SingleInstance.lock(at: lockFile, pid: 1, path: "/a") else {
            return XCTFail("the first claim should get the lock")
        }
        close(fd) // what the end of the process does

        guard case .acquired(let again) = SingleInstance.lock(at: lockFile, pid: 2, path: "/b") else {
            return XCTFail("a lock nobody holds should be taken")
        }
        defer { close(again) }
        XCTAssertEqual(SingleInstance.holder(at: lockFile), .init(pid: 2, path: "/b"),
                       "the new holder replaces the old one in the file")
    }

    func testHolderUnknownWhenTheFileSaysNothingUseful() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "garbage".write(to: lockFile, atomically: true, encoding: .utf8)
        XCTAssertNil(SingleInstance.holder(at: lockFile))
    }
}
