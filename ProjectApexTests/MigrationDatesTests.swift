// MigrationDatesTests.swift
// ProjectApexTests
//
// Pins MigrationDates as a namespaced enum with the two release-coupled
// cutover constants per ADR-0005.

import Testing
import Foundation
@testable import ProjectApex

@Suite("MigrationDates")
struct MigrationDatesTests {
    @Test("v2SetIntentBackfill exists as a Date constant")
    func setIntentBackfillExists() {
        let _: Date = MigrationDates.v2SetIntentBackfill
    }

    @Test("v2LocalDateField exists as a Date constant")
    func localDateFieldExists() {
        let _: Date = MigrationDates.v2LocalDateField
    }
}
