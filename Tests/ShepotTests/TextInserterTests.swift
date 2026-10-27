import XCTest
import AppKit
@testable import Shepot

@MainActor
private final class TestTextTarget: TextInputTarget {
    let appName = "Test input"
    var secure = false
    var problem: String?
    var acceptsSelection = true
    var throwsOnTyping = false
    var prefersKeyboardInput = false
    var ignoreReplacement = false
    var ignoreTyping = false
    var observable = true
    var problemAfterTyping: String?
    var valueAfterTyping: String?
    var state = TextInputState(value: "", selection: NSRange(location: 0, length: 0))
    var replacements: [String] = []
    var typed: [String] = []
    func focusProblem() -> String? { problem }
    func readState() -> TextInputState? { observable ? state : nil }
    func replaceSelection(_ text: String) -> Bool {
        if acceptsSelection {
            replacements.append(text)
            if !ignoreReplacement { state = TextInputState(value: text, selection: NSRange(location: text.utf16.count, length: 0)) }
        }
        return acceptsSelection
    }
    func typeUnicode(_ text: String) async throws {
        if throwsOnTyping { throw AppError.message("Ввод недоступен") }
        typed.append(text)
        if !ignoreTyping {
            let value = valueAfterTyping ?? text
            state = TextInputState(value: value, selection: NSRange(location: value.utf16.count, length: 0))
        }
        if let problemAfterTyping { problem = problemAfterTyping }
    }
}

