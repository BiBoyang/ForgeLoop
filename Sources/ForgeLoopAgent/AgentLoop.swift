import Foundation
import ForgeLoopAI

public enum AgentLoop {
    public static func run(
        prompts: [Message],
        context: AgentContext,
        config: AgentLoopConfig,
        emit: @escaping AgentEventSink,
        cancellation: CancellationHandle?,
        streamFn: @escaping StreamFn
    ) async throws {
        var currentContext = context
        currentContext.messages.append(contentsOf: prompts)

        let baseCount = currentContext.messages.count - prompts.count
        func delta() -> [Message] {
            guard baseCount < currentContext.messages.count else { return [] }
            return Array(currentContext.messages[baseCount...])
        }

        await emit(.agentStart)
        await emit(.turnStart)
        for prompt in prompts {
            await emit(.messageStart(message: prompt))
            await emit(.messageEnd(message: prompt))
        }

        let maxToolTurns = 8
        var toolTurnCount = 0

        while true {
            let resolved = await config.apiKeyResolver?(config.model.provider)
            let llmContext = Context(
                systemPrompt: currentContext.systemPrompt,
                messages: currentContext.messages
            )
            let options = StreamOptions(apiKey: resolved, cancellation: cancellation)
            let response = try await streamFn(config.model, llmContext, options)

            var emittedStart = false
            var streamCompleted = false
            var finalAssistant: AssistantMessage?

            streamLoop: for await event in response {
                switch event {
                case .start(let partial):
                    emittedStart = true
                    await emit(.messageStart(message: .assistant(partial)))
                    await emit(.messageUpdate(message: partial, assistantMessageEvent: event))
                case .textStart(_, let partial),
                     .textDelta(_, _, let partial),
                     .textEnd(_, _, let partial):
                    if !emittedStart {
                        emittedStart = true
                        await emit(.messageStart(message: .assistant(partial)))
                    }
                    await emit(.messageUpdate(message: partial, assistantMessageEvent: event))
                case .done, .error:
                    finalAssistant = await response.result()
                    streamCompleted = true
                    break streamLoop
                }
            }

            if !streamCompleted {
                finalAssistant = await response.result()
            }

            guard let final = finalAssistant else {
                await emit(.agentEnd(messages: delta()))
                return
            }

            currentContext.messages.append(.assistant(final))
            if !emittedStart {
                await emit(.messageStart(message: .assistant(final)))
            }
            await emit(.messageEnd(message: .assistant(final)))

            let toolCalls = final.content.compactMap { block -> ToolCall? in
                if case .toolCall(let tc) = block { return tc }
                return nil
            }

            if !toolCalls.isEmpty {
                if toolTurnCount >= maxToolTurns {
                    let errorMessage = AssistantMessage(
                        content: [.text(TextContent(text: "Maximum tool turn limit (\(maxToolTurns)) reached."))],
                        stopReason: .error,
                        errorMessage: "Maximum tool turn limit reached"
                    )
                    currentContext.messages.append(.assistant(errorMessage))
                    await emit(.messageStart(message: .assistant(errorMessage)))
                    await emit(.messageEnd(message: .assistant(errorMessage)))
                    await emit(.turnEnd(message: .assistant(errorMessage)))
                    await emit(.agentEnd(messages: delta()))
                    return
                }
                toolTurnCount += 1

                if config.toolExecutionMode == .parallel {
                    await executeToolsParallel(
                        toolCalls: toolCalls,
                        config: config,
                        emit: emit,
                        cancellation: cancellation,
                        context: &currentContext
                    )
                } else {
                    for toolCall in toolCalls {
                        await executeTool(
                            toolCall: toolCall,
                            config: config,
                            emit: emit,
                            cancellation: cancellation,
                            context: &currentContext
                        )
                    }
                }

                await emit(.turnEnd(message: .assistant(final)))
                await emit(.turnStart)
                continue
            }

            await emit(.turnEnd(message: .assistant(final)))
            await emit(.agentEnd(messages: delta()))
            return
        }
    }

