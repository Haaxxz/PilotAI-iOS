import Foundation
import XCTest
#if canImport(PilotAI)
@testable import PilotAI
#endif

final class WorkspaceServiceTests: XCTestCase {
    private func fixture(_ body: (WorkspaceService, URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PilotAI-workspace-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        try body(WorkspaceService(rootURL: root), root, base)
    }

    func testRejectsTraversalAbsoluteEscapedAndReservedPaths() throws {
        let invalid = ["", ".", "..", "../providers.json", "a/../../x", "/etc/passwd", "a//b", "a/", "a/./b", "a/../b",
                       "a\\b", "%2e%2e/providers.json", "a/%2f/b", "a\0b", "x\ny", "file:///tmp/x", "~/x", ".env",
                       "providers.json", "nested/CONVERSATIONS.JSON", "keys.json", "mcp_servers.json", "a/.hidden/file"]
        try fixture { store, _, _ in
            for path in invalid {
                XCTAssertThrowsError(try store.writeText(path: path, text: "x", expectedRevision: "missing"), "Accepted \(path)")
            }
            XCTAssertEqual(try WorkspaceService.components("notes/hello world.txt"), ["notes", "hello world.txt"])
            XCTAssertEqual(try store.list().entries.count, 0)
            XCTAssertThrowsError(try store.delete(path: "", expectedRevision: "missing"))
        }
    }

    func testCreateReadAtomicReplaceAndRevisionConflicts() throws {
        try fixture { store, root, _ in
            let created = try store.writeText(path: "notes.txt", text: "first", expectedRevision: "missing")
            let first = try store.readText(path: "notes.txt")
            XCTAssertEqual(first.text, "first")
            XCTAssertEqual(first.revision, created.revision)
            let other = WorkspaceService(rootURL: root)
            let second = try other.writeText(path: "notes.txt", text: "second", expectedRevision: first.revision)
            XCTAssertNotEqual(first.revision, second.revision)
            XCTAssertThrowsError(try store.writeText(path: "notes.txt", text: "stale", expectedRevision: first.revision)) { error in
                XCTAssertEqual(error as? WorkspaceService.WorkspaceError, .conflict)
            }
            XCTAssertEqual(try store.readText(path: "notes.txt").text, "second")
            XCTAssertThrowsError(try store.writeText(path: "notes.txt", text: "overwrite", expectedRevision: "missing"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["notes.txt"])
        }
    }

    func testSameContentReplacementAndRecreationInvalidateRevision() throws {
        try fixture { store, _, _ in
            let a = try store.writeText(path: "a.txt", text: "same", expectedRevision: "missing")
            let b = try store.writeText(path: "a.txt", text: "same", expectedRevision: a.revision)
            XCTAssertNotEqual(a.revision, b.revision)
            try store.delete(path: "a.txt", expectedRevision: b.revision)
            _ = try store.writeText(path: "a.txt", text: "same", expectedRevision: "missing")
            XCTAssertThrowsError(try store.delete(path: "a.txt", expectedRevision: b.revision))
        }
    }

    func testConcurrentWritersOnlyOneRevisionWins() throws {
        try fixture { store, root, _ in
            let item = try store.writeText(path: "counter.txt", text: "initial", expectedRevision: "missing")
            let resultLock = NSLock()
            var successes = 0
            var conflicts = 0
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                do {
                    try WorkspaceService(rootURL: root).writeText(path: "counter.txt", text: "writer-\(index)", expectedRevision: item.revision)
                    resultLock.lock(); successes += 1; resultLock.unlock()
                } catch WorkspaceService.WorkspaceError.conflict {
                    resultLock.lock(); conflicts += 1; resultLock.unlock()
                } catch { XCTFail("Unexpected concurrent write failure: \(error)") }
            }
            XCTAssertEqual(successes, 1)
            XCTAssertEqual(conflicts, 7)
            XCTAssertTrue(try store.readText(path: "counter.txt").text.hasPrefix("writer-"))
        }
    }

    func testSymlinkLeafAndParentNeverExposeOutsideData() throws {
        try fixture { store, root, base in
            _ = try store.list()
            let outside = base.appendingPathComponent("private", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let secret = outside.appendingPathComponent("sensitive.txt")
            try Data("private-provider-secret".utf8).write(to: secret)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.txt"), withDestinationURL: secret)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder"), withDestinationURL: outside)
            for path in ["linked.txt", "linked-folder/sensitive.txt"] {
                XCTAssertThrowsError(try store.read(path: path))
                XCTAssertThrowsError(try store.writeText(path: path, text: "overwrite", expectedRevision: "missing"))
                XCTAssertThrowsError(try store.delete(path: path, expectedRevision: "missing"))
                XCTAssertThrowsError(try store.rename(path: path, to: "moved.txt", expectedRevision: "missing"))
            }
            XCTAssertThrowsError(try store.createDirectory(path: "linked-folder/new"))
            XCTAssertThrowsError(try store.list(path: "linked-folder"))
            XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "private-provider-secret")
            let listing = try store.list()
            XCTAssertTrue(listing.entries.isEmpty)
            XCTAssertEqual(listing.skippedUnsafeEntries, 2)
            let output = store.executeLocally(toolName: "workspace_read", arguments: "{\"path\":\"linked.txt\"}")
            XCTAssertTrue(output.hasPrefix("WORKSPACE_ERROR:"))
            XCTAssertFalse(output.contains("private-provider-secret"))
            XCTAssertFalse(output.contains(base.path))
        }
    }

    func testSymlinkRootAndRootReplacementAreRejected() throws {
        try fixture { store, root, base in
            _ = try store.list()
            let alias = base.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            XCTAssertThrowsError(try WorkspaceService(rootURL: alias).list())
            try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("old-workspace"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.list())
        }
    }

    func testDanglingSymlinkCannotBeReplacedByCreation() throws {
        try fixture { store, root, base in
            _ = try store.list()
            let link = root.appendingPathComponent("dangling.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("missing"))
            XCTAssertThrowsError(try store.writeText(path: "dangling.txt", text: "x", expectedRevision: "missing"))
            XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        }
    }

    func testHardLinksAreRejected() throws {
        try fixture { store, root, base in
            _ = try store.list()
            let outside = base.appendingPathComponent("outside.txt")
            try Data("private".utf8).write(to: outside)
            try FileManager.default.linkItem(at: outside, to: root.appendingPathComponent("hardlink.txt"))
            XCTAssertThrowsError(try store.read(path: "hardlink.txt"))
            XCTAssertThrowsError(try store.writeText(path: "hardlink.txt", text: "x", expectedRevision: "missing"))
            XCTAssertEqual(try store.list().skippedUnsafeEntries, 1)
            XCTAssertEqual(try Data(contentsOf: outside), Data("private".utf8))
        }
    }

    func testRenameProtectsDestinationAndChecksSourceRevision() throws {
        try fixture { store, _, _ in
            let a = try store.writeText(path: "a.txt", text: "A", expectedRevision: "missing")
            _ = try store.writeText(path: "b.txt", text: "B", expectedRevision: "missing")
            XCTAssertThrowsError(try store.rename(path: "a.txt", to: "b.txt", expectedRevision: a.revision))
            XCTAssertThrowsError(try store.rename(path: "a.txt", to: "c.txt", expectedRevision: "old"))
            XCTAssertEqual(try store.readText(path: "b.txt").text, "B")
            _ = try store.createDirectory(path: "folder")
            let moved = try store.rename(path: "a.txt", to: "folder/a.txt", expectedRevision: a.revision)
            XCTAssertEqual(moved.path, "folder/a.txt")
            XCTAssertEqual(try store.readText(path: moved.path).text, "A")
            XCTAssertThrowsError(try store.read(path: "a.txt"))
        }
    }

    func testDirectoriesRequireExistingParentsAndEmptyDeletion() throws {
        try fixture { store, _, _ in
            XCTAssertThrowsError(try store.createDirectory(path: "missing/child"))
            _ = try store.createDirectory(path: "folder")
            let child = try store.writeText(path: "folder/child.txt", text: "child", expectedRevision: "missing")
            let populated = try XCTUnwrap(store.list().entries.first)
            XCTAssertThrowsError(try store.delete(path: "folder", expectedRevision: populated.revision)) { error in
                XCTAssertEqual(error as? WorkspaceService.WorkspaceError, .notEmpty)
            }
            try store.delete(path: child.path, expectedRevision: child.revision)
            let empty = try XCTUnwrap(store.list().entries.first)
            try store.delete(path: empty.path, expectedRevision: empty.revision)
            XCTAssertTrue(try store.list().entries.isEmpty)
        }
    }

    func testBoundsAndBinaryTextHandling() throws {
        try fixture { store, root, _ in
            XCTAssertThrowsError(try store.writeText(path: "text.txt", text: String(repeating: "😀", count: 16_001), expectedRevision: "missing"))
            XCTAssertThrowsError(try store.write(path: "large.bin", data: Data(repeating: 1, count: WorkspaceService.maxFileBytes + 1), expectedRevision: "missing"))
            _ = try store.write(path: "binary.bin", data: Data([0xff, 0x00, 0xfe]), expectedRevision: "missing")
            XCTAssertEqual(try store.read(path: "binary.bin").data, Data([0xff, 0x00, 0xfe]))
            XCTAssertThrowsError(try store.readText(path: "binary.bin")) { error in XCTAssertEqual(error as? WorkspaceService.WorkspaceError, .notText) }
            try Data(repeating: 0, count: WorkspaceService.maxFileBytes + 1).write(to: root.appendingPathComponent("outside-writer.bin"))
            XCTAssertThrowsError(try store.read(path: "outside-writer.bin"))
            XCTAssertThrowsError(try store.read(path: "folder/"))
        }
    }

    func testListingIsBoundedAndReservedFilesStayHidden() throws {
        try fixture { store, root, _ in
            _ = try store.list()
            try Data("not-agent-data".utf8).write(to: root.appendingPathComponent("providers.json"))
            let hidden = try store.list()
            XCTAssertTrue(hidden.entries.isEmpty)
            XCTAssertEqual(hidden.skippedUnsafeEntries, 1)
            XCTAssertThrowsError(try store.read(path: "providers.json"))
            for i in 0...WorkspaceService.maxEntries {
                _ = try store.writeText(path: "file-\(i).txt", text: "", expectedRevision: "missing")
            }
            let listing = try store.list()
            XCTAssertEqual(listing.entries.count, WorkspaceService.maxEntries)
            XCTAssertTrue(listing.truncated)
        }
    }

    func testToolValidationAndHonestCapabilities() throws {
        try fixture { store, _, _ in
            XCTAssertTrue(store.executeLocally(toolName: "workspace_write", arguments: "{\"path\":\"x\",\"text\":\"x\"}").hasPrefix("WORKSPACE_ERROR:"))
            XCTAssertTrue(store.executeLocally(toolName: "workspace_list", arguments: "{\"path\":9}").hasPrefix("WORKSPACE_ERROR:"))
            XCTAssertTrue(store.executeLocally(toolName: "workspace_list", arguments: "{\"root\":\"/\"}").hasPrefix("WORKSPACE_ERROR:"))
            XCTAssertTrue(store.executeLocally(toolName: "workspace_read", arguments: "[]").hasPrefix("WORKSPACE_ERROR:"))
            XCTAssertTrue(store.executeLocally(toolName: "workspace_delete", arguments: "{}").hasPrefix("TOOL_UNAVAILABLE:"))
            let write = store.executeLocally(toolName: "workspace_write", arguments: "{\"path\":\"hello.txt\",\"text\":\"hello\",\"expected_revision\":\"missing\"}")
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(write.utf8)) as? [String: Any])
            XCTAssertEqual(receipt["saved"] as? Bool, true)
            XCTAssertEqual(try store.readText(path: "hello.txt").text, "hello")
            let names = WorkspaceService.toolSchemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            XCTAssertEqual(Set(names), ["workspace_list", "workspace_read", "workspace_write", "workspace_mkdir", "workspace_rename"])
        }
    }
}

