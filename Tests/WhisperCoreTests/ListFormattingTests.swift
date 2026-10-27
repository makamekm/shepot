import XCTest
@testable import WhisperCore

final class ListFormattingTests: XCTestCase {
    func testParagraphBecomesSeveralItemsWithoutSpokenNewlines() {
        XCTAssertEqual(TextProcessing.clean("Купить молоко. Позвонить Маше. Отправить отчёт до 18:30.", style: .list),
                       "• Купить молоко.\n• Позвонить Маше.\n• Отправить отчёт до 18:30.")
    }

    func testSemicolonsAndSpokenEnumerationAreBoundaries() {
        XCTAssertEqual(ListFormatting.fallback("Нужна запись; текст должен сохраняться; окно закрывается после вставки."),
                       "• Нужна запись.\n• Текст должен сохраняться.\n• Окно закрывается после вставки.")
        XCTAssertEqual(ListFormatting.fallback("во-первых проверить запись во-вторых исправить вставку в-третьих закрыть окно"),
                       "• Во-первых проверить запись.\n• Во-вторых исправить вставку.\n• В-третьих закрыть окно.")
    }

    func testNumbersLinksAndAbbreviationsAreNotSplitAtEveryFullStop() {
        let output = ListFormatting.fallback("Проверить версию 1.5 на example.com. Отправить 10.5 рублей Маше.")
        XCTAssertEqual(output, "• Проверить версию 1.5 на example.com.\n• Отправить 10.5 рублей Маше.")
    }

    func testAIItemsKeepRelatedExplanationsTogether() {
        XCTAssertEqual(ListFormatting.normalizeEdited("- Отправить отчёт Вере. Срок — завтра до 18:30.\n- Проверить запись. Она должна продолжаться час."),
                       "• Отправить отчёт Вере. Срок — завтра до 18:30.\n• Проверить запись. Она должна продолжаться час.")
    }

    func testSingleHugeBulletAndProseAreReformatted() {
        let paragraph = "Отправить отчёт Вере. Проверить запись. Позвонить Маше."
        let expected = "• Отправить отчёт Вере.\n• Проверить запись.\n• Позвонить Маше."
        XCTAssertEqual(ListFormatting.normalizeEdited("• " + paragraph), expected)
        XCTAssertEqual(ListFormatting.normalizeEdited(paragraph), expected)
    }

    func testNumberedItemsAndWrappedDetailsStayTogether() {
        XCTAssertEqual(ListFormatting.normalizeEdited("1. Подготовить PDF.\n   Сохранить все 250 строк.\n2. Отправить Вере."),
                       "• Подготовить PDF. Сохранить все 250 строк.\n• Отправить Вере.")
    }

    func testLongFallbackKeepsEverySentenceInOrder() {
        let phrases = (1...300).map { "Задача номер \($0) должна сохранить все детали." }
        let output = TextProcessing.clean(phrases.joined(separator: " "), style: .list)
        XCTAssertEqual(output.components(separatedBy: "\n"), phrases.map { "• " + $0 })
        XCTAssertEqual(ListFormatting.fallback(output), output)
    }

    func testEmptyAndSingleThoughtStayValid() {
        XCTAssertEqual(ListFormatting.fallback(" \n "), "")
        XCTAssertEqual(ListFormatting.normalizeEdited("• Купить молоко."), "• Купить молоко.")
    }

    func testListPromptRequestsSemanticGroupingWithoutSummarizing() {
        let prompt = TextProcessing.prompt(style: .list, dictionary: [])
        XCTAssertTrue(prompt.contains("количество пунктов определяется смыслом"))
        XCTAssertTrue(prompt.contains("не дроби механически каждое предложение"))
        XCTAssertTrue(prompt.contains("не заменяй длинную диктовку кратким пересказом"))
        XCTAssertFalse(prompt.contains("Не добавляй новых пунктов"))
    }
}
