import Foundation
import WhisperCore

struct EditedDictation {
    var text: String
    var usedAI: Bool
    var notice: String = ""
}

enum DictationEditing {
    static let maximumWait: TimeInterval = 12
    static func run(base: String, useAI: Bool, style: WritingStyle = .clean, timeout: TimeInterval = maximumWait,
                    operation: @escaping @Sendable () async throws -> String) async throws -> EditedDictation {
        guard useAI else { return EditedDictation(text: base, usedAI: false) }
        do {
            let edited = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw AppError.message("AI не ответил за \(Int(timeout)) секунд.")
                }
                defer { group.cancelAll() }
                guard let text = try await group.next(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppError.message("AI вернул пустой ответ.")
                }
                return text
            }
            try Task.checkCancellation()
            guard !isSuspiciouslyShort(edited, comparedTo: base) else {
                throw AppError.message("AI слишком сильно сократил длинную диктовку. Сохранён полный текст.")
            }
            let formatted = style == .list ? ListFormatting.normalizeEdited(edited) : edited
            return EditedDictation(text: formatted, usedAI: true)
        } catch {
            try Task.checkCancellation()
            return EditedDictation(text: base, usedAI: false, notice: "Без AI: \(error.localizedDescription) Использована базовая пунктуация.")
        }
    }

    /// A rough guard against a tiny summary, not a semantic completeness check.
    /// ASR can repeat whole passages. Counting those copies as new content rejected
    /// valid editing, so the lower bound uses the input's distinct words instead.
    private static func isSuspiciouslyShort(_ edited: String, comparedTo base: String) -> Bool {
        func words(_ text: String) -> [Substring] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }
        }
        let input = words(base)
        guard input.count >= 100 else { return false }
        let outputCount = words(edited).count
        return outputCount * 10 < Set(input).count * 6
    }
}
