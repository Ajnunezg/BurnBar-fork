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
            let process = shellHelper("exec 0<&-; exit 0")

            XCTAssertEqual(BurnBarProjectCodeMemoryStore.runHelperProcess(process, stdin: payload), Data())
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func test_a_helper_that_ignores_stdin_still_reports_its_own_exit_status() {
        let process = shellHelper("exec 0<&-; exit 3")

        XCTAssertNotNil(BurnBarProjectCodeMemoryStore.runHelperProcess(
            process,
            stdin: Data(repeating: 0, count: 1_024 * 1_024)
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

    // A pipe holds ~64 KB. Before stdout and stderr were drained while the
    // helper ran, a helper that wrote more blocked on write, never exited,
    // and was killed at the timeout: `git status --ignored -uall` in any repo
    // with node_modules came back empty. These must finish far inside the
    // 5 s default timeout.

    func test_a_helper_writing_far_past_the_pipe_buffer_returns_all_of_its_stdout() throws {
        let process = shellHelper("head -c 1000000 /dev/zero")
        let started = Date()

        let output = try XCTUnwrap(BurnBarProjectCodeMemoryStore.runHelperProcess(process))

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output, Data(count: 1_000_000))
    }

    func test_a_helper_flooding_stderr_still_exits_and_keeps_stdout_clean() throws {
        let process = shellHelper("head -c 1000000 /dev/zero >&2; printf done")
        let started = Date()

        let output = try XCTUnwrap(BurnBarProjectCodeMemoryStore.runHelperProcess(process))

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output, Data("done".utf8))
    }

    func test_a_helper_echoing_a_large_stdin_does_not_deadlock_against_its_own_output() throws {
        // `cat` writes as it reads, so 4 MiB each way needs stdin fed while
        // stdout is drained.
        let payload = Data(repeating: UInt8(ascii: "y"), count: 4 * 1_024 * 1_024)
        let process = shellHelper("cat")

        let output = try XCTUnwrap(BurnBarProjectCodeMemoryStore.runHelperProcess(
            process,
            stdin: payload,
            maxOutputBytes: .max
        ))

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output, payload + Data("\n".utf8))
    }

    func test_output_past_the_cap_is_rejected_and_the_helper_is_stopped_early() {
        let process = shellHelper("head -c 100000000 /dev/zero")
        let started = Date()

        XCTAssertNil(BurnBarProjectCodeMemoryStore.runHelperProcess(process, maxOutputBytes: 64 * 1_024))

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(process.isRunning)
    }

    func test_git_ignored_paths_reads_a_status_listing_past_the_pipe_buffer() throws {
        let root = try makeRepository(ignoring: "*.log\n")
        defer { try? FileManager.default.removeItem(at: root) }
        // 2,000 entries of ~50 bytes each is ~100 KB of porcelain output.
        let name = String(repeating: "m", count: 40)
        for index in 0..<2_000 {
            FileManager.default.createFile(atPath: root.appendingPathComponent("\(name)-\(index).log").path, contents: nil)
        }

        let ignored = try XCTUnwrap(BurnBarProjectCodeMemoryStore.gitIgnoredPaths(root: root))

        XCTAssertEqual(ignored.count, 2_000)
        XCTAssertTrue(ignored.contains("\(name)-1999.log"))
    }

    func test_ignore_pruning_falls_back_to_gitignore_when_git_status_overflows_the_cap() throws {
        // Glob-ignored files stay one status entry each, so a big enough
        // generated tree overflows the cap. That must not read as "nothing
        // is ignored" and let every generated file into the index.
        setenv("OPENBURNBAR_CODE_HELPER_MAX_OUTPUT_BYTES", "16384", 1)
        defer { unsetenv("OPENBURNBAR_CODE_HELPER_MAX_OUTPUT_BYTES") }
        let root = try makeRepository(ignoring: "*.generated.swift\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let name = String(repeating: "g", count: 40)
        for index in 0..<1_000 {
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("\(name)-\(index).generated.swift").path,
                contents: Data("let x = 1\n".utf8)
            )
        }
        FileManager.default.createFile(atPath: root.appendingPathComponent("Kept.swift").path, contents: Data("let y = 2\n".utf8))

        XCTAssertNil(BurnBarProjectCodeMemoryStore.gitIgnoredPaths(root: root))
        let files = BurnBarProjectCodeMemoryStore.enumerateIndexableFiles(root: root, maxFiles: 5_000)

        XCTAssertEqual(files.map(\.lastPathComponent), ["Kept.swift"])
    }

    func test_git_ignored_paths_collapses_an_ignored_tree_to_its_directory() throws {
        // `-uall` listed every file under node_modules on every index poll;
        // the directory entry alone must still prune the whole tree.
        let root = try makeRepository(ignoring: "node_modules/\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("node_modules/pkg/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0..<500 {
            FileManager.default.createFile(atPath: nested.appendingPathComponent("\(index).js").path, contents: nil)
        }

        let ignored = try XCTUnwrap(BurnBarProjectCodeMemoryStore.gitIgnoredPaths(root: root))

        XCTAssertEqual(ignored, ["node_modules"])
        XCTAssertTrue(BurnBarProjectCodeMemoryStore.isGitIgnored(
            "node_modules/pkg/lib/7.js",
            isDirectory: false,
            ignoredPaths: ignored
        ))
    }

    private func makeRepository(ignoring patterns: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = BurnBarProjectCodeMemoryStore.gitOutput(root: root, arguments: ["init", "-q"])
        XCTAssertTrue(BurnBarProjectCodeMemoryStore.isGitWorktree(root: root))
        try Data(patterns.utf8).write(to: root.appendingPathComponent(".gitignore"))
        return root
    }

    private func shellHelper(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }
}
