import Foundation
@testable import OpenBurnBarDaemon
import XCTest

/// A helper that exits without draining stdin used to raise SIGPIPE on the
/// daemon's write, killing the whole host process (xctest "unexpected signal
/// code 13"). Before the fix, a failure here is a crash of the test runner,
/// not an assertion.
final class BurnBarProjectCodeMemoryHelperProcessTests: XCTestCase {
    func test_a_helper_that_closes_stdin_and_exits_does_not_kill_the_host() {
        // 4 MiB is far past any pipe buffer, so the write blocks until the
        // helper drops its stdin and then must fail with EPIPE, every run.
        let payload = Data(repeating: UInt8(ascii: "x"), count: 4 * 1_024 * 1_024)
        for _ in 0..<5 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec 0<&-; exit 0"]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            XCTAssertTrue(BurnBarProjectCodeMemoryStore.runHelperProcess(process, input: input, payload: payload))
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func test_a_helper_that_ignores_stdin_still_reports_its_own_exit_status() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 0<&-; exit 3"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        XCTAssertTrue(BurnBarProjectCodeMemoryStore.runHelperProcess(
            process,
            input: input,
            payload: Data(repeating: 0, count: 1_024 * 1_024)
        ))
        XCTAssertEqual(process.terminationStatus, 3)
    }

    func test_git_output_hands_git_an_empty_stdin_instead_of_a_pipe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // `hash-object --stdin` hashes whatever stdin holds: /dev/null gives
        // the empty-blob id, while the old pipe fed git a stray "\n".
        XCTAssertEqual(
            BurnBarProjectCodeMemoryStore.gitOutput(root: root, arguments: ["hash-object", "--stdin"]),
            "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
        )
    }
}
