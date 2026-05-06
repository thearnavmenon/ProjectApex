// MigrationDates.swift
// ProjectApex — Models
//
// Canonical home for release-coupled cutover dates. Each constant pins
// a one-time migration boundary (e.g. set-intent backfill cutoff, local-date
// field rollout) so query-time logic can branch on "before" vs "after"
// without scattering literal dates through services.
//
// Anchors below are the actual production apply timestamps captured during
// the 2026-05-06 deploy. Sub-second precision is recorded in the audit trail
// (PRs #48 / #52 commit messages, #10 close comment); second-level precision
// is sufficient for the consumer branching logic.

import Foundation

enum MigrationDates {
    /// Cutoff for the set-intent backfill (per ADR-0005 — three-phase
    /// migration with code validation shipping before DB migration).
    /// Reads of pre-cutoff sets must tolerate missing intent; reads of
    /// post-cutoff sets must require it.
    /// Apply timestamp: migration 0004, 2026-05-06 08:10:17.147758 UTC.
    static let v2SetIntentBackfill: Date = iso8601Utc("2026-05-06T08:10:17Z")

    /// Cutoff for the localDate-field rollout (per ADR-0005 — pre-bucketed
    /// localDate string at write time, immune to subsequent timezone
    /// changes). Reads of pre-cutoff sessions derive localDate from
    /// timestamp + active timezone; reads of post-cutoff sessions trust
    /// the stored field.
    /// Apply timestamp: migration 0002, 2026-05-06 07:25:14.561933 UTC.
    static let v2LocalDateField: Date = iso8601Utc("2026-05-06T07:25:14Z")

    private static func iso8601Utc(_ literal: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: literal) else {
            preconditionFailure("MigrationDates: invalid ISO8601 literal: \(literal)")
        }
        return date
    }
}
