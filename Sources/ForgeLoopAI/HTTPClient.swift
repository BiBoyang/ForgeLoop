import Foundation
import ForgeLoopDiagnostics

public protocol HTTPClient: Sendable {
    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        traceContext: TraceContext?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>)
}

public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession
    private let diagnostics: Diagnostics

    public init(
        session: URLSession = .shared,
        diagnostics: Diagnostics = Diagnostics()
    ) {
        self.session = session
        self.diagnostics = diagnostics
    }

    public func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        traceContext: TraceContext?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        let span = await diagnostics.trace.startSpan(
            name: "http.request",
            parent: traceContext,
            layer: "AI",
            operation: "stream",
            attributes: [
                "url": .string(url.absoluteString),
                "method": .string(method)
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            await diagnostics.trace.endSpan(
                span,
                attributes: ["status_code": .int(http.statusCode)],
                error: nil
            )

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
        } catch {
            await diagnostics.trace.endSpan(
                span,
                attributes: [:],
                error: TraceError(
                    type: "\(type(of: error))",
                    message: error.localizedDescription
                )
            )
            throw error
        }
    }
}
