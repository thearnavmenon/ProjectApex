import Foundation

/// Single resolver for bundled system-prompt resources (#220).
///
/// Consolidates the previously-duplicated
/// `Bundle.main.url(forResource:withExtension:"txt",subdirectory:"Prompts")
/// ?? <flat-bundle fallback>` + `String(contentsOf:)` pattern that lived
/// verbatim in five services (`AIInferenceService`, `SessionPlanService`,
/// `ProgramGenerationService`, `MacroPlanService`, `InferenceSpike`).
///
/// Only the *resolution + read* is shared here — each caller keeps its own
/// typed not-found error and any post-processing (e.g. appending the exercise
/// reference block), so caller-visible behavior is unchanged.
nonisolated enum PromptLoader {
    /// Loads a bundled prompt's UTF-8 contents. Tries the `Prompts/`
    /// subdirectory first, then the flat bundle root (resources are flattened
    /// in some build configurations). Returns `nil` when the resource cannot be
    /// located — so each caller can throw its own typed error — and throws only
    /// if the file is found but cannot be read.
    static func load(_ name: String) throws -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Prompts")
            ?? Bundle.main.url(forResource: name, withExtension: "txt")
        else {
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
