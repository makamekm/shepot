import XCTest
import WhisperCore
@testable import Shepot

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AIEditorTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() { session.invalidateAndCancel(); StubProtocol.handler = nil }

    func testRequestAndResponsesParsing() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let stream = request.httpBodyStream!
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = stream.read(&bytes, maxLength: bytes.count)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(body["input"] as? String, "привет Маша")
            XCTAssertEqual(body["model"] as? String, "custom-model")
            XCTAssertNil(body["reasoning"])
            XCTAssertTrue((body["instructions"] as? String)?.contains("редактор голосовой диктовки") == true)
            return (200, Data(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"Привет, Маша!"}]}]}"#.utf8))
        }
        let result = try await AIEditor(session: session).edit("привет Маша", style: .clean, dictionary: [], model: "custom-model", key: "test-key")
        XCTAssertEqual(result, "Привет, Маша!")
    }
    func testDefaultModelUsesNoReasoningForLatency() async throws {
        StubProtocol.handler = { request in
            let stream = request.httpBodyStream!
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = stream.read(&bytes, maxLength: bytes.count)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, AIEditor.defaultModel)
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Готово."}]}]}"#.utf8))
        }
        _ = try await AIEditor(session: session).edit("готово", style: .clean, dictionary: [], model: AIEditor.defaultModel, key: "test")
    }
    func testIncompleteOutputIsNeverDeliveredAsComplete() async {
        StubProtocol.handler = { _ in (200, Data(#"{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}"#.utf8)) }
        do {
            _ = try await AIEditor(session: session).edit("текст", style: .clean, dictionary: [], model: "test", key: "test")
            XCTFail("Incomplete responses must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("не закончил")) }
    }
    func testInvalidKeyHasActionableError() async {
        StubProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await AIEditor(session: session).edit("текст", style: .clean, dictionary: [], model: "test", key: "test")
            XCTFail("401 must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("API-ключ")) }
    }
    func testEmptyResponseDoesNotEraseDictation() async {
        StubProtocol.handler = { _ in (200, Data(#"{"status":"completed","output":[]}"#.utf8)) }
        do {
            _ = try await AIEditor(session: session).edit("текст", style: .list, dictionary: [], model: "test", key: "test")
            XCTFail("Empty responses must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("не вернул текст")) }
    }
}
