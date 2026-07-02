// TraineeModelEnumsTests.swift
// ProjectApexTests
//
// Verifies the supporting enums (SetIntent, AxisConfidence, StimulusDimension,
// Severity, BodyJoint, ProjectionProgress) and the LimitationSubject sum
// type. Per-enum case-coverage + Codable round-trip.

import Testing
import Foundation
@testable import ProjectApex

@Suite("SetIntent")
struct SetIntentTests {
    @Test("Cases match ADR-0005 verbatim")
    func adrCases() {
        #expect(Set(SetIntent.allCases.map(\.rawValue)) ==
                ["warmup", "top", "backoff", "technique", "amrap"])
    }

    @Test("Codable round-trip")
    func codable() throws {
        for value in SetIntent.allCases {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(SetIntent.self, from: data) == value)
        }
    }
}

@Suite("AxisConfidence")
struct AxisConfidenceTests {
    @Test("Cases match ADR-0005 verbatim")
    func adrCases() {
        #expect(Set(AxisConfidence.allCases.map(\.rawValue)) ==
                ["bootstrapping", "calibrating", "established", "seasoned"])
    }

    @Test("Codable round-trip")
    func codable() throws {
        for value in AxisConfidence.allCases {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(AxisConfidence.self, from: data) == value)
        }
    }
}

@Suite("StimulusDimension")
struct StimulusDimensionTests {
    @Test("Cases match ADR-0005 / CONTEXT.md")
    func cases() {
        #expect(Set(StimulusDimension.allCases.map(\.rawValue)) ==
                ["neuromuscular", "metabolic", "both"])
    }
}

@Suite("Severity")
struct SeverityTests {
    @Test("Standard severity ordering")
    func cases() {
        #expect(Set(Severity.allCases.map(\.rawValue)) ==
                ["mild", "moderate", "severe"])
    }
}

@Suite("BodyJoint")
struct BodyJointTests {
    @Test("Includes lowerBack with snake_case raw value")
    func lowerBackEncoding() throws {
        let data = try JSONEncoder().encode(BodyJoint.lowerBack)
        #expect(String(data: data, encoding: .utf8) == "\"lower_back\"")
    }

    @Test("All cases round-trip")
    func roundTrip() throws {
        for joint in BodyJoint.allCases {
            let data = try JSONEncoder().encode(joint)
            #expect(try JSONDecoder().decode(BodyJoint.self, from: data) == joint)
        }
    }
}

@Suite("ProjectionProgress")
struct ProjectionProgressTests {
    @Test("onTrack uses snake_case raw value")
    func onTrackEncoding() throws {
        let data = try JSONEncoder().encode(ProjectionProgress.onTrack)
        #expect(String(data: data, encoding: .utf8) == "\"on_track\"")
    }
}

@Suite("InterSessionGapBucket")
struct InterSessionGapBucketTests {
    @Test("Cases match ADR-0014 enumeration")
    func cases() {
        #expect(Set(InterSessionGapBucket.allCases.map(\.rawValue)) ==
                ["under48h", "between_48_and_72h", "over72h"])
    }

    @Test("All cases round-trip through Codable")
    func roundTrip() throws {
        for bucket in InterSessionGapBucket.allCases {
            let data = try JSONEncoder().encode(bucket)
            #expect(try JSONDecoder().decode(InterSessionGapBucket.self, from: data) == bucket)
        }
    }

    @Test("between48And72h encodes as snake_case raw value")
    func snakeCaseEncoding() throws {
        let data = try JSONEncoder().encode(InterSessionGapBucket.between48And72h)
        #expect(String(data: data, encoding: .utf8) == "\"between_48_and_72h\"")
    }

    @Test("between_48_and_72h string decodes to between48And72h")
    func snakeCaseDecoding() throws {
        let data = Data("\"between_48_and_72h\"".utf8)
        #expect(try JSONDecoder().decode(InterSessionGapBucket.self, from: data) == .between48And72h)
    }
}

@Suite("LimitationSubject")
struct LimitationSubjectTests {
    @Test("Pattern subject round-trips with kind+value discriminator")
    func patternRoundTrip() throws {
        let original = LimitationSubject.pattern(.horizontalPush)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LimitationSubject.self, from: data)
        #expect(decoded == original)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(json?["kind"] == "pattern")
        #expect(json?["value"] == "horizontal_push")
    }

    @Test("Muscle subject round-trips")
    func muscleRoundTrip() throws {
        let original = LimitationSubject.muscle(.legs)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LimitationSubject.self, from: data) == original)
    }

    @Test("Joint subject round-trips")
    func jointRoundTrip() throws {
        let original = LimitationSubject.joint(.lowerBack)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LimitationSubject.self, from: data) == original)
    }
}

// MARK: - #582: limitation → macro-plan prompt descriptor

@Suite("LimitationSubject.promptDescriptor (#582)")
struct LimitationPromptDescriptorTests {

    @Test("joint/muscle un-snake-cased; pattern uses its displayName")
    func subjectDescriptors() {
        #expect(LimitationSubject.joint(.knee).promptDescriptor == "knee")
        #expect(LimitationSubject.joint(.lowerBack).promptDescriptor == "lower back")
        #expect(LimitationSubject.muscle(.legs).promptDescriptor == "legs")
        #expect(LimitationSubject.pattern(.squat).promptDescriptor
                == MovementPattern.squat.displayName)
    }

    @Test("digest descriptor prefers the user's note, else the subject region")
    func digestPrefersNote() {
        let withNote = ActiveLimitationDigest(from: ActiveLimitation(
            subject: .joint(.knee), severity: .moderate, onsetDate: Date(),
            evidenceCount: 1, userConfirmed: true, notes: "left knee ACL"))
        #expect(withNote.promptDescriptor == "left knee ACL")

        let noNote = ActiveLimitationDigest(from: ActiveLimitation(
            subject: .joint(.shoulder), severity: .mild, onsetDate: Date(),
            evidenceCount: 1, userConfirmed: true, notes: nil))
        #expect(noNote.promptDescriptor == "shoulder")

        let blankNote = ActiveLimitationDigest(from: ActiveLimitation(
            subject: .joint(.hip), severity: .mild, onsetDate: Date(),
            evidenceCount: 1, userConfirmed: true, notes: "   "))
        #expect(blankNote.promptDescriptor == "hip", "whitespace-only note falls back to subject")
    }
}
