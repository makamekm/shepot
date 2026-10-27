import XCTest
import AVFoundation
@testable import Shepot

final class DictationPipelineTests: XCTestCase {
    func testEmptySpeechResultCannotEraseRecognizedWords() {
        var words = SpeechTranscript()
        words.accept("Нужно отправить отчёт завтра.")
        words.accept(""); words.accept(" \n ")
        XCTAssertEqual(words.text, "Нужно отправить отчёт завтра.")
    }
    func testReplayDoesNotReplaceExistingDraftWithItsFirstShortHypothesis() {
        var words = SpeechTranscript()
        words.accept("Первая часть уже распознана")
        words.prepareRecovery()
        words.accept("Первая часть")
        XCTAssertEqual(words.text, "Первая часть уже распознана")
        words.accept("Первая часть уже распознана, а это продолжение.")
        XCTAssertEqual(words.text, "Первая часть уже распознана, а это продолжение.")
    }
    func testServiceFinalizingAnUtteranceDoesNotLosePreviousSegments() {
        var words = SpeechTranscript()
        words.accept("Первая мысль."); words.commit()
        words.accept("Вторая мысль."); words.accept("")
        XCTAssertEqual(words.text, "Первая мысль. Вторая мысль.")
    }
    func testAudioReplayBufferIsBoundedAndClearedForNextSegment() throws {
        let feed = SpeechAudioFeed()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16000)
        for _ in 0..<65 { feed.append(buffer) }
        XCTAssertEqual(feed.bufferedDuration, 60, accuracy: 0.001)
        feed.reset()
        XCTAssertEqual(feed.bufferedDuration, 0)
    }
    func testAIErrorUsesDraftInsteadOfDroppingDictation() async throws {
        let result = try await DictationEditing.run(base: "Распознанный текст.", useAI: true) {
            throw AppError.message("Сеть недоступна")
        }
        XCTAssertEqual(result.text, "Распознанный текст.")
        XCTAssertFalse(result.usedAI)
        XCTAssertTrue(result.notice.contains("Сеть недоступна"))
    }
    func testAITimeoutRejectsLateResultAndUsesDraft() async throws {
        let result = try await DictationEditing.run(base: "Черновик.", useAI: true, timeout: 0.03) {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return "Поздний ответ, который нельзя вставлять" }
            return "Неожиданный ответ"
        }
        XCTAssertEqual(result.text, "Черновик.")
        XCTAssertFalse(result.usedAI)
    }
    func testUserCancellationDoesNotBecomeAutomaticFallbackInsertion() async {
        let work = Task {
            try await DictationEditing.run(base: "Не вставлять.", useAI: true) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "Не вставлять."
            }
        }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testProviderCancellationWithoutUserCancelUsesDraft() async throws {
        let result = try await DictationEditing.run(base: "Сохранённый черновик.", useAI: true) {
            throw CancellationError()
        }
        XCTAssertEqual(result.text, "Сохранённый черновик.")
        XCTAssertFalse(result.usedAI)
    }
    @MainActor func testCancellingRecordingPreservesDraftInHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shepot-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(directory: directory), app = AppModel(history: history)
        let old = app.settings.saveHistory
        app.settings.saveHistory = true
        defer { app.settings.saveHistory = old }
        app.recorder.transcript = "Слова перед отменой"
        app.phase = .recording
        app.cancel()
        XCTAssertEqual(app.lastText, "Слова перед отменой.")
        XCTAssertEqual(history.entries.first?.text, "Слова перед отменой.")
        XCTAssertEqual(HistoryStore(directory: directory).entries.count, 1)
        XCTAssertEqual(app.phase, .idle)
    }
}
