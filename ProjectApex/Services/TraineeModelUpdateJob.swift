// Services/TraineeModelUpdateJob.swift
// ProjectApex
//
// WAQ flush handler for trainee_model_update items (Phase 1 / Slice 11, issue #12).
// ADR-0005 / ADR-0006.
//
// Responsibility: route queued trainee_model_updates items to the
// update-trainee-model Edge Function instead of the default Supabase
// REST insert path; on a successful response, update the local
// SwiftData cache via TraineeModelLocalStore.
//
// Registration: call register(with:) at app startup so the WAQ knows
// to dispatch trainee_model_updates items through this handler. Must
// be called before the first WAQ flush.
//
// Failure semantics (per ADR-0006 §3):
//   • HTTP 429 / 502 / 503 / 504 / network failure → .transientFailure
//     (WAQ retries with exponential backoff, up to maxRetries).
//   • HTTP 4xx (other than 429) → .permanentFailure (logged via
//     FallbackLogRecord + os.Logger; item removed from WAQ).
//   • HTTP 200 with decodable TraineeModel → snapshot saved to local
//     store; .success returned.
//   • HTTP 200 with undecodable model (Phase 1 stub returns {}) →
//     snapshot not updated; .success returned (server acknowledged).
//   • HTTP 200 with missing trainee_model key → .permanentFailure
//     (unexpected response shape; item removed to avoid replay loop).
//
// Idempotency is enforced server-side via the
// trainee_model_applied_sessions PRIMARY KEY (user_id, session_id).
// Safe to retry — duplicates are short-circuited at the DB layer.
//
// Out of scope (Phase 2):
//   • Rule logic — runs inside the Edge Function / stored procedure.
//   • Prompt-assembly integration — consumes TraineeModelDigest.

import Foundation
import OSLog

// MARK: - TraineeModelUpdateJob

/// WAQ adapter that routes `trainee_model_updates` items to the
/// `update-trainee-model` Edge Function and updates the local snapshot
/// on a successful response.
final class TraineeModelUpdateJob {

    // MARK: - Constants

    /// WAQ table sentinel shared with TraineeModelService.waqTable.
    static let waqTable = TraineeModelService.waqTable

    /// Supabase Edge Function name (without the project prefix).
    static let functionName = "update-trainee-model"

    private static let callSite = "TraineeModelUpdateJob.flush"
    private static let logger   = Logger(subsystem: "com.projectapex",
                                          category: "TraineeModelUpdate")

    // MARK: - Dependencies

    private let supabase: SupabaseClient
    private let store: TraineeModelLocalStore

    // MARK: - Init

    init(supabase: SupabaseClient, store: TraineeModelLocalStore) {
        self.supabase = supabase
        self.store    = store
    }

    // MARK: - Registration

    /// Registers this job's flush handler with the WAQ for the
    /// `trainee_model_updates` table. Must be called at app startup,
    /// before any WAQ flushes run.
    func register(with waq: WriteAheadQueue) async {
        let handler = makeHandler()
        await waq.registerFlushHandler(forTable: Self.waqTable, handler)
    }

    // MARK: - Handler Factory

    /// Returns the `@Sendable` closure that the WAQ calls for every
    /// `trainee_model_updates` item during flush.
    func makeHandler() -> @Sendable (QueuedWrite) async -> WAQFlushOutcome {
        let supabase = self.supabase
        let store    = self.store
        return { item in
            await TraineeModelUpdateJob.flush(item, supabase: supabase, store: store)
        }
    }

    // MARK: - Flush Logic

    private static func flush(
        _ item: QueuedWrite,
        supabase: SupabaseClient,
        store: TraineeModelLocalStore
    ) async -> WAQFlushOutcome {
        // POST item.payload (already-encoded TraineeModelUpdatePayload JSON) to Edge Function.
        let responseData: Data
        do {
            responseData = try await supabase.invokeFunction(functionName, body: item.payload)
        } catch let err as SupabaseError {
            return httpOutcome(for: err, item: item)
        } catch {
            logger.warning("[\(callSite)] network error for item \(item.id): \(error.localizedDescription, privacy: .public)")
            return .transientFailure
        }

        return await parseResponse(responseData, item: item, store: store)
    }

    // MARK: - Response Parsing

    private static func parseResponse(
        _ data: Data,
        item: QueuedWrite,
        store: TraineeModelLocalStore
    ) async -> WAQFlushOutcome {
        // Response must be a JSON object containing a "trainee_model" key.
        guard
            let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modelRaw = json["trainee_model"]
        else {
            let msg = "response missing 'trainee_model' key"
            logger.error("[\(callSite)] \(msg, privacy: .public) for item \(item.id, privacy: .public)")
            FallbackLogRecord(callSite: callSite, reason: msg).emit()
            return .permanentFailure(msg)
        }

        // Try to decode the model value. Phase 1 stub returns {} — that won't
        // decode as a TraineeModel (required fields missing), which is expected.
        // Either way the server returned 200, so treat as success.
        if let modelData = try? JSONSerialization.data(withJSONObject: modelRaw) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let model = try? decoder.decode(TraineeModel.self, from: modelData) {
                do {
                    try await store.save(model)
                } catch {
                    logger.warning("[\(callSite)] store save failed for item \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    // Save failure does not prevent removing the item — the server
                    // acknowledged the event. The next session completion will
                    // produce a fresh WAQ item that can retry the save.
                }
            }
        }

        return .success
    }

    // MARK: - HTTP Status → Outcome Mapping

    private static func httpOutcome(for error: SupabaseError, item: QueuedWrite) -> WAQFlushOutcome {
        switch error {
        case .httpError(let code, let body):
            // Transient: rate-limited or gateway-unavailable — retry with backoff.
            if code == 429 || (502...504).contains(code) {
                logger.warning("[\(callSite)] transient HTTP \(code) for item \(item.id, privacy: .public)")
                return .transientFailure
            }
            // Permanent: any other 4xx — bad request shape, auth failure, etc.
            if (400..<500).contains(code) {
                let msg = "permanent HTTP \(code): \(body)"
                logger.error("[\(callSite)] \(msg, privacy: .public) for item \(item.id, privacy: .public)")
                FallbackLogRecord(callSite: callSite, httpStatus: code, reason: body).emit()
                return .permanentFailure(msg)
            }
            // 5xx other than 502–504 (e.g. 500, 501) — treat as transient.
            logger.warning("[\(callSite)] transient HTTP \(code) for item \(item.id, privacy: .public)")
            return .transientFailure

        case .invalidURL:
            let msg = "invalid Edge Function URL"
            logger.error("[\(callSite)] \(msg, privacy: .public)")
            return .permanentFailure(msg)

        case .decodingError(let detail):
            // invokeFunction returns raw Data — decoding errors shouldn't happen,
            // but guard defensively.
            let msg = "response decoding error: \(detail)"
            logger.error("[\(callSite)] \(msg, privacy: .public) for item \(item.id, privacy: .public)")
            return .permanentFailure(msg)
        }
    }
}
