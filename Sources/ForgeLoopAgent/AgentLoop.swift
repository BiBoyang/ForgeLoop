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
                    await applyBetweenTurns(
                        messages: currentContext.messages,
                        config: config,
                        cancellation: cancellation,
                        context: &currentContext,
                        emit: emit
                    )
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
                await applyBetweenTurns(
                    messages: currentContext.messages,
                    config: config,
                    cancellation: cancellation,
                    context: &currentContext,
                    emit: emit
                )
                await emit(.turnStart)
                continue
            }

            await emit(.turnEnd(message: .assistant(final)))
            await applyBetweenTurns(
                messages: currentContext.messages,
                config: config,
                cancellation: cancellation,
                context: &currentContext,
                emit: emit
            )
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
        let before = await applyBeforeToolCall(
            toolName: toolCall.name,
            arguments: toolCall.arguments,
            hook: config.beforeToolCall,
            cancellation: cancellation
        )

        await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: before.arguments))

        let rawResult: ToolResult
        if before.blocked {
            rawResult = ToolResult.error(
                .cancelled,
                message: before.blockReason ?? "Blocked by beforeToolCall hook"
            )
        } else if let executor = config.toolExecutor {
            rawResult = await executor.execute(
                name: toolCall.name,
                arguments: before.arguments,
                cwd: config.cwd,
                cancellation: cancellation
            )
        } else {
            rawResult = ToolResult.error(.notImplemented, message: "No tool executor configured")
        }

        let result = await applyAfterToolCall(
            toolName: toolCall.name,
            arguments: before.arguments,
            result: rawResult,
            hook: config.afterToolCall,
            cancellation: cancellation
        )

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

        // Phase 1: Apply beforeToolCall hooks and emit start events in source order.
        struct ToolPlan: Sendable {
            let toolCall: ToolCall
            let arguments: String
            let blocked: Bool
            let blockReason: String?
        }

        var plans: [ToolPlan] = []
        for toolCall in toolCalls {
            let before = await applyBeforeToolCall(
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                hook: config.beforeToolCall,
                cancellation: cancellation
            )
            let plan = ToolPlan(
                toolCall: toolCall,
                arguments: before.arguments,
                blocked: before.blocked,
                blockReason: before.blockReason
            )
            plans.append(plan)
            await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: before.arguments))
        }

        // Phase 2: Execute non-blocked tools in parallel.
        struct ToolOutput: Sendable {
            let toolCallId: String
            let toolName: String
            let arguments: String
            let result: ToolResult
        }

        var results: [ToolOutput] = []
        await withTaskGroup(of: ToolOutput.self) { group in
            for plan in plans where !plan.blocked {
                group.addTask {
                    let result = await executor.execute(
                        name: plan.toolCall.name,
                        arguments: plan.arguments,
                        cwd: config.cwd,
                        cancellation: cancellation
                    )
                    return ToolOutput(
                        toolCallId: plan.toolCall.id,
                        toolName: plan.toolCall.name,
                        arguments: plan.arguments,
                        result: result
                    )
                }
            }

            // Blocked tools produce an immediate error result.
            for plan in plans where plan.blocked {
                results.append(ToolOutput(
                    toolCallId: plan.toolCall.id,
                    toolName: plan.toolCall.name,
                    arguments: plan.arguments,
                    result: ToolResult.error(.cancelled, message: plan.blockReason ?? "Blocked by beforeToolCall hook")
                ))
            }

            // Collect completion order, then sort back to source order.
            var unordered: [ToolOutput] = []
            for await output in group {
                unordered.append(output)
            }

            let idToIndex = Dictionary(uniqueKeysWithValues: toolCalls.enumerated().map { ($1.id, $0) })
            let ordered = unordered.sorted {
                (idToIndex[$0.toolCallId] ?? 0) < (idToIndex[$1.toolCallId] ?? 0)
            }
            results.append(contentsOf: ordered)
        }

        // Phase 3: Apply afterToolCall hooks, then emit end events and inject tool_results in source order.
        let idToIndex = Dictionary(uniqueKeysWithValues: toolCalls.enumerated().map { ($1.id, $0) })
        let orderedResults = results.sorted {
            (idToIndex[$0.toolCallId] ?? 0) < (idToIndex[$1.toolCallId] ?? 0)
        }

        for output in orderedResults {
            let result = await applyAfterToolCall(
                toolName: output.toolName,
                arguments: output.arguments,
                result: output.result,
                hook: config.afterToolCall,
                cancellation: cancellation
            )
            let summary = makeSummary(from: result)
            await emit(.toolExecutionEnd(toolCallId: output.toolCallId, toolName: output.toolName, isError: result.isError, summary: summary))

            let toolMsg = Message.tool(ToolResultMessage(
                toolCallId: output.toolCallId,
                output: result.output,
                isError: result.isError
            ))
            context.messages.append(toolMsg)
            await emit(.messageEnd(message: toolMsg))
        }
    }

    // MARK: - Hook helpers

    private struct BeforeToolCallApplied: Sendable {
        let arguments: String
        let blocked: Bool
        let blockReason: String?
    }

    private static func applyBeforeToolCall(
        toolName: String,
        arguments: String,
        hook: BeforeToolCallHook?,
        cancellation: CancellationHandle?
    ) async -> BeforeToolCallApplied {
        guard let hook = hook else {
            return BeforeToolCallApplied(arguments: arguments, blocked: false, blockReason: nil)
        }
        guard let result = await hook(toolName, arguments, cancellation) else {
            return BeforeToolCallApplied(arguments: arguments, blocked: false, blockReason: nil)
        }
        if result.block {
            return BeforeToolCallApplied(
                arguments: result.modifiedArguments ?? arguments,
                blocked: true,
                blockReason: result.reason
            )
        }
        return BeforeToolCallApplied(
            arguments: result.modifiedArguments ?? arguments,
            blocked: false,
            blockReason: nil
        )
    }

    private static func applyAfterToolCall(
        toolName: String,
        arguments: String,
        result: ToolResult,
        hook: AfterToolCallHook?,
        cancellation: CancellationHandle?
    ) async -> ToolResult {
        guard let hook = hook else { return result }
        guard let hookResult = await hook(toolName, arguments, result, cancellation) else { return result }

        let base: ToolResult
        if let modified = hookResult.modifiedResult {
            base = modified
        } else {
            base = result
        }

        if let isError = hookResult.isError, isError != base.isError {
            return ToolResult(output: base.output, isError: isError, errorCode: base.errorCode)
        }
        return base
    }

    private static func applyBetweenTurns(
        messages: [Message],
        config: AgentLoopConfig,
        cancellation: CancellationHandle?,
        context: inout AgentContext,
        emit: AgentEventSink
    ) async {
        guard let hook = config.betweenTurns else { return }
        guard let result = await hook(messages, cancellation) else { return }
        guard let compacted = result.compactedMessages else { return }
        let before = context.messages.count
        context.messages = compacted
        let after = compacted.count
        await emit(.contextCompacted(before: before, after: after, messages: compacted))
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
