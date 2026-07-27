import Foundation

/// A deliberately tiny, port-scoped instrument for validating Network
/// Extension behaviour on a real machine.
///
/// Enforcement rules cannot be trusted until it is known how the framework
/// honours `peekOutboundBytes`. If it waits for the full requested amount, a
/// peek larger than a client's first write holds that connection open, which
/// is how a single website rule previously became a total loss of network. The
/// probe answers that question against one unused port, so nothing else on the
/// machine can be touched while it is measured.
///
/// It is compiled out of Release builds and must stay that way.
enum FilterProbe {
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    /// While true the filter allows every flow except the probe port, so a
    /// first install on a working machine cannot cost connectivity no matter
    /// what the enforcement logic would have decided. Turn this off only after
    /// the peek behaviour has been measured.
    static let probeOnly = false

    /// An arbitrary unused port. Nothing on macOS listens here by default.
    static let port = 9_443

    /// Chosen to be far larger than the probe client's first write, so a
    /// framework that waits for the full amount is immediately visible.
    static let peekBytes = 1_024
}
