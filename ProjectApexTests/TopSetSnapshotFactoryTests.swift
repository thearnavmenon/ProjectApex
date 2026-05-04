// TopSetSnapshotFactoryTests.swift
// ProjectApexTests
//
// Tests for TopSetSnapshot.make(setLog:loggedInTimezone:) — Phase 1 / Slice 5.
// See ADR-0005 ("pre-bucketed localDate string at write time"), issue #4.

import Testing
import Foundation
@testable import ProjectApex

@Suite("TopSetSnapshot.make factory")
struct TopSetSnapshotFactoryTests {

    // MARK: Fixtures

    private static let sydney = TimeZone(identifier: "Australia/Sydney")!
    private static let tokyo  = TimeZone(identifier: "Asia/Tokyo")!
    private static let utc    = TimeZone(identifier: "UTC")!

    /// 2026-05-03 14:30:00 UTC.
    /// In Australia/Sydney (UTC+10, no DST in May): 2026-05-04 00:30 — date 2026-05-04.
    /// In Asia/Tokyo     (UTC+9):                    2026-05-03 23:30 — date 2026-05-03.
    /// In UTC:                                       2026-05-03 14:30 — date 2026-05-03.
    private static let acrossSydneyMidnight = Date(timeIntervalSince1970: 1_777_818_600)

    private func setLog(
        loggedAt: Date = TopSetSnapshotFactoryTests.acrossSydneyMidnight,
        weightKg: Double = 100.0,
        reps: Int = 5
    ) -> SetLog {
        SetLog(
            id: UUID(),
            sessionId: UUID(),
            exerciseId: "barbell_back_squat",
            setNumber: 1,
            weightKg: weightKg,
            repsCompleted: reps,
            rpeFelt: 8,
            rirEstimated: 2,
            aiPrescribed: nil,
            loggedAt: loggedAt,
            primaryMuscle: "quads"
        )
    }

    // MARK: - Cycle 1: factory exists, copies scalar fields

    @Test("Factory copies sessionId, weightKg, reps from the set log")
    func copiesScalarFields() {
        let log = setLog(weightKg: 102.5, reps: 7)
        let snap = TopSetSnapshot.make(setLog: log, loggedInTimezone: Self.sydney)

        #expect(snap.sessionId == log.sessionId)
        #expect(snap.weightKg  == 102.5)
        #expect(snap.reps      == 7)
    }

    // MARK: - Cycle 2: Epley e1RM (CONTEXT.md — weight × (1 + reps/30))

    @Test("Factory computes Epley e1rm = weight × (1 + reps/30)")
    func computesEpleyE1rm() {
        let log = setLog(weightKg: 100.0, reps: 5)
        let snap = TopSetSnapshot.make(setLog: log, loggedInTimezone: Self.sydney)

        // 100 × (1 + 5/30) = 100 × 1.16666… = 116.666…
        let expected = 100.0 * (1.0 + 5.0 / 30.0)
        #expect(abs(snap.e1rm - expected) < 1e-9)
    }

    // MARK: - Cycle 3: localDate formatted yyyy-MM-dd in supplied timezone

    @Test("localDate formatted as yyyy-MM-dd in the supplied timezone")
    func localDateFormattedInSuppliedTimezone() {
        // 2026-05-03 14:30 UTC → 2026-05-04 00:30 Sydney → date 2026-05-04.
        let log = setLog(loggedAt: Self.acrossSydneyMidnight)
        let snap = TopSetSnapshot.make(setLog: log, loggedInTimezone: Self.sydney)

        #expect(snap.localDate == "2026-05-04")
    }

    // MARK: - Cycle 4: Sydney→Tokyo timezone immunity (the watchpoint scenario)

    /// User logs a top set at 2026-05-04 00:30 Sydney time. The pre-bucketed
    /// `localDate` must record "2026-05-04" — the user's then-local date —
    /// and remain that string regardless of any subsequent timezone in
    /// which the snapshot is read or re-rendered. Re-formatting the same
    /// `loggedAt` instant in Tokyo (UTC+9) would yield "2026-05-03"; the
    /// snapshot's pre-bucketed string is immune to that drift.
    @Test("Sydney→Tokyo timezone immunity: pre-bucketed localDate doesn't drift")
    func sydneyToTokyoTimezoneImmunity() {
        let log = setLog(loggedAt: Self.acrossSydneyMidnight)
        let snap = TopSetSnapshot.make(setLog: log, loggedInTimezone: Self.sydney)

        // 1. Captured at the user's then-local Sydney date.
        #expect(snap.localDate == "2026-05-04")

        // 2. The same instant rendered in Tokyo would yield a different
        //    date — but the snapshot stores a string, not a Date+TZ pair,
        //    so reading later in any timezone observes the captured value.
        let tokyoFormatter = DateFormatter()
        tokyoFormatter.locale     = Locale(identifier: "en_US_POSIX")
        tokyoFormatter.dateFormat = "yyyy-MM-dd"
        tokyoFormatter.timeZone   = Self.tokyo
        let tokyoRenderedFromInstant = tokyoFormatter.string(from: log.loggedAt)
        #expect(tokyoRenderedFromInstant == "2026-05-03")

        // 3. Demonstrate the immunity: the snapshot's stored string is
        //    unchanged after Codable round-trip in any reader timezone.
        let data = try! JSONEncoder().encode(snap)
        let decoded = try! JSONDecoder().decode(TopSetSnapshot.self, from: data)
        #expect(decoded.localDate == "2026-05-04")
    }

