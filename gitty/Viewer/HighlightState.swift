import Observation

/// The identifier highlighted on every page (Highlight in the text menu), until it's removed.
/// One at a time: highlighting another replaces it.
@MainActor @Observable
final class HighlightState {
    var current: IdentifierHighlight?
}
