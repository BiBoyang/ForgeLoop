import Foundation

public protocol HTTPClient: Sendable {
    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>)
}

public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            let task = Task {
                do {
                    for try await byte in bytes {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}
