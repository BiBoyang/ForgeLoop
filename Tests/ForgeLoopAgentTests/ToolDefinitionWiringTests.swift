import Foundation
import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopTestSupport

/// TASK-tool-schema-wiring：Tool.definition 的 schema 与 ToolArgsValidator 语义一致性、
/// ToolExecutor.toolDefinitions 快照、AgentLoop 经 StreamOptions.tools 透传。
final class ToolDefinitionWiringTests: XCTestCase {

    // MARK: - Schema ↔ Validator 一致性（DoD 4）

    private func toolSchemaPairs() -> [(tool: any Tool, schema: ToolArgsSchema)] {
        [
            (ReadTool(), readToolSchema),
            (WriteTool(), writeToolSchema),
            (BashTool(), bashToolSchema),
            (EditTool(), editToolSchema),
            (FindTool(), findToolSchema),
            (GrepTool(), grepToolSchema),
            (ListTool(), listToolSchema),
            (BgTool(manager: BackgroundTaskManager()), bgToolSchema),
            (BgStatusTool(manager: BackgroundTaskManager()), bgStatusToolSchema)
        ]
    }

    private func parseParameters(_ definition: ToolDefinition, file: StaticString = #filePath, line: UInt = #line) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: definition.parametersJSON) as? [String: Any] else {
            XCTFail("parametersJSON is not a JSON object", file: file, line: line)
            return nil
        }
        return object
    }

    func testBuiltinToolDefinitionsMatchArgsSchemas() throws {
        for (tool, schema) in toolSchemaPairs() {
            let definition = tool.definition
            XCTAssertEqual(definition.name, tool.name)
            XCTAssertFalse(definition.description.isEmpty, "\(tool.name) description must not be empty")

            guard let object = parseParameters(definition) else { continue }
            XCTAssertEqual(object["type"] as? String, "object", "\(tool.name)")
            XCTAssertEqual(object["additionalProperties"] as? Bool, false, "\(tool.name): validator rejects unknown fields, schema must too")

            let required = Set((object["required"] as? [String]) ?? [])
            XCTAssertEqual(required, Set(schema.requiredFieldNames), "\(tool.name) required mismatch")

            guard let properties = object["properties"] as? [String: Any] else {
                XCTFail("\(tool.name): missing properties")
                continue
            }
            XCTAssertEqual(Set(properties.keys), schema.knownFieldNames, "\(tool.name) properties mismatch")

            for field in schema.fields {
                guard let property = properties[field.name] as? [String: Any] else {
                    XCTFail("\(tool.name).\(field.name): missing property schema")
                    continue
                }
                assertJSONType(property, matches: field.type, context: "\(tool.name).\(field.name)")
            }
        }
    }

    private func assertJSONType(_ property: [String: Any], matches type: ToolArgType, context: String) {
        switch type {
        case .string:
            XCTAssertEqual(property["type"] as? String, "string", context)
        case .int:
            XCTAssertEqual(property["type"] as? String, "integer", context)
        case .bool:
            XCTAssertEqual(property["type"] as? String, "boolean", context)
        case .numberOrString:
            guard let anyOf = property["anyOf"] as? [[String: Any]] else {
                XCTFail("\(context): numberOrString must map to anyOf")
                return
            }
            XCTAssertTrue(anyOf.contains { $0["type"] as? String == "number" }, context)
            XCTAssertTrue(anyOf.contains { $0["type"] as? String == "string" }, context)
        case .stringArray:
            XCTAssertEqual(property["type"] as? String, "array", context)
            let items = property["items"] as? [String: Any]
            XCTAssertEqual(items?["type"] as? String, "string", context)
        }
    }

    /// 用 schema 的 required 字段造出类型正确的最小参数：必须通过校验；
    /// 附加未知字段必须被拒（与 additionalProperties=false 对齐）。
    func testSchemaAndValidatorAgreeOnAcceptance() throws {
        for (tool, schema) in toolSchemaPairs() {
            var args: [String: Any] = [:]
            for field in schema.fields where field.required {
                switch field.type {
                case .string: args[field.name] = "x"
                case .int: args[field.name] = 1
                case .bool: args[field.name] = true
                case .numberOrString: args[field.name] = 1000
                case .stringArray: args[field.name] = ["a"]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: args)
            let json = String(decoding: data, as: UTF8.self)

            if case .failure(let errors) = ToolArgsValidator.validate(json, schema: schema) {
                XCTFail("\(tool.name): schema-minimal args rejected by validator: \(errors)")
            }

            var withBogus = args
            withBogus["bogusField"] = 1
            let bogusData = try JSONSerialization.data(withJSONObject: withBogus)
            let bogusJSON = String(decoding: bogusData, as: UTF8.self)
            if case .success = ToolArgsValidator.validate(bogusJSON, schema: schema) {
                XCTFail("\(tool.name): unknown field accepted by validator but schema says additionalProperties=false")
            }
        }
    }

    // MARK: - SubagentTool.definition

    func testSubagentToolDefinitionListsAvailableTypes() throws {
        let subagents = [
            SubagentDefinition(name: "explore", description: "read-only explorer", prompt: "...", tools: .readOnly),
            SubagentDefinition(name: "general", description: "general purpose", prompt: "...", tools: .all)
        ]
        let tool = SubagentTool(
            subagents: subagents,
            parentConfig: CodingAgentConfig(model: Model(id: "m", name: "m", api: "faux", provider: "faux"), cwd: "/tmp")
        )

        let definition = tool.definition
        XCTAssertEqual(definition.name, "agent")
        XCTAssertTrue(definition.description.contains("explore"), "description should list available subagent types")
        XCTAssertTrue(definition.description.contains("general"))

        guard let object = parseParameters(definition),
              let properties = object["properties"] as? [String: Any],
              let subagentType = properties["subagent_type"] as? [String: Any] else {
            XCTFail("agent definition missing subagent_type schema")
            return
        }
        let enumValues = Set((subagentType["enum"] as? [String]) ?? [])
        XCTAssertEqual(enumValues, Set(["explore", "general"]))

        let required = Set((object["required"] as? [String]) ?? [])
        XCTAssertEqual(required, Set(["description", "prompt"]))
    }

    // MARK: - ToolExecutor.toolDefinitions 快照（DoD 2）

    func testToolExecutorDefinitionsSnapshotSortedByName() {
        let executor = ToolExecutor()
        executor.register(WriteTool())
        executor.register(ReadTool())
        executor.register(ListTool())

        let definitions = executor.toolDefinitions
        XCTAssertEqual(definitions.map(\.name), ["ls", "read", "write"])
        XCTAssertEqual(definitions.map(\.description), [ListTool().definition.description, ReadTool().definition.description, WriteTool().definition.description])
    }

    // MARK: - AgentLoop 透传（DoD 2）

    private actor OptionsCapture {
        private(set) var captured: [StreamOptions?] = []
        func append(_ options: StreamOptions?) {
            captured.append(options)
        }
    }

    func testAgentLoopPassesToolDefinitionsInStreamOptions() async throws {
        let executor = ToolExecutor()
        executor.register(ReadTool())
        executor.register(GrepTool())

        let capture = OptionsCapture()
        let endTurnMessage = AssistantMessage.text("done", stopReason: .endTurn)
        let streamFn: StreamFn = { _, _, options in
            await capture.append(options)
            let stream = AssistantMessageStream()
            Task.detached {
                stream.push(.start(partial: endTurnMessage))
                stream.push(.done(reason: .endTurn, message: endTurnMessage))
                stream.end(endTurnMessage)
            }
            return stream
        }

        let collector = EventCollector()
        let emit: AgentEventSink = { event in
            await collector.append(event)
        }

        try await AgentLoop.run(
            prompts: [.user(UserMessage(text: "hi"))],
            context: AgentContext(systemPrompt: "", messages: []),
            config: AgentLoopConfig(
                model: Model(id: "faux", name: "faux", api: "faux", provider: "faux"),
                toolExecutor: executor,
                cwd: "/tmp"
            ),
            emit: emit,
            cancellation: nil,
            streamFn: streamFn
        )

        let captured = await capture.captured
        XCTAssertEqual(captured.count, 1)
        let tools = captured.first??.tools
        XCTAssertEqual(tools?.map(\.name), ["grep", "read"])
        XCTAssertEqual(tools?.first?.description, GrepTool().definition.description)
    }

    /// 无 toolExecutor 时 tools 必须为 nil（不发送空数组，保持既有行为）。
    func testAgentLoopWithoutExecutorOmitsTools() async throws {
        let capture = OptionsCapture()
        let endTurnMessage = AssistantMessage.text("done", stopReason: .endTurn)
        let streamFn: StreamFn = { _, _, options in
            await capture.append(options)
            let stream = AssistantMessageStream()
            Task.detached {
                stream.push(.start(partial: endTurnMessage))
                stream.push(.done(reason: .endTurn, message: endTurnMessage))
                stream.end(endTurnMessage)
            }
            return stream
        }

        let collector = EventCollector()
        let emit: AgentEventSink = { event in
            await collector.append(event)
        }

        try await AgentLoop.run(
            prompts: [.user(UserMessage(text: "hi"))],
            context: AgentContext(systemPrompt: "", messages: []),
            config: AgentLoopConfig(
                model: Model(id: "faux", name: "faux", api: "faux", provider: "faux"),
                cwd: "/tmp"
            ),
            emit: emit,
            cancellation: nil,
            streamFn: streamFn
        )

        let captured = await capture.captured
        XCTAssertEqual(captured.count, 1)
        XCTAssertNil(captured.first??.tools)
    }
}
