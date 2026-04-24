import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli
@testable import ForgeLoopTUI

/// AgentEvent -> CoreRenderEvent 适配行为等价测试：
/// 同一语义输入序列下，adapter 输出与手写 core 事件输出完全一致。
@MainActor
final class CoreRenderEventAdapterTests: XCTestCase {
    // MARK: - 1) Assistant streaming 生命周期等价

    func testAssistantStreamingLifecycleEquivalence() {
        let first = assistant(text: "hello")
        let second = assistant(text: "hello world")

        assertEquivalent(
            agentEvents: [
                .messageStart(message: .assistant(assistant())),
                .messageUpdate(message: first, assistantMessageEvent: .start(partial: first)),
                .messageUpdate(message: second, assistantMessageEvent: .start(partial: second)),
                .messageEnd(message: .assistant(second)),
            ],
            coreEvents: [
                .blockStart(id: "__assistant"),
                .blockUpdate(id: "__assistant", lines: ["hello"]),
                .blockUpdate(id: "__assistant", lines: ["hello world"]),
                .blockEnd(id: "__assistant", lines: ["hello world"], footer: nil),
            ]
        )
    }

    // MARK: - 2) User message 等价

    func testUserMessageEquivalence() {
        assertEquivalent(
            agentEvents: [
                .messageStart(message: .user(UserMessage(text: "do something"))),
            ],
            coreEvents: [
                .insert(lines: [Style.user("❯ do something"), ""]),
            ]
        )
    }

    // MARK: - 3) Tool execution 等价

    func testToolExecutionEquivalence() {
        assertEquivalent(
            agentEvents: [
                .toolExecutionStart(toolCallId: "tc-1", toolName: "read", args: "{}"),
                .toolExecutionEnd(toolCallId: "tc-1", toolName: "read", isError: false, summary: "content"),
            ],
            coreEvents: [
                .operationStart(id: "tc-1", header: "● read({})", status: "⎿ running..."),
                .operationEnd(id: "tc-1", isError: false, result: "content"),
            ]
        )
    }

    func testToolFailureEquivalence() {
        assertEquivalent(
            agentEvents: [
                .toolExecutionStart(toolCallId: "tc-1", toolName: "write", args: "{}"),
                .toolExecutionEnd(toolCallId: "tc-1", toolName: "write", isError: true, summary: nil),
            ],
            coreEvents: [
                .operationStart(id: "tc-1", header: "● write({})", status: "⎿ running..."),
                .operationEnd(id: "tc-1", isError: true, result: nil),
            ]
        )
    }

    // MARK: - 4) Notification folding 等价

    func testNotificationFoldingEquivalence() {
        assertEquivalent(
            agentEvents: [
                .agentStart,
                .agentStart,
                .agentStart,
                .agentStart,
            ],
            coreEvents: [
                .notification(text: "agent started"),
                .notification(text: "agent started"),
                .notification(text: "agent started"),
                .notification(text: "agent started"),
            ]
        )
    }

    // MARK: - 5) Error footer 等价

    func testErrorFooterEquivalence() {
        assertEquivalent(
            agentEvents: [
                .messageStart(message: .assistant(assistant())),
                .messageEnd(message: .assistant(assistant(errorMessage: "HTTP 404"))),
            ],
            coreEvents: [
                .blockStart(id: "__assistant"),
                .blockEnd(id: "__assistant", lines: [], footer: "HTTP 404"),
            ]
        )
    }

    // MARK: - 6) Thinking block 等价

    func testThinkingBlockEquivalence() {
        assertEquivalent(
            agentEvents: [
                .messageStart(message: .assistant(assistant())),
                .messageEnd(message: .assistant(assistant(text: "result", thinking: "I think"))),
            ],
            coreEvents: [
                .blockStart(id: "__assistant"),
                .blockEnd(id: "__assistant", lines: ["💭 I think", "result"], footer: nil),
            ]
        )
    }

    func testThinkingMultilineEquivalence() {
        let thinking = "line one\nline two"
        assertEquivalent(
            agentEvents: [
                .messageStart(message: .assistant(assistant())),
                .messageEnd(message: .assistant(assistant(text: "ok", thinking: thinking))),
            ],
            coreEvents: [
                .blockStart(id: "__assistant"),
                .blockEnd(id: "__assistant", lines: ["💭 line one …", "ok"], footer: nil),
            ]
        )
    }

    // MARK: - 7) 混合场景等价（assistant + tool + notification）

    func testMixedScenarioEquivalence() {
        let streaming = assistant(text: "Let me check")
        assertEquivalent(
            agentEvents: [
                .messageStart(message: .user(UserMessage(text: "query"))),
                .messageStart(message: .assistant(assistant())),
                .messageUpdate(message: streaming, assistantMessageEvent: .start(partial: streaming)),
                .messageEnd(message: .assistant(streaming)),
                .toolExecutionStart(toolCallId: "t1", toolName: "search", args: "q"),
                .toolExecutionEnd(toolCallId: "t1", toolName: "search", isError: false, summary: "found"),
                .agentEnd(messages: []),
            ],
            coreEvents: [
                .insert(lines: [Style.user("❯ query"), ""]),
                .blockStart(id: "__assistant"),
                .blockUpdate(id: "__assistant", lines: ["Let me check"]),
                .blockEnd(id: "__assistant", lines: ["Let me check"], footer: nil),
                .operationStart(id: "t1", header: "● search(q)", status: "⎿ running..."),
                .operationEnd(id: "t1", isError: false, result: "found"),
                .notification(text: "agent ended"),
            ]
        )
    }

