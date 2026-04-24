# ForgeLoop

[![Release](https://img.shields.io/github/v/release/BiBoyang/ForgeLoop?display_name=tag)](https://github.com/BiBoyang/ForgeLoop/releases)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/macOS-14%2B-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/BiBoyang/ForgeLoop/blob/main/LICENSE)

`ForgeLoop` is a Swift coding-agent project with a layered architecture:

- `ForgeLoopAI` for providers, streaming, and message models
- `ForgeLoopAgent` for lifecycle, loop control, tools, and cancellation
- `ForgeLoopCli` for interaction, routing, and terminal UX

## Terminal Rendering

`ForgeLoop` now wires an application-level Markdown table policy into `ForgeLoopTUI`.

- wide tables prefer `compact -> truncate -> degrade`
- the app uses ASCII `"..."` truncation in table cells
- the real call site is `TranscriptRenderer(markdownOptions:)` in `ForgeLoopCli`

If you want to tune this app-level behavior, update `forgeLoopMarkdownRenderOptions()` in `Sources/ForgeLoopCli/CodingTUI.swift`.

## Related Projects

- `ForgeLoopTUI` (standalone TUI rendering library): https://github.com/BiBoyang/ForgeLoopTUI

## Suggested GitHub Topics

- `swift`
- `cli`
- `coding-agent`
- `llm-agent`
- `terminal-ui`
