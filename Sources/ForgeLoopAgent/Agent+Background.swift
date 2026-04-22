import Foundation
import ForgeLoopAI

extension Agent {
    /// 配置后台任务完成通知桥接。
    /// 当后台任务完成时，自动注入 synthetic user message 并尝试驱动 continue()。
    public func setupBackgroundNotifications(manager: BackgroundTaskManager) {
        Task {
            await manager.setCompletionHandler { [weak self] record in
                guard let self = self else { return }
                let summary = record.output.isEmpty ? "(no output)" : String(record.output.prefix(200))
                let text = """
                    Background task \(record.id) completed with status: \(record.status.rawValue)
                    Command: \(record.command)
                    Output: \(summary)
                    """.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = Message.user(UserMessage(text: text))
                self.steer(message)

                // 如果 agent idle，直接触发 continue
                // 如果 busy，等 idle 后再触发
                if !self.state.isStreaming {
                    try? await self.continue()
                } else {
                    Task {
                        await self.waitForIdle()
                        try? await self.continue()
                    }
                }
            }
        }
    }
}
