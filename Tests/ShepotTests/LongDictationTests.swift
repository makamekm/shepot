import XCTest
import AVFoundation
@testable import Shepot

final class LongDictationTests: XCTestCase {
    private let first = "Первая большая мысль уже распознана целиком и должна остаться в тексте навсегда."

    func testShortNewHypothesisAppendsInsteadOfClearingLongDraft() {
        var words = SpeechTranscript()
        words.accept(first)
        words.accept("Теперь")
        XCTAssertEqual(words.text, first + " Теперь")
        words.accept("Теперь продолжаю следующую мысль.")
        XCTAssertEqual(words.text, first + " Теперь продолжаю следующую мысль.")
    }
    func testReturningCumulativeResultDoesNotDuplicateFrozenPrefix() {
        var words = SpeechTranscript()
        words.accept(first)
        words.accept("Следующая мысль")
        words.accept(first + " Следующая мысль продолжается до конца.")
        XCTAssertEqual(words.text, first + " Следующая мысль продолжается до конца.")
    }
    func testNewPassageLongerThanPreviousOneStillAppends() {
        var words = SpeechTranscript()
        words.accept(first)
        let next = "Переходим дальше: завтра встречаемся утром возле офиса, обсуждаем бюджет, сроки поставки оборудования, распределение задач между участниками команды, затем отправляем подготовленные документы заказчику."
        words.accept(next)
        XCTAssertEqual(words.text, first + " " + next)
        words.accept(next + " После этого завершаем обсуждение.")
        XCTAssertEqual(words.text, first + " " + next + " После этого завершаем обсуждение.")
    }
    func testShorterStalePrefixCannotEraseExistingDraft() {
        var words = SpeechTranscript()
        words.accept(first)
        words.accept("Первая большая мысль уже распознана")
        XCTAssertEqual(words.text, first)
    }
    func testRepeatedPhraseAtLaterAudioPositionIsPreserved() {
        var words = SpeechTranscript()
        words.accept("Это важная мысль.", audioStart: 0, audioEnd: 2)
        words.accept("Это важная мысль.", audioStart: 5, audioEnd: 7)
        XCTAssertEqual(words.text, "Это важная мысль. Это важная мысль.")
    }
    func testLateTimingMetadataDoesNotDuplicateSameHypothesis() {
        var words = SpeechTranscript()
        words.accept(first, audioStart: 0, audioEnd: 0)
        words.accept(first, audioStart: 5, audioEnd: 12)
        XCTAssertEqual(words.text, first)
    }
    func testUnreliablePartialTimingsCannotTurnFinalCorrectionIntoDuplicate() {
        var words = SpeechTranscript()
        words.accept(first, audioStart: 0, audioEnd: 3, audioTimesReliable: false)
        words.accept(first, audioStart: 5, audioEnd: 12, audioTimesReliable: true)
        XCTAssertEqual(words.text, first)
    }
    func testAudioOverlapAddsOnlyNewWordsAtWindowBoundary() {
        var words = SpeechTranscript()
        words.accept("Сначала обсуждаем проект, затем подводим итоги встречи.")
        words.commit(overlapNext: true)
        words.accept("Итоги встречи. Теперь обсуждаем дальнейшие планы.")
        XCTAssertEqual(words.text, "Сначала обсуждаем проект, затем подводим итоги встречи. Теперь обсуждаем дальнейшие планы.")
    }
    func testEightyMinuteSessionRetainsEverySectionInOrder() {
        var words = SpeechTranscript(), expected: [String] = []
        for index in 0..<120 {
            XCTAssertTrue(SpeechWindowPolicy.shouldRotate(bufferedDuration: 40, requestAge: 40))
            let section = "Часть \(index): сохраняем начало и конец, контрольныймаркер\(index)."
            words.accept("Часть \(index)")
            words.accept(section)
            expected.append(section)
            XCTAssertEqual(words.text, expected.joined(separator: " "))
            words.commit(overlapNext: true)
        }
        XCTAssertEqual(words.text, expected.joined(separator: " "))
        XCTAssertTrue(words.text.contains("контрольныймаркер0"))
        XCTAssertTrue(words.text.contains("контрольныймаркер119"))
    }
    func testHandoverKeepsOverlapAndNewAudioWhileRecognizerChanges() throws {
        let feed = SpeechAudioFeed()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16000)
        for _ in 0..<40 { feed.append(buffer) }
        feed.rotate(retaining: SpeechWindowPolicy.overlap)
        XCTAssertEqual(feed.bufferedDuration, 3, accuracy: 0.001)
        for _ in 0..<5 { feed.append(buffer) }
        XCTAssertEqual(feed.bufferedDuration, 8, accuracy: 0.001)
        feed.rotate(retaining: SpeechWindowPolicy.overlap)
        XCTAssertEqual(feed.bufferedDuration, 3, accuracy: 0.001)
    }
    func testAISummaryCannotReplaceFullLongDictation() async throws {
        let base = (0..<300).map { "слово\($0)" }.joined(separator: " ")
        let result = try await DictationEditing.run(base: base, useAI: true) { "Краткий пересказ." }
        XCTAssertEqual(result.text, base)
        XCTAssertFalse(result.usedAI)
    }
    func testLongFallbackKeepsFirstAndLastWordsWithoutTruncation() async throws {
        let base = (0..<20_000).map { "слово\($0)" }.joined(separator: " ")
        let result = try await DictationEditing.run(base: base, useAI: true) { throw AppError.message("Нет сети") }
        XCTAssertEqual(result.text, base)
    }
    @MainActor func testLongSessionCheckpointUpdatesOneHistoryEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shepot-checkpoint-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(directory: directory)
        var entry = Dictation(original: first, text: first, style: .clean, duration: 40, app: "Test", usedAI: false)
        history.upsert(entry)
        entry.original += " Последняя фраза длинной записи."
        entry.text = entry.original; entry.duration = 3600
        history.upsert(entry)
        let saved = HistoryStore(directory: directory)
        XCTAssertEqual(saved.entries.count, 1)
        XCTAssertEqual(saved.entries[0].original, entry.original)
        XCTAssertEqual(saved.entries[0].duration, 3600)
    }
    @MainActor func testHourTimerDoesNotWrapAtSixtyMinutes() {
        let app = AppModel()
        app.elapsed = 3785
        XCTAssertEqual(app.timeLabel, "1:03:05")
    }
    func testLongTranscriptDisplayRetainsAllCharactersAndEmoji() {
        let text = (0..<2000).map { "Мысль \($0): длинный текст 👩🏽‍💻.\n" }.joined()
        let blocks = TranscriptDisplay.blocks(text)
        XCTAssertEqual(blocks.joined(), text)
        XCTAssertTrue(blocks.allSatisfy { $0.count <= 2400 })
        XCTAssertTrue(blocks.last!.contains("1999"))
    }
}
