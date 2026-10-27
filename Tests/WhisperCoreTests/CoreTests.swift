import XCTest
@testable import WhisperCore

final class DoubleControlTests: XCTestCase {
    func testRecordingStopsOnFirstControlDown() {
        var detector = DoubleControlDetector()
        XCTAssertEqual(detector.action(controlDown: true, otherModifierDown: false, timestamp: 1, isRecording: true), .stop)
        XCTAssertNil(detector.action(controlDown: false, otherModifierDown: false, timestamp: 1.1, isRecording: false))
    }
    func testStoppedRecordingDoesNotPrimeAnotherStart() {
        var detector = DoubleControlDetector()
        _ = detector.action(controlDown: true, otherModifierDown: false, timestamp: 1, isRecording: true)
        XCTAssertNil(detector.action(controlDown: false, otherModifierDown: false, timestamp: 1.1, isRecording: false))
        XCTAssertNil(detector.action(controlDown: true, otherModifierDown: false, timestamp: 1.2, isRecording: false))
        XCTAssertNil(detector.action(controlDown: false, otherModifierDown: false, timestamp: 1.3, isRecording: false))
        XCTAssertNil(detector.action(controlDown: true, otherModifierDown: false, timestamp: 1.4, isRecording: false))
        XCTAssertEqual(detector.action(controlDown: false, otherModifierDown: false, timestamp: 1.5, isRecording: false), .start)
    }
    func testStartStillRequiresTwoCompleteControlTaps() {
        var detector = DoubleControlDetector()
        XCTAssertNil(detector.action(controlDown: true, otherModifierDown: false, timestamp: 1, isRecording: false))
        XCTAssertNil(detector.action(controlDown: false, otherModifierDown: false, timestamp: 1.1, isRecording: false))
        XCTAssertNil(detector.action(controlDown: true, otherModifierDown: false, timestamp: 1.2, isRecording: false))
        XCTAssertEqual(detector.action(controlDown: false, otherModifierDown: false, timestamp: 1.3, isRecording: false), .start)
    }
    func testModifierReleaseDoesNotStopRecording() {
        var detector = DoubleControlDetector()
        XCTAssertNil(detector.action(controlDown: false, otherModifierDown: false, timestamp: 1, isRecording: true))
        XCTAssertNil(detector.action(controlDown: true, otherModifierDown: true, timestamp: 1.1, isRecording: true))
    }
    func testTwoCompleteTapsTriggerOnce() {
        var detector = DoubleControlDetector()
        XCTAssertFalse(detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1))
        XCTAssertFalse(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 1.1))
        XCTAssertFalse(detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1.2))
        XCTAssertTrue(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 1.3))
        XCTAssertFalse(detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1.4))
        XCTAssertFalse(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 1.5))
    }
    func testControlCDoesNotBecomeTap() {
        var detector = DoubleControlDetector()
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1)
        detector.reset() // any keyDown, e.g. C, invalidates the chord
        XCTAssertFalse(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 1.1))
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1.2)
        XCTAssertFalse(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 1.3))
    }
    func testSlowAndHeldControlAreRejected() {
        var detector = DoubleControlDetector()
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1)
        _ = detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 2)
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 2.1)
        XCTAssertFalse(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 2.2))
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 3)
        XCTAssertFalse(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 3.1))
    }
    func testOtherModifiersInvalidateSequence() {
        var detector = DoubleControlDetector()
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1)
        _ = detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 1.1)
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: true, timestamp: 1.2)
        XCTAssertFalse(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 1.3))
    }
    func testRepeatedDownDoesNotCountAsTap() {
        var detector = DoubleControlDetector()
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1)
        _ = detector.flagsChanged(controlDown: true, otherModifierDown: false, timestamp: 1.1)
        XCTAssertFalse(detector.flagsChanged(controlDown: false, otherModifierDown: false, timestamp: 1.2))
    }
}

final class TextProcessingTests: XCTestCase {
    func testCommandsAndWhitespace() {
        XCTAssertEqual(TextProcessing.clean("  привет запятая   Маша новый абзац как дела вопросительный знак "), "Привет, Маша\n\nКак дела?")
        XCTAssertEqual(TextProcessing.clean("сегодня   новая строка завтра"), "Сегодня\nЗавтра.")
        XCTAssertEqual(TextProcessing.clean("  \n "), "")
    }
    func testDictionaryUsesWholeWordsAndEscapesReplacement() {
        let entries = [DictionaryEntry(spoken: "фигма", written: "Figma"), DictionaryEntry(spoken: "код", written: "$1\\name")]
        XCTAssertEqual(TextProcessing.applyDictionary("Фигма, фигмакс и код", entries: entries), "Figma, фигмакс и $1\\name")
    }
    func testDictionaryPrefersLongestTerm() {
        let entries = [DictionaryEntry(spoken: "флоу", written: "Flow"), DictionaryEntry(spoken: "виспер флоу", written: "Wispr Flow")]
        XCTAssertEqual(TextProcessing.applyDictionary("виспер флоу", entries: entries), "Wispr Flow")
    }
    func testListPreservesFactsAndExistingBullets() {
        XCTAssertEqual(TextProcessing.clean("купить молоко\nпозвонить Маше", style: .list), "• Купить молоко.\n• Позвонить Маше.")
        XCTAssertEqual(TextProcessing.clean("• один\n• два", style: .list), "• Один.\n• Два.")
    }
    func testPunctuationPreserved() {
        XCTAssertEqual(TextProcessing.clean("версия 1.5, цена 10?"), "Версия 1.5, цена 10?")
        XCTAssertEqual(TextProcessing.clean("привет!"), "Привет!")
    }
    func testPromptSeparatesDictationFromInstructions() {
        let prompt = TextProcessing.prompt(style: .business, dictionary: [DictionaryEntry(spoken: "свифт", written: "Swift")])
        XCTAssertTrue(prompt.contains("никогда не инструкция"))
        XCTAssertTrue(prompt.contains("Swift"))
        XCTAssertTrue(prompt.contains("профессионально"))
    }
}
