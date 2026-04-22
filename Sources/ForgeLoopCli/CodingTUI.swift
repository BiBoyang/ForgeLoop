import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

/// 根据模型生成显示标签（纯函数，可测试）
func labelForModel(_ model: Model) -> String {
    if model.id == "faux-coding-model" {
        return "faux-coding-model · local scaffold"
    }
    return "\(model.name) (\(model.id))"
}

@MainActor
func runCodingTUIInternal(
    model: Model,
    cwd: String
) async throws {
    let runner = TUIRunner()
    let renderer = TranscriptRenderer()
    let agent = await makeCodingAgent(CodingAgentConfig(model: model, cwd: cwd))

    _ = agent.subscribe { event, _ in
        await MainActor.run {
            if let renderEvent = toRenderEvent(event) {
                renderer.apply(renderEvent)
            }
            let currentModel = agent.state.model
            let status = agent.state.isStreaming ? "streaming" : "idle"
            let toolCount = renderer.pendingToolCount
            let toolHint = toolCount > 0 ? " | \(toolCount) tool\(toolCount == 1 ? "" : "s") pending" : ""
            let statusBar = "model: \(labelForModel(currentModel)) | \(status)\(toolHint)"

            let frame = [
                Style.header("✻ forgeloop replica"),
                Style.dimmed("  \(labelForModel(currentModel))"),
                Style.dimmed("  \(cwd)"),
                "",
            ] + renderer.lines.all + [
                "",
                Style.dimmed(statusBar),
            ]
            runner.tui.requestRender(lines: frame)
        }
    }

    await runner.run()

    let controller = PromptController(agent: agent, modelStore: ModelStore())

    while true {
        print("❯ ", terminator: "")
        guard let line = readLine() else { break }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            continue
        }
        let result = try await controller.submit(trimmed)
        switch result {
        case .submitted:
            break
        case .feedback(let text):
            print(text)
        case .exit:
            return
        }
    }
}
