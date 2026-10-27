import Foundation
import WhisperCore

struct AIEditor {
    static let defaultModel = "gpt-5.6-terra"
    var session: URLSession = .shared
    func edit(_ text: String, style: WritingStyle, dictionary: [DictionaryEntry], model: String, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = DictationEditing.maximumWait
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = [
            "model": modelID,
            "instructions": TextProcessing.prompt(style: style, dictionary: dictionary),
            "input": text,
            "store": false,
            "max_output_tokens": 4096
        ]
        if modelID == Self.defaultModel { body["reasoning"] = ["effort": "none"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("OpenAI вернул некорректный ответ.") }
        guard (200...299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw AppError.message("Проверьте API-ключ OpenAI в настройках.")
            case 429: throw AppError.message("Лимит OpenAI исчерпан. Проверьте баланс или повторите позже.")
            default: throw AppError.message("OpenAI недоступен (HTTP \(http.statusCode)). Проверьте модель и подключение.")
            }
        }
        struct Response: Decodable {
            struct Output: Decodable {
                struct Content: Decodable { var type: String; var text: String? }
                var type: String
                var content: [Content]?
            }
            var status: String
            var output: [Output]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.status == "completed" else { throw AppError.message("AI не закончил редактуру. Исходный текст сохранён.") }
        let edited = decoded.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }.filter { $0.type == "output_text" }.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty else { throw AppError.message("AI не вернул текст. Исходная диктовка сохранена.") }
        return edited
    }
}
