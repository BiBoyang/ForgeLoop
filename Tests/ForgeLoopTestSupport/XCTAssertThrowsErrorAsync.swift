import XCTest

/// Asserts that an async expression throws an error.
public func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #file,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw, but it did not", file: file, line: line)
    } catch {
        // Expected
    }
}