#if WORKSPACE_STANDALONE_TESTS && os(Linux)
// Opt-in no-dependency Linux runner. Normal XCTest/SwiftPM discovery does not see a second
// entry point; enable this runner only with -D WORKSPACE_STANDALONE_TESTS.
@main
private enum WorkspaceLinuxTestRunner {
    static func main() {
        XCTMain([
            testCase([
                ("testRejectsTraversalAbsoluteEscapedAndReservedPaths", WorkspaceServiceTests.testRejectsTraversalAbsoluteEscapedAndReservedPaths),
                ("testCreateReadAtomicReplaceAndRevisionConflicts", WorkspaceServiceTests.testCreateReadAtomicReplaceAndRevisionConflicts),
                ("testSameContentReplacementAndRecreationInvalidateRevision", WorkspaceServiceTests.testSameContentReplacementAndRecreationInvalidateRevision),
                ("testConcurrentWritersOnlyOneRevisionWins", WorkspaceServiceTests.testConcurrentWritersOnlyOneRevisionWins),
                ("testSymlinkLeafAndParentNeverExposeOutsideData", WorkspaceServiceTests.testSymlinkLeafAndParentNeverExposeOutsideData),
                ("testSymlinkRootAndRootReplacementAreRejected", WorkspaceServiceTests.testSymlinkRootAndRootReplacementAreRejected),
                ("testDanglingSymlinkCannotBeReplacedByCreation", WorkspaceServiceTests.testDanglingSymlinkCannotBeReplacedByCreation),
                ("testHardLinksAreRejected", WorkspaceServiceTests.testHardLinksAreRejected),
                ("testRenameProtectsDestinationAndChecksSourceRevision", WorkspaceServiceTests.testRenameProtectsDestinationAndChecksSourceRevision),
                ("testDirectoriesRequireExistingParentsAndEmptyDeletion", WorkspaceServiceTests.testDirectoriesRequireExistingParentsAndEmptyDeletion),
                ("testBoundsAndBinaryTextHandling", WorkspaceServiceTests.testBoundsAndBinaryTextHandling),
                ("testListingIsBoundedAndReservedFilesStayHidden", WorkspaceServiceTests.testListingIsBoundedAndReservedFilesStayHidden),
                ("testToolValidationAndHonestCapabilities", WorkspaceServiceTests.testToolValidationAndHonestCapabilities)
            ]),
            testCase(BrowserURLPolicyTests.linuxTests)
        ])
    }
}
#endif
