import Foundation
@testable import ForgeLoopAI

/// Generic HTTP client stub for provider contract tests.
/// Returns a fixed SSE payload regardless of request URL/method.
public final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let response: HTTPURLResponse
    private let bytes: [UInt8]
    private let delayNanos: UInt64

    public init(statusCode: Int, payload: String, delayNanos: UInt64 = 0) {
        self.response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        self.bytes = Array(payload.utf8)
        self.delayNanos = delayNanos
    }

    public func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        let response = self.response
        let bytes = self.bytes
        let delayNanos = self.delayNanos
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            let task = Task {
                do {
                    for byte in bytes {
                        if delayNanos > 0 {
                            try await Task.sleep(nanoseconds: delayNanos)
                        }
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (response, stream)
    }
}
