// UserIdentityResolver.swift
// ProjectApex — App Layer
//
// #369 auth slice 3. Pure (Keychain-injectable) resolution of the app's user
// identity. Extracted from `AppDependencies.resolvedUserId` and the onboarding
// user-insert so the precedence is deterministically testable with a scoped
// `KeychainService` (the `GenerationUserProfile.assemble` extraction precedent).
//
// THE REPOINT (slice 3): the app's identity is now the anonymous-auth
// `auth.uid()` established by slice 1, read synchronously from the persisted
// `.supabaseAuthUserId` Keychain entry. RLS is STILL OFF this slice, so the
// transitional fallback below is safe — old placeholder-keyed data still reads.

import Foundation

enum UserIdentityResolver {

    /// Resolves the user UUID for all Supabase writes and AI calls, in priority
    /// order:
    ///
    ///   1. `.supabaseAuthUserId` — the anonymous-auth `auth.uid()` slice 1
    ///      persists once a session is established. This is the identity slice 5's
    ///      `users` RLS policy (`id = auth.uid()`) will match.
    ///   2. `.userId` — the onboarding mirror. Kept as a secondary so an install
    ///      that minted a `.userId` before slice 1 (or before its session has
    ///      restored mid-launch) keeps reading its existing id rather than the
    ///      placeholder. Onboarding now writes `auth.uid()` here too, so the two
    ///      keys converge for fresh installs.
    ///   3. `placeholderUserId` — the TRANSITIONAL first-launch fallback. On a
    ///      fresh install the async anon sign-in may not have completed the first
    ///      time this is read; the placeholder keeps reads working in that window.
    ///      This is safe ONLY because RLS is off this slice (the fallback reads
    ///      succeed). It becomes vestigial once RLS lands (slice 5) + slice 1's
    ///      readiness gate guarantees a session before any RLS-gated read.
    static func resolve(keychain: KeychainService, placeholder: UUID) -> UUID {
        if let authUid = nonEmptyUUID(keychain, .supabaseAuthUserId) { return authUid }
        if let mirrored = nonEmptyUUID(keychain, .userId) { return mirrored }
        return placeholder
    }

    /// The id onboarding writes to the `public.users` row (and the `.userId`
    /// mirror): the resolved identity ONLY when it is the real auth uid. Returns
    /// `nil` when no auth session has resolved yet — the caller must then skip the
    /// `users` insert rather than persist a placeholder-keyed row that slice 5's
    /// RLS policy would later orphan.
    static func onboardingUserId(keychain: KeychainService, placeholder: UUID) -> UUID? {
        let resolved = resolve(keychain: keychain, placeholder: placeholder)
        return resolved == placeholder ? nil : resolved
    }

    private static func nonEmptyUUID(_ keychain: KeychainService, _ key: KeychainKey) -> UUID? {
        guard let stored = (try? keychain.retrieve(key)) ?? nil, !stored.isEmpty else { return nil }
        return UUID(uuidString: stored)
    }
}