    // MARK: - Cycle 5: edge-of-midnight crossings

    /// 23:59 Sydney on day X stays date X (does not bleed forward into
    /// X+1); 00:01 next-local-day is day X+1. UTC-rendered date diverges
    /// from local date in Sydney's window 14:00–24:00 UTC.
    @Test("Edge-of-midnight: 23:59 stays date X; 00:01 next-local-day is X+1")
    func edgeOfMidnightCrossings() {
        // 2026-05-03 23:59:00 Sydney = 2026-05-03 13:59:00 UTC.
        // (Sydney is UTC+10 in May, no DST. Sydney's 23:59 May 3 is
        // UTC's 13:59 May 3 — same calendar date in UTC.)
        let sydneyMay3_2359 = Date(timeIntervalSince1970: 1_777_816_740)

        // +120s: 23:59:00 + 2min = 00:01 May 4 Sydney = 14:01 May 3 UTC.
        let sydneyMay4_0001 = sydneyMay3_2359.addingTimeInterval(120)

        let snap2359 = TopSetSnapshot.make(
            setLog: setLog(loggedAt: sydneyMay3_2359),
            loggedInTimezone: Self.sydney
        )
        let snap0001 = TopSetSnapshot.make(
            setLog: setLog(loggedAt: sydneyMay4_0001),
            loggedInTimezone: Self.sydney
        )

        #expect(snap2359.localDate == "2026-05-03")
        #expect(snap0001.localDate == "2026-05-04")

        // Same instants rendered in UTC produce a different date —
        // confirming we are not silently using UTC.
        let utcFormatter = DateFormatter()
        utcFormatter.locale     = Locale(identifier: "en_US_POSIX")
        utcFormatter.dateFormat = "yyyy-MM-dd"
        utcFormatter.timeZone   = Self.utc
        #expect(utcFormatter.string(from: sydneyMay3_2359) == "2026-05-03")
        #expect(utcFormatter.string(from: sydneyMay4_0001) == "2026-05-03")
        // ↑ both render as 2026-05-03 in UTC because Sydney's 23:59 May 3
        //   and 00:01 May 4 are both within UTC's 13:59–14:01 May 3 window.
        //   Sydney-bucketed snapshot disagrees with UTC for the second one
        //   ("2026-05-04" Sydney vs "2026-05-03" UTC) — confirming the
        //   factory honours its loggedInTimezone parameter rather than
        //   silently bucketing in UTC.
        #expect(snap0001.localDate != utcFormatter.string(from: sydneyMay4_0001))
    }

    // MARK: - Cycle 6: explicit timezone honoured (no silent system fallback)

    /// The factory must not silently fall back to TimeZone.current — passing
    /// two different explicit timezones for the same instant must produce two
    /// different localDates whenever the instant straddles their date boundary.
    @Test("Explicit timezone is honoured; passing different timezones yields different localDates")
    func explicitTimezoneHonoured() {
        // 2026-05-03 14:30 UTC straddles Sydney's date boundary:
        //   Sydney (UTC+10) → 2026-05-04
        //   Tokyo  (UTC+9)  → 2026-05-03
        //   UTC             → 2026-05-03
        let log = setLog(loggedAt: Self.acrossSydneyMidnight)

        let sydneySnap = TopSetSnapshot.make(setLog: log, loggedInTimezone: Self.sydney)
        let tokyoSnap  = TopSetSnapshot.make(setLog: log, loggedInTimezone: Self.tokyo)
        let utcSnap    = TopSetSnapshot.make(setLog: log, loggedInTimezone: Self.utc)

        #expect(sydneySnap.localDate == "2026-05-04")
        #expect(tokyoSnap.localDate  == "2026-05-03")
        #expect(utcSnap.localDate    == "2026-05-03")

        // Sanity: the three snapshots disagree on date for the same instant
        // — proving each respected its parameter rather than collapsing
        // to a single shared system timezone.
        #expect(sydneySnap.localDate != tokyoSnap.localDate)
        #expect(sydneySnap.localDate != utcSnap.localDate)
    }

    // MARK: - Cycle 7: UTC date field captured for ordering / display

    /// Per the issue body, the factory captures both `date` (UTC timestamp,
    /// preserved for ordering and display) and `localDate` (pre-bucketed
    /// string) atomically at construction. The UTC instant is needed to
    /// order the EWMA window since localDate is day-granular only.
    @Test("Factory captures setLog.loggedAt as the snapshot's date, and Codable round-trips it")
    func capturesUTCDateAndRoundTrips() throws {
        let log = setLog(loggedAt: Self.acrossSydneyMidnight)
        let snap = TopSetSnapshot.make(setLog: log, loggedInTimezone: Self.sydney)

        #expect(snap.date == log.loggedAt)

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(TopSetSnapshot.self, from: data)
        #expect(decoded.date      == snap.date)
        #expect(decoded.localDate == snap.localDate)
        #expect(decoded == snap)
    }
}
