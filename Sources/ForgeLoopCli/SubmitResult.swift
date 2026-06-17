import ForgeLoopTUI

/// Result returned when the user submits input to a session.
///
/// This type was originally nested inside `PromptController`. It is now a top-level
/// type so that both the TUI (`PromptController`) and the AppKit frontend can share
/// the same submission abstraction without depending on `PromptController`'s
/// input-management details.
public enum SubmitResult: Equatable {
    case submitted
    case feedback(String)
    case showModelPicker(ListPickerState)
    case exit
}
