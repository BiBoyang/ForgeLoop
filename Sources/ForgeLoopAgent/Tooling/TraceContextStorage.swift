import ForgeLoopDiagnostics

/// Task-local storage for the active trace span during tool execution.
///
/// `ToolExecutor` sets this value around each `Tool.execute` call so that
/// tools (notably `SubagentTool`) can create child spans without changing the
/// `Tool` protocol surface.
enum TraceContextStorage {
    @TaskLocal static var current: TraceContext?
}
