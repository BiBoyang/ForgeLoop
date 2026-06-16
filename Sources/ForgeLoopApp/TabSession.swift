import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopTUI

@MainActor
final class TabSession {
    let id: String
    let agent: Agent
    let transcript: TranscriptRenderer
    var inputState = MultiLineInputState(viewport: Viewport(width: 60))
    var inputHistory = PromptHistory()
    var currentBlockID: String?
    var bgTaskLines: [String] = []
    var footerNotice: String? = nil
    var messageSegments: [AppController.MessageSegment] = []

    init(id: String, agent: Agent, transcript: TranscriptRenderer) {
        self.id = id
        self.agent = agent
        self.transcript = transcript
    }
}