    // MARK: - Sequential execution

    private static func executeTool(
        toolCall: ToolCall,
        config: AgentLoopConfig,
        emit: AgentEventSink,
        cancellation: CancellationHandle?,
        context: inout AgentContext
    ) async {
        await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))

        let result: ToolResult
        if let executor = config.toolExecutor {
            result = await executor.execute(
                name: toolCall.name,
                arguments: toolCall.arguments,
                cwd: config.cwd,
                cancellation: cancellation
            )
        } else {
            result = ToolResult.error(.notImplemented, message: "No tool executor configured")
        }

        let summary = makeSummary(from: result)
        await emit(.toolExecutionEnd(toolCallId: toolCall.id, toolName: toolCall.name, isError: result.isError, summary: summary))

        let toolMsg = Message.tool(ToolResultMessage(
            toolCallId: toolCall.id,
            output: result.output,
            isError: result.isError
        ))
        context.messages.append(toolMsg)
        await emit(.messageEnd(message: toolMsg))
    }

    // MARK: - Parallel execution

    private static func executeToolsParallel(
        toolCalls: [ToolCall],
        config: AgentLoopConfig,
        emit: AgentEventSink,
        cancellation: CancellationHandle?,
        context: inout AgentContext
    ) async {
        guard let executor = config.toolExecutor else {
            for toolCall in toolCalls {
                await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
                let summary = makeSummary(from: ToolResult.error(.notImplemented, message: "No tool executor configured"))
                await emit(.toolExecutionEnd(toolCallId: toolCall.id, toolName: toolCall.name, isError: true, summary: summary))
                let toolMsg = Message.tool(ToolResultMessage(toolCallId: toolCall.id, output: "No tool executor configured", isError: true))
                context.messages.append(toolMsg)
                await emit(.messageEnd(message: toolMsg))
            }
            return
        }

        // Phase 1: Fire all toolExecutionStart events (order doesn't matter for start)
        for toolCall in toolCalls {
            await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
        }

        // Phase 2: Execute in parallel, collect results in source order
        struct ToolOutput: Sendable {
            let toolCallId: String
            let toolName: String
            let result: ToolResult
        }

        var results: [ToolOutput] = []
        await withTaskGroup(of: ToolOutput.self) { group in
            for toolCall in toolCalls {
                group.addTask {
                    let result = await executor.execute(
                        name: toolCall.name,
                        arguments: toolCall.arguments,
                        cwd: config.cwd,
                        cancellation: cancellation
                    )
                    return ToolOutput(toolCallId: toolCall.id, toolName: toolCall.name, result: result)
                }
            }

            // Collect in completion order, then sort back to source order
            var unordered: [ToolOutput] = []
            for await output in group {
                unordered.append(output)
            }

            // Restore source order using toolCalls index
            let idToIndex = Dictionary(uniqueKeysWithValues: toolCalls.enumerated().map { ($1.id, $0) })
            results = unordered.sorted {
                (idToIndex[$0.toolCallId] ?? 0) < (idToIndex[$1.toolCallId] ?? 0)
            }
        }

        // Phase 3: Emit end events and inject tool_results in source order
        for output in results {
            let summary = makeSummary(from: output.result)
            await emit(.toolExecutionEnd(toolCallId: output.toolCallId, toolName: output.toolName, isError: output.result.isError, summary: summary))

            let toolMsg = Message.tool(ToolResultMessage(
                toolCallId: output.toolCallId,
                output: output.result.output,
                isError: output.result.isError
            ))
            context.messages.append(toolMsg)
            await emit(.messageEnd(message: toolMsg))
        }
    }
}

private func makeSummary(from result: ToolResult) -> String? {
    let output = result.output
    if output.isEmpty { return "(no output)" }
    let firstLine = output.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? output
    let maxLen = 80
    if firstLine.count > maxLen {
        let endIndex = firstLine.index(firstLine.startIndex, offsetBy: maxLen)
        return String(firstLine[..<endIndex]) + "..."
    }
    return firstLine
}
