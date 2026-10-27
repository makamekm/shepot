import XCTest
import WhisperCore
@testable import Shepot

final class CodexEditorTests: XCTestCase {
    func testParsesFinalMessageAndRequiresCompletedTurn() throws {
        let output = """
        {"type":"thread.started","thread_id":"test"}
        {"type":"item.completed","item":{"type":"reasoning","text":"not user text"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Готовый текст."}}
        {"type":"turn.completed"}
        """
        XCTAssertEqual(try CodexEditor.parseOutput(Data(output.utf8)), "Готовый текст.")
        XCTAssertThrowsError(try CodexEditor.parseOutput(Data(output.replacingOccurrences(of: "{\"type\":\"turn.completed\"}", with: "").utf8)))
    }
    func testFailedOrEmptyTurnNeverBecomesDictation() {
        for output in ["{\"type\":\"turn.completed\"}", "{\"type\":\"turn.failed\"}", "garbage", ""] {
            XCTAssertThrowsError(try CodexEditor.parseOutput(Data(output.utf8)))
        }
    }
    func testCLIReceivesDictationThroughStdinAndUsesLuna() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shepot-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex"), prompt = directory.appendingPathComponent("prompt"), args = directory.appendingPathComponent("args")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(args.path)'
        /bin/cat > '\(prompt.path)'
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Встретимся завтра."}}' '{"type":"turn.completed"}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let raw = "ну давай завтра $(echo NOT_A_COMMAND)"
        let edited = try await CodexEditor().edit(raw, style: .clean, dictionary: [], executablePath: executable.path)
        XCTAssertEqual(edited, "Встретимся завтра.")
        let sent = try String(contentsOf: prompt, encoding: .utf8), arguments = try String(contentsOf: args, encoding: .utf8)
        XCTAssertTrue(sent.contains(raw))
        XCTAssertFalse(arguments.contains(raw))
        XCTAssertTrue(arguments.contains("gpt-6-luna"))
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("read-only"))
    }
    func testChildProcessTimeoutIsBounded() async {
        do {
            _ = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("не ответил")) }
    }
    func testCancelledChildProcessDoesNotReturnOutput() async {
        let task = Task { try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
