import XCTest
@testable import ForgeLoopAgent

final class ToolArgsValidationTests: XCTestCase {

    // MARK: - Schema Definition

    private let testSchema = ToolArgsSchema(fields: [
        ToolArgField(name: "path", type: .string, required: true),
        ToolArgField(name: "content", type: .string, required: true),
        ToolArgField(name: "timeoutMs", type: .numberOrString, required: false),
        ToolArgField(name: "recursive", type: .bool, required: false),
    ])

    // MARK: - invalid_json

    func testInvalidJsonReturnsInvalidJsonError() {
        let result = ToolArgsValidator.validate("not json", schema: testSchema)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].code, .invalidJson)
        XCTAssertTrue(errors[0].message.contains("Invalid JSON"))
    }

    func testInvalidUtf8ReturnsInvalidJsonError() {
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: "test".utf8)
        let json = String(data: data, encoding: .utf8) ?? ""
        let result = ToolArgsValidator.validate(json, schema: testSchema)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertEqual(errors[0].code, .invalidJson)
    }

    func testNonObjectJsonReturnsInvalidJsonError() {
        let result = ToolArgsValidator.validate("[1, 2, 3]", schema: testSchema)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertEqual(errors[0].code, .invalidJson)
        XCTAssertTrue(errors[0].message.contains("object"))
    }

    // MARK: - missing_required

    func testMissingRequiredField() {
        let result = ToolArgsValidator.validate("{\"content\":\"hello\"}", schema: testSchema)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        let missingErrors = errors.filter { $0.code == .missingRequired }
        XCTAssertEqual(missingErrors.count, 1)
        XCTAssertEqual(missingErrors[0].path, "$.path")
        XCTAssertTrue(missingErrors[0].message.contains("path"))
    }

    func testMultipleMissingRequiredFields() {
        let result = ToolArgsValidator.validate("{}", schema: testSchema)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        let missingErrors = errors.filter { $0.code == .missingRequired }
        XCTAssertEqual(missingErrors.count, 2)
        XCTAssertTrue(missingErrors.contains { $0.path == "$.path" })
        XCTAssertTrue(missingErrors.contains { $0.path == "$.content" })
    }

    // MARK: - invalid_type

    func testInvalidTypeForStringField() {
        let result = ToolArgsValidator.validate(
            "{\"path\":123,\"content\":\"hello\"}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        let typeErrors = errors.filter { $0.code == .invalidType }
        XCTAssertEqual(typeErrors.count, 1)
        XCTAssertEqual(typeErrors[0].path, "$.path")
        XCTAssertTrue(typeErrors[0].message.contains("string"))
    }

    func testInvalidTypeForBoolField() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"recursive\":\"not-a-bool\"}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        let typeErrors = errors.filter { $0.code == .invalidType }
        XCTAssertTrue(typeErrors.contains { $0.path == "$.recursive" })
    }

    func testInvalidTypeForNumberOrStringField() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"timeoutMs\":true}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        let typeErrors = errors.filter { $0.code == .invalidType }
        XCTAssertEqual(typeErrors.count, 1)
        XCTAssertEqual(typeErrors[0].path, "$.timeoutMs")
    }

    // MARK: - unknown_field

    func testUnknownField() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"extra\":\"value\"}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        let unknownErrors = errors.filter { $0.code == .unknownField }
        XCTAssertEqual(unknownErrors.count, 1)
        XCTAssertEqual(unknownErrors[0].path, "$.extra")
        XCTAssertTrue(unknownErrors[0].message.contains("extra"))
    }

    func testMultipleUnknownFields() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"foo\":1,\"bar\":2}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        let unknownErrors = errors.filter { $0.code == .unknownField }
        XCTAssertEqual(unknownErrors.count, 2)
    }

    // MARK: - Combined Errors

    func testMultipleErrorTypesReportedTogether() {
        let result = ToolArgsValidator.validate(
            "{\"content\":123,\"unknown\":true}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertTrue(errors.contains { $0.code == .missingRequired })
        XCTAssertTrue(errors.contains { $0.code == .invalidType })
        XCTAssertTrue(errors.contains { $0.code == .unknownField })
    }

    // MARK: - Success Path

    func testValidArgumentsSuccess() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"hello\"}",
            schema: testSchema
        )
        guard case .success(let args) = result else {
            XCTFail("Expected success")
            return
        }
        XCTAssertEqual(args.string("path"), "/tmp")
        XCTAssertEqual(args.string("content"), "hello")
        XCTAssertNil(args.string("timeoutMs"))
    }

    // MARK: - timeoutMs Compatibility (number and numeric string)

    func testTimeoutMsAsNumber() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"timeoutMs\":15000}",
            schema: testSchema
        )
        guard case .success(let args) = result else {
            XCTFail("Expected success")
            return
        }
        XCTAssertEqual(args.int("timeoutMs"), 15000)
    }

    func testTimeoutMsAsNumericString() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"timeoutMs\":\"15000\"}",
            schema: testSchema
        )
        guard case .success(let args) = result else {
            XCTFail("Expected success")
            return
        }
        XCTAssertEqual(args.int("timeoutMs"), 15000)
    }

    func testTimeoutMsAsNonNumericStringFails() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"timeoutMs\":\"abc\"}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertTrue(errors.contains { $0.code == .invalidType && $0.path == "$.timeoutMs" })
    }

    // MARK: - ValidatedArgs Typed Access

    func testValidatedArgsBoolAccess() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"recursive\":true}",
            schema: testSchema
        )
        guard case .success(let args) = result else {
            XCTFail("Expected success")
            return
        }
        XCTAssertEqual(args.bool("recursive"), true)
    }

    func testValidatedArgsBoolAccessFromString() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"recursive\":\"true\"}",
            schema: testSchema
        )
        guard case .success(let args) = result else {
            XCTFail("Expected success")
            return
        }
        XCTAssertEqual(args.bool("recursive"), true)
    }

    // MARK: - Type Safety: Bool/Int 与 NSNumber 桥接隔离

    func testBoolFieldRejectsNumber() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"recursive\":1}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertTrue(errors.contains { $0.code == .invalidType && $0.path == "$.recursive" })
    }

    func testBoolFieldRejectsZero() {
        let result = ToolArgsValidator.validate(
            "{\"path\":\"/tmp\",\"content\":\"x\",\"recursive\":0}",
            schema: testSchema
        )
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertTrue(errors.contains { $0.code == .invalidType && $0.path == "$.recursive" })
    }

    func testIntFieldRejectsTrue() {
        let intSchema = ToolArgsSchema(fields: [
            ToolArgField(name: "count", type: .int, required: true)
        ])
        let result = ToolArgsValidator.validate("{\"count\":true}", schema: intSchema)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertTrue(errors.contains { $0.code == .invalidType && $0.path == "$.count" })
    }

    func testIntFieldRejectsFalse() {
        let intSchema = ToolArgsSchema(fields: [
            ToolArgField(name: "count", type: .int, required: true)
        ])
        let result = ToolArgsValidator.validate("{\"count\":false}", schema: intSchema)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertTrue(errors.contains { $0.code == .invalidType && $0.path == "$.count" })
    }

    func testValidatedArgsBoolReturnsNilForNumber() {
        let args = ValidatedArgs(raw: ["flag": 1])
        XCTAssertNil(args.bool("flag"))
    }

    func testValidatedArgsBoolReturnsNilForZero() {
        let args = ValidatedArgs(raw: ["flag": 0])
        XCTAssertNil(args.bool("flag"))
    }

    func testValidatedArgsIntReturnsNilForBoolTrue() {
        let args = ValidatedArgs(raw: ["count": true])
        XCTAssertNil(args.int("count"))
    }

    func testValidatedArgsIntReturnsNilForBoolFalse() {
        let args = ValidatedArgs(raw: ["count": false])
        XCTAssertNil(args.int("count"))
    }

    // MARK: - ReadTool Integration

    func testReadToolRejectsInvalidJson() async {
        let tool = ReadTool()
        let result = await tool.execute(arguments: "not json", cwd: "/tmp", cancellation: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidJson"))
    }

    func testReadToolRejectsMissingPath() async {
        let tool = ReadTool()
        let result = await tool.execute(arguments: "{}", cwd: "/tmp", cancellation: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("missingRequired"))
        XCTAssertTrue(result.output.contains("$.path"))
    }

    func testReadToolRejectsUnknownField() async {
        let tool = ReadTool()
        let result = await tool.execute(arguments: "{\"path\":\"x\",\"extra\":1}", cwd: "/tmp", cancellation: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("unknownField"))
        XCTAssertTrue(result.output.contains("$.extra"))
    }

    func testReadToolRejectsInvalidPathType() async {
        let tool = ReadTool()
        let result = await tool.execute(arguments: "{\"path\":123}", cwd: "/tmp", cancellation: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidType"))
    }

    // MARK: - WriteTool Integration

    func testWriteToolRejectsMissingContent() async {
        let tool = WriteTool()
        let result = await tool.execute(arguments: "{\"path\":\"/tmp/x\"}", cwd: "/tmp", cancellation: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("missingRequired"))
        XCTAssertTrue(result.output.contains("$.content"))
    }

    func testWriteToolRejectsInvalidContentType() async {
        let tool = WriteTool()
        let result = await tool.execute(arguments: "{\"path\":\"/tmp/x\",\"content\":123}", cwd: "/tmp", cancellation: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidType"))
    }

    // MARK: - Side Effect Isolation

    func testReadToolInvalidArgsDoesNotTouchFileSystem() async throws {
        let tool = ReadTool()
        // 使用不合法 JSON，不应触发任何文件 I/O
        let result = await tool.execute(arguments: "bad json", cwd: "/nonexistent/path", cancellation: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidJson"))
    }

    func testWriteToolInvalidArgsDoesNotTouchFileSystem() async throws {
        let tool = WriteTool()
        // 缺少 content，不应创建文件
        let result = await tool.execute(arguments: "{\"path\":\"/should/not/create\"}", cwd: "/tmp", cancellation: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("missingRequired"))
    }

    // MARK: - Error Formatting

    func testErrorFormatting() {
        let errors = [
            ValidationError(code: .missingRequired, message: "Missing required argument: path", path: "$.path"),
            ValidationError(code: .unknownField, message: "Unknown field: extra", path: "$.extra")
        ]
        let result = ToolArgsValidator.formatErrors(errors)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("[missingRequired] Missing required argument: path (path: $.path)"))
        XCTAssertTrue(result.output.contains("[unknownField] Unknown field: extra (path: $.extra)"))
        XCTAssertEqual(result.errorCode, .missingRequired)
    }
}
