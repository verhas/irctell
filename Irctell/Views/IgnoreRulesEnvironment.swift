import SwiftUI

extension EnvironmentValues {
    /// The ignores in force, for the transcripts reading the log.
    @Entry var ignoreRules: [IgnoreRule] = []
}