final class TextInserterTests: XCTestCase {
    func testReadbackAcceptsEditorWhitespaceAndUnicodeNormalization() {
        let before = TextInputState(value: "", selection: NSRange(location: 0, length: 0))
        let actual = TextInputState(value: "\nКофе\u{00A0}и\u{202F}cafe\u{0301}.\n", selection: nil)
        XCTAssertTrue(actual.confirmsInsertion("Кофе и café.", from: before))
        XCTAssertFalse(actual.confirmsInsertion("Кофе и чай.", from: before))
    }
    @MainActor func testChangedFieldDoesNotTriggerMismatchErrorOrAnotherInsertion() async {
        let target = TestTextTarget()
        target.prefersKeyboardInput = true; target.valueAfterTyping = "Текст, изменённый редактором."
        let result = await TextInserter().deliver("Исходный текст.", to: target, modifiersDown: { false })
        XCTAssertEqual(result.outcome, .sentUnverified)
        XCTAssertTrue(result.shouldDismissHUD)
        XCTAssertFalse(result.inserted)
        XCTAssertEqual(target.typed.count, 1)
    }
    func testGrowingChatComposerKeepsIdentityByTopOrBottomAnchor() {
        let initial = CGRect(x: 100, y: 600, width: 700, height: 50)
        XCTAssertTrue(InputFieldGeometry.isSameField(initial, CGRect(x: 100, y: 500, width: 700, height: 150)))
        XCTAssertTrue(InputFieldGeometry.isSameField(initial, CGRect(x: 100, y: 600, width: 700, height: 150)))
        XCTAssertFalse(InputFieldGeometry.isSameField(initial, CGRect(x: 100, y: 400, width: 700, height: 50)))
    }
    @MainActor func testAXSuccessWithoutChangingTextFallsBackToKeyboard() async {
        let target = TestTextTarget()
        target.ignoreReplacement = true
        let result = await TextInserter().deliver("Реальный текст", to: target, modifiersDown: { false })
        XCTAssertTrue(result.inserted)
        XCTAssertEqual(target.typed, ["Реальный текст"])
        XCTAssertEqual(target.state.value, "Реальный текст")
    }
    @MainActor func testSilentSetterAndIgnoredTypingNeverReportInserted() async {
        let target = TestTextTarget(), before = NSPasteboard.general.changeCount
        target.ignoreReplacement = true; target.ignoreTyping = true
        let result = await TextInserter().deliver("Реальный текст", to: target, modifiersDown: { false })
        XCTAssertFalse(result.inserted)
        XCTAssertEqual(target.state.value, "")
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
    @MainActor func testExternalKeyboardPathDoesNotCallAXSetter() async {
        let target = TestTextTarget()
        target.prefersKeyboardInput = true
        let result = await TextInserter().deliver("Веб-поле", to: target, modifiersDown: { false })
        XCTAssertTrue(result.inserted)
        XCTAssertTrue(target.replacements.isEmpty)
        XCTAssertEqual(target.typed, ["Веб-поле"])
    }
    @MainActor func testUnreadableInputCannotReportConfirmedInsertion() async {
        let target = TestTextTarget()
        target.observable = false
        let result = await TextInserter().deliver("Текст", to: target, modifiersDown: { false })
        XCTAssertFalse(result.inserted)
        XCTAssertTrue(result.message.contains("не позволяет подтвердить"))
        XCTAssertEqual(result.outcome, .sentUnverified)
        XCTAssertTrue(result.shouldDismissHUD)
    }
    @MainActor func testVerifiedInsertionImmediatelyClosesHUD() async {
        let app = AppModel(), target = TestTextTarget()
        app.phase = .processing
        var closed = false
        app.hideHUD = { closed = true }
        app.completeInsertion(await TextInserter().deliver("Готовый текст", to: target, modifiersDown: { false }))
        XCTAssertTrue(closed)
        XCTAssertEqual(app.phase, .success)
        XCTAssertFalse(app.isBusy)
    }
    @MainActor func testOpaqueInputClosesHUDWithoutClaimingConfirmationOrLosingText() async {
        let app = AppModel(), target = TestTextTarget()
        target.observable = false
        app.lastText = "Готовый текст"
        app.phase = .processing
        var closed = false
        app.hideHUD = { closed = true }
        let before = NSPasteboard.general.changeCount
        app.completeInsertion(await TextInserter().deliver(app.lastText, to: target, modifiersDown: { false }))
        XCTAssertTrue(closed)
        XCTAssertEqual(app.phase, .unverified)
        XCTAssertTrue(app.message.contains("не позволяет подтвердить"))
        XCTAssertEqual(app.lastText, "Готовый текст")
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
    @MainActor func testRejectedInputKeepsHUDAndTextForRetry() async {
        let app = AppModel(), target = TestTextTarget()
        target.prefersKeyboardInput = true; target.ignoreTyping = true
        app.lastText = "Готовый текст"
        var closed = false
        app.hideHUD = { closed = true }
        app.completeInsertion(await TextInserter().deliver(app.lastText, to: target, modifiersDown: { false }))
        XCTAssertFalse(closed)
        XCTAssertEqual(app.phase, .error)
        XCTAssertEqual(app.lastText, "Готовый текст")
    }
    @MainActor func testFocusLostAfterSendingToOpaqueInputRemainsFailure() async {
        let target = TestTextTarget()
        target.observable = false; target.problemAfterTyping = "Фокус изменился"
        let result = await TextInserter().deliver("Текст", to: target, modifiersDown: { false })
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertFalse(result.shouldDismissHUD)
        XCTAssertEqual(result.message, "Фокус изменился")
    }
    func testReadbackVerifiesFullValueIncludingSelectionAndEmoji() {
        let before = TextInputState(value: "Привет, мир!", selection: NSRange(location: 8, length: 3))
        let expected = TextInputState(value: "Привет, Luna 👋!", selection: NSRange(location: 15, length: 0))
        XCTAssertTrue(expected.confirmsInsertion("Luna 👋", from: before))
        XCTAssertFalse(before.confirmsInsertion("Luna 👋", from: before))
        XCTAssertFalse(TextInputState(value: "Luna 👋", selection: nil).confirmsInsertion("Luna 👋", from: before))
    }
    @MainActor func testDirectInsertionDoesNotChangeClipboard() async {
        let target = TestTextTarget(), before = NSPasteboard.general.changeCount
        let result = await TextInserter().deliver("Привет!", to: target, modifiersDown: { false })
        XCTAssertTrue(result.inserted)
        XCTAssertEqual(target.replacements, ["Привет!"])
        XCTAssertTrue(target.typed.isEmpty)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
    @MainActor func testUnsupportedSelectionFallsBackToTypingWithoutClipboard() async {
        let target = TestTextTarget(), before = NSPasteboard.general.changeCount
        target.acceptsSelection = false
        let result = await TextInserter().deliver("Текст 👋", to: target, modifiersDown: { false })
        XCTAssertTrue(result.inserted)
        XCTAssertEqual(target.typed, ["Текст 👋"])
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
    @MainActor func testMissingTargetDoesNotCopyOrReportSuccess() async {
        let before = NSPasteboard.general.changeCount
        let result = await TextInserter().deliver("Текст", to: nil, modifiersDown: { false })
        XCTAssertFalse(result.inserted)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
    @MainActor func testFocusFailureDoesNotCopyOrType() async {
        let target = TestTextTarget(), before = NSPasteboard.general.changeCount
        target.problem = "Фокус изменился"
        let result = await TextInserter().deliver("Текст", to: target, modifiersDown: { false })
        XCTAssertFalse(result.inserted)
        XCTAssertEqual(result.message, "Фокус изменился")
        XCTAssertTrue(target.replacements.isEmpty && target.typed.isEmpty)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
    @MainActor func testSecureFieldDoesNotReceiveText() async {
        let target = TestTextTarget()
        target.secure = true
        let result = await TextInserter().deliver("Текст", to: target, modifiersDown: { false })
        XCTAssertFalse(result.inserted)
        XCTAssertTrue(target.replacements.isEmpty && target.typed.isEmpty)
    }
    @MainActor func testWaitsForStoppingControlToBeReleased() async {
        let target = TestTextTarget()
        var checks = 0
        let result = await TextInserter().deliver("Текст", to: target, modifiersDown: {
            checks += 1
            return checks < 3
        })
        XCTAssertGreaterThanOrEqual(checks, 3)
        XCTAssertTrue(result.inserted)
        XCTAssertEqual(target.replacements, ["Текст"])
    }
    @MainActor func testFailedTypingDoesNotCopyOrReportSuccess() async {
        let target = TestTextTarget(), before = NSPasteboard.general.changeCount
        target.acceptsSelection = false; target.throwsOnTyping = true
        let result = await TextInserter().deliver("Текст", to: target, modifiersDown: { false })
        XCTAssertFalse(result.inserted)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
    @MainActor func testNativeTextViewReplacesSelectionAtCaret() {
        _ = NSApplication.shared
        let view = NSTextView()
        view.string = "Привет, мир!"
        view.setSelectedRange(NSRange(location: 8, length: 3))
        let before = NSPasteboard.general.changeCount
        XCTAssertTrue(LocalTextTarget(responder: view).replaceSelection("Luna 👋"))
        XCTAssertEqual(view.string, "Привет, Luna 👋!")
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
    func testUnicodeChunksPreserveEmojiAndParagraphs() {
        let text = String(repeating: "Текст 👩🏽‍💻 и 🌿!\n", count: 20)
        let chunks = UnicodeInput.chunks(text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 })
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
    }
    func testKeyboardEventContainsUnicodeWithoutCommandOrControl() throws {
        let units = Array("Привет 👋".utf16)
        let (down, _) = try UnicodeInput.events(for: units)
        var actual = 0, buffer = [UniChar](repeating: 0, count: 64)
        down.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &actual, unicodeString: &buffer)
        XCTAssertEqual(Array(buffer.prefix(actual)), units)
        XCTAssertTrue(down.flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate]).isEmpty)
        XCTAssertNotEqual(down.getIntegerValueField(.keyboardEventKeycode), 9) // Never ⌘V.
    }
}
