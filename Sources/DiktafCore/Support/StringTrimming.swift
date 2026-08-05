import Foundation

extension String {
    /// Whitespace and newlines off both ends. Used often enough, and easy
    /// enough to get subtly wrong, to be worth naming once.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
