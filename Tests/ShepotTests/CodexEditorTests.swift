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
    func testNpmShimResolvesToBundledNativeBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shepot-npm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let vendor = "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin"
        #else
        let vendor = "node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin"
        #endif
        let package = root.appendingPathComponent("lib/node_modules/@openai/codex")
        let script = package.appendingPathComponent("bin/codex.js"), native = package.appendingPathComponent(vendor + "/codex")
        let link = root.appendingPathComponent("bin/codex")
        for directory in [script, native, link].map({ $0.deletingLastPathComponent() }) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "#!/usr/bin/env node\n".write(to: script, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: native, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: native.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
        XCTAssertEqual(URL(fileURLWithPath: CodexEditor.nativeExecutable(for: link.path)).resolvingSymlinksInPath(), native.resolvingSymlinksInPath())
        XCTAssertEqual(CodexEditor.nativeExecutable(for: "/bin/sleep"), "/bin/sleep")
    }
    func testChildThatDiesBeforeReadingInputReportsItsError() async throws {
        signal(SIGPIPE, SIG_IGN)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shepot-broken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'dyld: Library not loaded: libsimdjson.33.dylib' >&2\nexit 134\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let longDictation = String(repeating: "очень длинная диктовка ", count: 20_000)
        do {
            _ = try await CodexEditor().edit(longDictation, style: .clean, dictionary: [], executablePath: executable.path)
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("libsimdjson"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("диктовка"))
        }
    }
}