    // MARK: - 8) Adapter 端到端（忽略 turnStart/turnEnd）

    func testAdapterEndToEndSkipsTurnLifecycleEvents() {
        let stream = assistant(text: "processing")
        assertEquivalent(
            agentEvents: [
                .turnStart,
                .messageStart(message: .assistant(assistant())),
                .messageUpdate(message: stream, assistantMessageEvent: .start(partial: stream)),
                .turnEnd(message: .assistant(stream)),
                .messageEnd(message: .assistant(assistant(text: "done"))),
            ],
            coreEvents: [
                .blockStart(id: "__assistant"),
                .blockUpdate(id: "__assistant", lines: ["processing"]),
                .blockEnd(id: "__assistant", lines: ["done"], footer: nil),
            ]
        )
    }

    // MARK: - 9) Stream 覆盖更新不回退

    func testStreamingReplacementEquivalence() {
        let first = assistant(text: "alpha\nbeta\ngamma")
        let second = assistant(text: "x")

        assertEquivalent(
            agentEvents: [
                .messageStart(message: .assistant(assistant())),
                .messageUpdate(message: first, assistantMessageEvent: .start(partial: first)),
                .messageUpdate(message: second, assistantMessageEvent: .start(partial: second)),
                .messageEnd(message: .assistant(second)),
            ],
            coreEvents: [
                .blockStart(id: "__assistant"),
                .blockUpdate(id: "__assistant", lines: ["alpha", "beta", "gamma"]),
                .blockUpdate(id: "__assistant", lines: ["x"]),
                .blockEnd(id: "__assistant", lines: ["x"], footer: nil),
            ]
        )
    }

    // MARK: - 10) Tool 多行 summary 截断等价

    func testToolMultiLineSummaryEquivalence() {
        let summary = "line1\nline2\nline3\nline4"
        assertEquivalent(
            agentEvents: [
                .toolExecutionStart(toolCallId: "tc", toolName: "bash", args: "{}"),
                .toolExecutionEnd(toolCallId: "tc", toolName: "bash", isError: false, summary: summary),
            ],
            coreEvents: [
                .operationStart(id: "tc", header: "● bash({})", status: "⎿ running..."),
                .operationEnd(id: "tc", isError: false, result: summary),
            ]
        )
    }

    // MARK: - 11) agentStart / agentEnd 通知映射

    func testAgentLifecycleMappedToNotifications() {
        assertEquivalent(
            agentEvents: [.agentStart, .agentEnd(messages: [])],
            coreEvents: [.notification(text: "agent started"), .notification(text: "agent ended")]
        )
    }

    // MARK: - 12) messageUpdate 提取 thinking + text

    func testMessageUpdateThinkingAndTextExtraction() {
        let msg = assistant(text: "answer", thinking: "reason")
        assertEquivalent(
            agentEvents: [
                .messageStart(message: .assistant(assistant())),
                .messageUpdate(message: msg, assistantMessageEvent: .start(partial: msg)),
                .messageEnd(message: .assistant(msg)),
            ],
            coreEvents: [
                .blockStart(id: "__assistant"),
                .blockUpdate(id: "__assistant", lines: ["💭 reason", "answer"]),
                .blockEnd(id: "__assistant", lines: ["💭 reason", "answer"], footer: nil),
            ]
        )
    }
}

// MARK: - Helpers

@MainActor
private func assertEquivalent(agentEvents: [AgentEvent], coreEvents: [CoreRenderEvent], file: StaticString = #filePath, line: UInt = #line) {
    let fromAgent = render(agentEvents: agentEvents)
    let fromCore = render(coreEvents: coreEvents)
    XCTAssertEqual(fromAgent, fromCore, file: file, line: line)
}

@MainActor
private func render(agentEvents: [AgentEvent]) -> [String] {
    let renderer = TranscriptRenderer()
    for event in agentEvents {
        if let core = toCoreRenderEvent(event) {
            renderer.applyCore(core)
        }
    }
    return renderer.lines.all
}

@MainActor
private func render(coreEvents: [CoreRenderEvent]) -> [String] {
    let renderer = TranscriptRenderer()
    for event in coreEvents {
        renderer.applyCore(event)
    }
    return renderer.lines.all
}

private func assistant(text: String = "", thinking: String? = nil, errorMessage: String? = nil) -> AssistantMessage {
    var blocks: [AssistantBlock] = []
    if let thinking {
        blocks.append(.text(TextContent(text: "<thinking>\(thinking)</thinking>")))
    }
    if !text.isEmpty || blocks.isEmpty {
        blocks.append(.text(TextContent(text: text)))
    }
    return AssistantMessage(content: blocks, stopReason: .endTurn, errorMessage: errorMessage)
}
