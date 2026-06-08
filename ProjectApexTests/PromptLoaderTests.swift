import XCTest
@testable import ProjectApex

/// #220 — the shared `PromptLoader` that the five system-prompt services now
/// resolve through. The contract the callers depend on: an existing bundled
/// prompt loads with contents; a missing resource returns `nil` (not a throw)
/// so each caller can map it to its own typed not-found error.
final class PromptLoaderTests: XCTestCase {

    func test_load_existingBundledPrompt_returnsNonEmptyContents() throws {
        // SystemPrompt_Inference ships in the app bundle (Copy Bundle Resources);
        // the existing inference-prompt anchor tests rely on the same resolution.
        let contents = try PromptLoader.load("SystemPrompt_Inference")
        XCTAssertNotNil(contents, "An existing bundled prompt must resolve to its contents")
        XCTAssertFalse(contents?.isEmpty ?? true, "Loaded prompt must be non-empty")
    }

    func test_load_missingResource_returnsNil_doesNotThrow() throws {
        // The load-bearing contract: a missing resource is a nil return, NOT a
        // throw — each caller turns the nil into its own typed error.
        let contents = try PromptLoader.load("NoSuchPrompt_zzz_doesNotExist")
        XCTAssertNil(contents, "A missing resource must return nil rather than throwing")
    }
}
