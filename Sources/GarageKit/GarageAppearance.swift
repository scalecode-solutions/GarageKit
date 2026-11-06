/// The trigger's wording, chosen by the host. The kit ships neutral defaults
/// (GarageLab); a host can pass its own wording.
public struct GarageAppearance: Sendable {
    /// Idle caption in hold-to-trigger mode.
    public var holdPrompt: String
    /// Idle caption in tap mode.
    public var tapPrompt: String

    public init(holdPrompt: String = "Press and hold",
                tapPrompt: String = "Tap to open or close") {
        self.holdPrompt = holdPrompt
        self.tapPrompt = tapPrompt
    }

    public static let standard = GarageAppearance()
}
