// Features/Workout/ExerciseSwapViewModel.swift
// ProjectApex
//
// @Observable @MainActor bridge from ExerciseSwapService actor to SwiftUI.
// Drives ExerciseSwapView and relays the confirmed swap back to WorkoutViewModel.

import SwiftUI

// MARK: - ExerciseSwapViewModel

@Observable
@MainActor
final class ExerciseSwapViewModel {

    // MARK: - Displayed state (read by ExerciseSwapView)

    var messages: [ExerciseSwapService.ChatMessage] = []
    var isProcessing: Bool = false
    var inputText: String = ""

    /// The most recent suggestion from the AI (nil until one arrives).
    var pendingSuggestion: ExerciseSwapService.ExerciseSuggestion? = nil

    /// Called when the user confirms a swap — wired to WorkoutViewModel.
    var onConfirmSwap: ((ExerciseSwapService.ExerciseSuggestion, String) -> Void)?

    /// Called when the user dismisses without swapping.
    var onDismiss: (() -> Void)?

    // MARK: - Quick reply chips

    let quickReplyChips: [String] = [
        "Equipment taken",
        "Too heavy",
        "Feeling pain",
        "Wrong muscle focus",
        "No equipment available"
    ]

    // MARK: - Private

    private let service: ExerciseSwapService
    private var currentContext: ExerciseSwapService.SwapContext?
    /// The reason label shown to the user before confirming (set to the last chip/message sent).
    private var lastUserReason: String = ""

    // MARK: - Init

    init(service: ExerciseSwapService) {
        self.service = service
    }

    // MARK: - Public API

    func startConversation(context: ExerciseSwapService.SwapContext) {
        currentContext = context
        Task {
            await service.startConversation(context: context)
            await pullState()
        }
    }

    func sendChip(_ text: String) {
        lastUserReason = text
        send(text, isChip: true)
    }

    func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let text = inputText
        lastUserReason = text
        inputText = ""
        send(text, isChip: false)
    }

    /// Called when the user taps "Confirm Swap".
    func confirmSwap() {
        guard let suggestion = pendingSuggestion else { return }
        onConfirmSwap?(suggestion, lastUserReason)
    }

    /// Called when the user dismisses without swapping.
    func dismiss() {
        Task {
            await service.reset()
        }
        onDismiss?()
    }

    // MARK: - Private helpers

    private func send(_ text: String, isChip: Bool) {
        Task {
            await service.sendMessage(text, isChip: isChip)
            await pullState()
        }
    }

    private func pullState() async {
        let msgs = await service.messages
        let processing = await service.isProcessing
        messages = msgs
        isProcessing = processing
        // Surface the latest assistant suggestion (if any)
        pendingSuggestion = msgs.last(where: { $0.role == .assistant })?.suggestion
    }
}
