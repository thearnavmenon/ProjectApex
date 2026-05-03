// MigrationDates.swift
// ProjectApex — Models
//
// Canonical home for release-coupled cutover dates. Each constant pins
// a one-time migration boundary (e.g. set-intent backfill cutoff, local-date
// field rollout) so query-time logic can branch on "before" vs "after"
// without scattering literal dates through services.
//
// Placeholder values point to the v2 release horizon and must be updated
// to actual deploy timestamps before v2 ships.

import Foundation

enum MigrationDates {
    /// Cutoff for the set-intent backfill (per ADR-0005 — three-phase
    /// migration with code validation shipping before DB migration).
    /// Reads of pre-cutoff sets must tolerate missing intent; reads of
    /// post-cutoff sets must require it.
    static let v2SetIntentBackfill: Date = Date(timeIntervalSince1970: 0)

    /// Cutoff for the localDate-field rollout (per ADR-0005 — pre-bucketed
    /// localDate string at write time, immune to subsequent timezone
    /// changes). Reads of pre-cutoff sessions derive localDate from
    /// timestamp + active timezone; reads of post-cutoff sessions trust
    /// the stored field.
    static let v2LocalDateField: Date = Date(timeIntervalSince1970: 0)
}
