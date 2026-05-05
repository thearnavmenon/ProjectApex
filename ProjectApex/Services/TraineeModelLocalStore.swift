// Services/TraineeModelLocalStore.swift
// ProjectApex
//
// SwiftData local cache for the TraineeModel snapshot (Phase 1 / Slice 8,
// issue #8, ADR-0005 / ADR-0006).
//
// Architecture:
//   • LocalTraineeModelRecord — single @Model row. Document-style: the full
//     TraineeModel is JSON-encoded into modelJSON: Data, mirroring the
//     Supabase trainee_models.model_json JSONB column. Not flattened into
//     sub-entities — keeping it as one row avoids SwiftData relationship
//     complexity and matches the authoritative server shape exactly.
//   • TraineeModelLocalStore — thin wrapper. Public API: load / save / clear.
//     The server (Edge Function response) is authoritative; this store is a
//     read cache that hydrates on success and bootstraps to empty on first
//     launch (nil return from load() is the first-launch signal to the
//     consumer — TraineeModelService, Slice #11).
//
// Single-user v2: one record, singleton-keyed. Multi-user / multi-device
// concurrency is explicitly out of scope per ADR-0006.

import Foundation
import SwiftData

// MARK: - LocalTraineeModelRecord

/// Single-row SwiftData @Model. The full TraineeModel value is stored as
/// a JSON blob to mirror the server's JSONB representation and avoid
/// entity relationship complexity.
@Model
final class LocalTraineeModelRecord {
    /// Singleton key — always "singleton" for v2 single-user.
    @Attribute(.unique) var id: String
    var modelJSON: Data
    var cachedAt: Date

    init(id: String = "singleton", modelJSON: Data, cachedAt: Date = Date()) {
        self.id = id
        self.modelJSON = modelJSON
        self.cachedAt = cachedAt
    }
}

// MARK: - TraineeModelLocalStore

/// Wraps a SwiftData ModelContainer providing load / save / clear access
/// to the locally cached TraineeModel snapshot.
///
/// @MainActor isolation is required: ModelContainer has internal main-actor
/// executor requirements (task-local storage for @ModelActor infrastructure).
/// Deallocation off the main actor crashes. All callers must dispatch to the
/// main actor — TraineeModelService (Slice #11) does this via await.
@MainActor
final class TraineeModelLocalStore {

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: Factories

    /// Production store — persisted to the app's default SwiftData location.
    static func makeShared() throws -> TraineeModelLocalStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        let container = try ModelContainer(for: LocalTraineeModelRecord.self,
                                           configurations: config)
        return TraineeModelLocalStore(container: container)
    }

    /// In-memory store — for unit / integration tests.
    static func makeInMemory() throws -> TraineeModelLocalStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LocalTraineeModelRecord.self,
                                           configurations: config)
        return TraineeModelLocalStore(container: container)
    }

    /// On-disk store at an explicit URL — for persistence-across-restart tests
    /// and targeted migration scenarios.
    static func makeOnDisk(at url: URL) throws -> TraineeModelLocalStore {
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(for: LocalTraineeModelRecord.self,
                                           configurations: config)
        return TraineeModelLocalStore(container: container)
    }

    // MARK: Public API

    /// Returns the cached TraineeModel, or nil if the store is empty (first
    /// launch) or if the stored JSON cannot be decoded (treated as no model).
    func load() -> TraineeModel? {
        guard let record = fetchRecord() else { return nil }
        return try? JSONDecoder().decode(TraineeModel.self, from: record.modelJSON)
    }

    /// Persists the model as a JSON blob. Upserts: if a record already
    /// exists it is updated in-place; otherwise a new record is inserted.
    func save(_ model: TraineeModel) throws {
        let data = try JSONEncoder().encode(model)
        if let record = fetchRecord() {
            record.modelJSON = data
            record.cachedAt = Date()
        } else {
            container.mainContext.insert(LocalTraineeModelRecord(modelJSON: data))
        }
        try container.mainContext.save()
    }

    /// Removes the cached record. load() will return nil after this call.
    func clear() throws {
        if let record = fetchRecord() {
            container.mainContext.delete(record)
            try container.mainContext.save()
        }
    }

    // MARK: Private

    private func fetchRecord() -> LocalTraineeModelRecord? {
        var descriptor = FetchDescriptor<LocalTraineeModelRecord>()
        descriptor.fetchLimit = 1
        return try? container.mainContext.fetch(descriptor).first
    }
}
