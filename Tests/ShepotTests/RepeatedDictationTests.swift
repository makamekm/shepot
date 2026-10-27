import XCTest
import WhisperCore
@testable import Shepot

final class RepeatedDictationTests: XCTestCase {
    static let source = """
    Так получается какие проблемы я прям щас вижу да кнопка Fullscreen должна быть одна и она должна открывать весь интерфейс весь сайт они вот конкретно видео да где-то пикнул Потом слева где значок идёт и собеседника нет я прям щас вижу две кнопки их не должно быть когда собеседника нет это получается репорт собеседника и всё Потом слева где значок идёт и собеседника нет я прям щас вижу две кнопки на их не должно быть собеседника нет это получается репорт собеседника и всё Следующие чаты Там цвета и те же Там цвета и те же Там цвета они и те же самые что и в оригинале это полеводы получается Сообщение чатах там стрелочка почему-то типа квадратик белый Сообщение чатах там стрелочка почему-то типа квадратик белый Следующая это мода lokki они выглядят не так же и крестик сверху не соответствуют Следующая это модалки они выглядят не так же и крестик сверху не соответствуют И ещё одно это кнопки где И ещё одно это кнопки где Под собеседником и под видео справа какая-то лишняя кнопка её у нас вообще нет там какие-то полоски у нас такого как бы Под собеседником и под видео справа какая-то лишняя кнопка её у нас вообще нет там какие-то полоски у нас такого как бы не было в оригинале.
    """
    static let edited = """
    • Кнопка Fullscreen должна быть одна и открывать весь интерфейс сайта, а не только видео.
    • Когда собеседника нет, слева не должны отображаться две кнопки, включая репорт собеседника.
    • Цвета чатов должны соответствовать оригиналу.
    • В сообщениях чата вместо стрелочки отображается белый квадратик.
    • Модальные окна и крестик сверху не соответствуют оригиналу.
    • Под собеседником и под видео справа есть лишняя кнопка с полосками, которой не было в оригинале.
    """

    func testRemovingRepeatedFeedbackDoesNotRejectEditedTextInEitherStyle() async throws {
        XCTAssertLessThan(Self.edited.split(whereSeparator: \.isWhitespace).count * 10,
                          Self.source.split(whereSeparator: \.isWhitespace).count * 6)
        for style in [WritingStyle.list, .business] {
            let result = try await DictationEditing.run(base: TextProcessing.clean(Self.source, style: style), useAI: true, style: style) {
                Self.edited
            }
            XCTAssertTrue(result.usedAI, result.notice)
            XCTAssertEqual(result.text, Self.edited)
        }
    }

    func testShortSummaryOfRepetitiveTextStillCannotReplaceAllDetails() async throws {
        let sentences = (1...100).map { "Нужно проверить отдельную задачу номер \($0) и сохранить её результат." }
        let source = sentences.joined(separator: " ")
        let result = try await DictationEditing.run(base: source, useAI: true) { "Проверить задачи." }
        XCTAssertFalse(result.usedAI)
        XCTAssertEqual(result.text, source)
    }

    func testRemovingDuplicatesFromLongTextKeepsEveryDistinctDetail() async throws {
        let facts = (1...100).map { "Проверить задачу номер \($0) и отправить результат." }
        let source = facts.map { Array(repeating: $0, count: 3).joined(separator: " ") }.joined(separator: " ")
        let edited = facts.joined(separator: " ")
        let result = try await DictationEditing.run(base: source, useAI: true) { edited }
        XCTAssertTrue(result.usedAI, result.notice)
        XCTAssertEqual(result.text, edited)
    }

    func testLiveLunaFormatsRepeatedFeedback() async throws {
        guard ProcessInfo.processInfo.environment["SHEPOT_RUN_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Реальный запрос к Codex запускается только явно через SHEPOT_RUN_LIVE_CODEX=1.")
        }
        let executable = try XCTUnwrap(CodexEditor.discoverExecutable())
        let started = Date()
        let result = try await DictationEditing.run(base: TextProcessing.clean(Self.source, style: .list), useAI: true, style: .list) {
            try await CodexEditor().edit(Self.source, style: .list, dictionary: [], executablePath: executable)
        }
        print("Repeated dictation probe: \(String(format: "%.1f", Date().timeIntervalSince(started))) s; AI=\(result.usedAI)\n\(result.text)\n\(result.notice)")
        XCTAssertTrue(result.usedAI, result.notice)
        let items = result.text.components(separatedBy: "\n")
        XCTAssertGreaterThanOrEqual(items.count, 5)
        XCTAssertLessThanOrEqual(items.count, 8)
        for fact in ["Fullscreen", "собеседник", "цвет", "стрел", "бел", "крестик", "полоск"] {
            XCTAssertTrue(result.text.localizedCaseInsensitiveContains(fact), "Missing: \(fact)")
        }
    }
}
