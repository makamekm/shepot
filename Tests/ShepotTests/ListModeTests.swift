import XCTest
import WhisperCore
@testable import Shepot

final class ListModeTests: XCTestCase {
    func testAIParagraphIsNormalizedInActualEditingPipeline() async throws {
        let source = "Купить молоко. Позвонить Маше. Отправить отчёт."
        let result = try await DictationEditing.run(base: TextProcessing.clean(source, style: .list), useAI: true, style: .list) {
            "• Купить молоко. Позвонить Маше. Отправить отчёт."
        }
        XCTAssertEqual(result.text, "• Купить молоко.\n• Позвонить Маше.\n• Отправить отчёт.")
        XCTAssertTrue(result.usedAI)
    }

    func testTimeoutKeepsFullListRatherThanOneBullet() async throws {
        let phrases = (1...80).map { "Проверить задачу номер \($0) до завтра." }
        let base = TextProcessing.clean(phrases.joined(separator: " "), style: .list)
        let result = try await DictationEditing.run(base: base, useAI: true, style: .list, timeout: 0.02) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return "• Слишком поздний ответ."
        }
        XCTAssertFalse(result.usedAI)
        XCTAssertEqual(result.text.components(separatedBy: "\n"), phrases.map { "• " + $0 })
    }

    func testOtherStylesKeepParagraphs() async throws {
        let result = try await DictationEditing.run(base: "Черновик.", useAI: true, style: .business) {
            "Первое предложение. Второе предложение."
        }
        XCTAssertEqual(result.text, "Первое предложение. Второе предложение.")
    }

    /// Explicit manual integration check; normal test runs never send text outside the machine.
    func testLiveLunaSplitsUnpunctuatedDictationByMeaning() async throws {
        guard ProcessInfo.processInfo.environment["SHEPOT_RUN_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Реальный запрос к Codex запускается только явно через SHEPOT_RUN_LIVE_CODEX=1.")
        }
        let executable = try XCTUnwrap(CodexEditor.discoverExecutable())
        let source = """
        надо подготовить отчёт для Веры и отправить завтра до 18:30 в отчёт включить расходы за сентябрь и сравнение с августом ещё нужно проверить новую версию приложения 1.5 на старом макбуке особенно запись длиннее часа чтобы не пропадало начало диктовки по сайту надо заменить главную фотографию и поправить кнопку заявки на мобильном потому что она уезжает за край экрана потом договориться с Машей о встрече в пятницу после обеда и заранее прислать ей повестку отдельно по документам выгрузить все 250 строк в PDF и сохранить исходную таблицу без изменений а для поддержки написать инструкцию по установке и добавить в неё картинки с разрешениями микрофона и универсального доступа
        """
        let started = Date()
        let result = try await DictationEditing.run(base: TextProcessing.clean(source, style: .list), useAI: true, style: .list) {
            try await CodexEditor().edit(source, style: .list, dictionary: [], executablePath: executable)
        }
        print("Luna list probe: \(String(format: "%.1f", Date().timeIntervalSince(started))) s; \(result.text.components(separatedBy: "\n").count) items\n\(result.text)")
        XCTAssertTrue(result.usedAI, result.notice)
        let items = result.text.components(separatedBy: "\n")
        XCTAssertGreaterThanOrEqual(items.count, 5)
        XCTAssertLessThanOrEqual(items.count, 9)
        XCTAssertTrue(items.allSatisfy { $0.hasPrefix("• ") })
        for fact in ["18:30", "1.5", "250", "PDF", "сентябр", "август", "микрофон", "универсальн"] {
            XCTAssertTrue(result.text.localizedCaseInsensitiveContains(fact), "Missing: \(fact)")
        }
    }
}
