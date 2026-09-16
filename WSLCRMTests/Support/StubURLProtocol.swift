import Foundation
@testable import WSLCRM

/// Routes requests from a test-specific URLSession to an async handler.
/// Each session carries a unique `X-Stub-Id` header so tests can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]

        static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(body.utf8),
                     headers: ["Content-Type": "application/json"].merging(headers) { _, new in new })
        }
    }

    typealias Handler = @Sendable (URLRequest) async throws -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private var loadingTask: Task<Void, Never>?

    /// Creates a session whose requests are answered by `handler`.
    static func session(handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub-Id": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request.withBodyStreamRead()
        let id = request.value(forHTTPHeaderField: "X-Stub-Id") ?? ""
        let handler = Self.lock.withLock { Self.handlers[id] }
        let box = ClientBox(protocolInstance: self, client: client)

        loadingTask = Task {
            guard let handler else {
                box.fail(URLError(.unsupportedURL))
                return
            }
            do {
                let stub = try await handler(request)
                box.finish(url: request.url!, stub: stub)
            } catch {
                box.fail(error)
            }
        }
    }

    /// URLProtocolClient is not Sendable; URLSession tolerates callbacks from any thread.
    private struct ClientBox: @unchecked Sendable {
        let protocolInstance: URLProtocol
        let client: URLProtocolClient?

        func finish(url: URL, stub: Response) {
            let response = HTTPURLResponse(url: url, statusCode: stub.status,
                                           httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        func fail(_ error: Error) {
            client?.urlProtocol(protocolInstance, didFailWithError: error)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}

extension URLRequest {
    /// URLSession moves `httpBody` into `httpBodyStream` before protocols see it.
    func withBodyStreamRead() -> URLRequest {
        guard httpBody == nil, let stream = httpBodyStream else { return self }
        var copy = self
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        copy.httpBody = data
        return copy
    }

    var jsonBody: [String: Any]? {
        guard let body = httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// Thread-safe counter for asserting how many times something happened.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    func increment(_ key: String) {
        lock.withLock { storage[key, default: 0] += 1 }
    }

    func value(_ key: String) -> Int {
        lock.withLock { storage[key, default: 0] }
    }
}

enum Fixture {
    /// Loads `WSLCRMTests/Fixtures/<name>.json` from the test bundle.
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name).json"])
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: data(name))
    }

    private final class BundleToken {}
}
