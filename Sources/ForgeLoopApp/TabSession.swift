import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopTUI

@MainActor
final class TabSession {
    let id: String
    let transcript: TranscriptRenderer
    var inputState = MultiLineInputState(viewport: Viewport(width: 60))
    var inputHistory = PromptHistory()
    var currentBlockID: String?
    var bgTaskLines: [String] = []
    var footerNotice: String? = nil
    var messageSegments: [AppController.MessageSegment] = []
    let coordinator: SessionCoordinator

    var agent: Agent { coordinator.agent }
    var attachmentStore: AttachmentStore { coordinator.attachmentStore }

    init(id: String, agent: Agent, transcript: TranscriptRenderer, coordinator: SessionCoordinator? = nil) {
        self.id = id
        self.transcript = transcript
        self.coordinator = coordinator ?? SessionCoordinator(agent: agent)
    }
}
