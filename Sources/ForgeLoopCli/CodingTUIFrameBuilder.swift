import Foundation
import ForgeLoopTUI

/// App-side helper that assembles ``ScreenLayout`` / ``ScreenLayoutConfig``
/// and runs ``ScreenLayoutRenderer`` to produce a ``ComposedFrame``.
///
/// This keeps app-specific state mapping in the CLI layer while removing
/// duplicated "layout → render" boilerplate from ``CodingTUI``.
enum CodingTUIFrameBuilder {

    struct Input {
        let headerLines: [String]
        let transcriptLines: [String]
        let queueLines: [String]
        let statusLines: [String]
        let inputLines: [String]
        let pinnedTranscriptRange: Range<Int>?
        let terminalHeight: Int
        let terminalWidth: Int
        let showHeader: Bool
        let cursorOffset: Int?

        init(
            headerLines: [String] = [],
            transcriptLines: [String] = [],
            queueLines: [String] = [],
            statusLines: [String] = [],
            inputLines: [String] = [],
            pinnedTranscriptRange: Range<Int>? = nil,
            terminalHeight: Int = 24,
            terminalWidth: Int = 80,
            showHeader: Bool = true,
            cursorOffset: Int? = nil
        ) {
            self.headerLines = headerLines
            self.transcriptLines = transcriptLines
            self.queueLines = queueLines
            self.statusLines = statusLines
            self.inputLines = inputLines
            self.pinnedTranscriptRange = pinnedTranscriptRange
            self.terminalHeight = terminalHeight
            self.terminalWidth = terminalWidth
            self.showHeader = showHeader
            self.cursorOffset = cursorOffset
        }
    }

    static func build(
        input: Input,
        renderer: ScreenLayoutRenderer = ScreenLayoutRenderer()
    ) -> ComposedFrame {
        let layout = ScreenLayout(
            header: input.headerLines,
            transcript: input.transcriptLines,
            queue: input.queueLines,
            status: input.statusLines,
            input: input.inputLines,
            pinnedTranscriptRange: input.pinnedTranscriptRange
        )
        let config = ScreenLayoutConfig(
            terminalHeight: input.terminalHeight,
            terminalWidth: input.terminalWidth,
            showHeader: input.showHeader
        )
        return renderer.render(
            layout: layout,
            config: config,
            cursorOffset: input.cursorOffset
        )
    }
}
