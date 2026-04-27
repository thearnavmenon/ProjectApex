// Features/Workout/ExerciseSwapView.swift
// ProjectApex
//
// Chat-style sheet for mid-session exercise swaps (P3-T10).
// Presented as a .large detent sheet over ActiveSetView.
//
// Layout:
//   ┌─────────────────────────────┐
//   │  Swap Exercise         [X]  │  ← header
//   ├─────────────────────────────┤
//   │  (chat bubbles)             │  ← scrollable message list
//   ├─────────────────────────────┤
//   │  [chip] [chip] [chip]       │  ← quick replies (hidden after suggestion)
//   │  [Confirm Swap]             │  ← visible only when suggestion is pending
//   │  [_____________] [Send]     │  ← text input bar
//   └─────────────────────────────┘

import SwiftUI

// MARK: - ExerciseSwapView

struct ExerciseSwapView: View {

    @State var viewModel: ExerciseSwapViewModel

    // Background colour token
    private let bg = Color(red: 0.07, green: 0.08, blue: 0.10)
    private let bubbleAssistant = Color(red: 0.14, green: 0.15, blue: 0.18)
    private let bubbleUser = Color(red: 0.23, green: 0.56, blue: 1.00)
    private let accentOrange = Color(red: 1.00, green: 0.60, blue: 0.20)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.10))
                messageList
                bottomBar
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(24)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Swap Exercise")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("AI-powered substitution")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button {
                viewModel.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.35))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if viewModel.isProcessing {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation {
                    if let last = viewModel.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.isProcessing) { _, processing in
                if processing {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ExerciseSwapService.ChatMessage) -> some View {
        let isUser = message.role == .user || message.role == .chip
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(message.displayText)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser ? bubbleUser : bubbleAssistant,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .multilineTextAlignment(isUser ? .trailing : .leading)

                // Suggestion card inside assistant bubble
                if let suggestion = message.suggestion {
                    suggestionCard(suggestion)
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func suggestionCard(_ s: ExerciseSwapService.ExerciseSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentOrange)
                Text("Suggested Swap")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentOrange)
            }
            Text(s.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            let weightLabel = s.suggestedWeightKg == 0 ? "BW" : "\(Int(s.suggestedWeightKg)) kg"
            Text("\(weightLabel) · \(s.suggestedReps) reps")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))

            Text(s.reasoning)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.50))
                .italic()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accentOrange.opacity(0.30), lineWidth: 1)
        )
    }

    private var thinkingIndicator: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.white.opacity(0.40))
                        .frame(width: 7, height: 7)
                        .scaleEffect(viewModel.isProcessing ? 1.0 : 0.5)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                            value: viewModel.isProcessing
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleAssistant, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer()
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.10))

            VStack(spacing: 10) {
                // Quick reply chips — hidden once a suggestion is pending
                if viewModel.pendingSuggestion == nil && !viewModel.isProcessing {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.quickReplyChips, id: \.self) { chip in
                                Button {
                                    viewModel.sendChip(chip)
                                } label: {
                                    Text(chip)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(0.10), in: Capsule())
                                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Confirm Swap button — appears only when a suggestion is present
                if viewModel.pendingSuggestion != nil {
                    Button {
                        viewModel.confirmSwap()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Confirm Swap")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(accentOrange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                }

                // Text input bar
                HStack(spacing: 10) {
                    TextField("Type a message…", text: $viewModel.inputText)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .onSubmit { viewModel.sendMessage() }

                    Button {
                        viewModel.sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(
                                viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.white.opacity(0.20)
                                    : bubbleUser
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isProcessing)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.top, 10)
        }
        .background(bg)
    }
}
