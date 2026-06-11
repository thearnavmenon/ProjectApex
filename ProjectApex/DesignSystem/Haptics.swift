// Haptics.swift
// ProjectApex — DesignSystem
//
// The haptic vocabulary (DESIGN.md §Haptics). Each entry is a distinct physical
// metaphor: `.medium` is the plate-thud and `.rigid` is the pawl — both spoken
// for — so other interactions stay silent (feel-pill, routine-nav carry no haptic).

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum Haptics {
    #if canImport(UIKit)
    /// `set-logged` — the thud of a plate set down.
    static func setLogged() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// `rest-complete` — two light taps.
    static func restComplete() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            generator.impactOccurred()
        }
    }

    /// `milestone` — the ratchet click: success notification + rigid impact.
    static func milestone() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// `back-off` — safety / warning.
    static func backOff() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// `scrub-snap` — chart-scrub detents (Progress). Selection, never impact.
    static func scrubSnap() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    #else
    static func setLogged() {}
    static func restComplete() {}
    static func milestone() {}
    static func backOff() {}
    static func scrubSnap() {}
    #endif
}
