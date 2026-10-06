import DiktafClaude
import DiktafCore
import DiktafOllama
import Foundation

/// The `TextRefiner` the session holds, standing in front of Ollama and Claude.
///
/// The counterpart of `EngineSwitchingTranscriber`: the session keeps one refiner
/// for the life of the application, and the engine is read at every cleanup so a
/// change in the settings applies to the next dictation.
///
/// Ollama that is not running, or has no such model, falls through to Claude
/// within the same deadline. Anything else Ollama says is its own failure: a
/// second agent rewriting a transcript the first one choked on is not a fallback
/// anybody would want to wait for.
struct EngineSwitchingRefiner: TextRefiner {
    /// Which engine is cleaning up, and the model it was given — reported before
    /// the work starts, so the indicator can say who it is waiting for.
    struct Choice: Sendable, Equatable {
        let engine: CleanupEngine
        let model: String
        /// Set when this is Claude standing in for an Ollama that could not be
        /// reached, with Ollama's own account of why.
        let fallbackReason: String?
    }

    let ollama: any TextRefiner
    let claude: any TextRefiner
    let settings: @Sendable () async -> Settings
    let report: @Sendable (Choice) async -> Void

    func refine(text: String, instruction: String) async throws -> String {
        let settings = await settings()
        let claudeModel = settings.cleanupModel ?? "claude"

        switch settings.cleanupEngine {
        case .claude:
            await report(Choice(engine: .claude, model: claudeModel, fallbackReason: nil))
            return try await claude.refine(text: text, instruction: instruction)

        case .ollama:
            let model = OllamaModelCatalogue.model(named: settings.ollamaModel)
            await report(Choice(engine: .ollama, model: model, fallbackReason: nil))
            do {
                return try await ollama.refine(text: text, instruction: instruction)
            } catch RefinementFailure.agentUnavailable(let reason) {
                try Task.checkCancellation()
                await report(Choice(engine: .claude, model: claudeModel, fallbackReason: reason))
                return try await claude.refine(text: text, instruction: instruction)
            }
        }
    }
}
