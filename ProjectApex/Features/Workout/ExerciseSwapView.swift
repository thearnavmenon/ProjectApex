// Features/Workout/ExerciseSwapView.swift
// ProjectApex
//
// Chat-style sheet for mid-session exercise swaps (P3-T10).
// Presented as a .large detent sheet over ActiveSetView.
//
// Restyled to the Brutalist Athletic identity (umbrella #473): pure-black
// surfaces, volt-lime accent reserved for the primary action, sharp corners,
// condensed labels. Visual layer only — all behaviour, state, bindings and
// the onConfirmSwap callback are preserved.
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

    var body: some View {
        ZStack {
            Apex.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                messageList
                bottomBar
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(Apex.corner)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Swap Exercise")
                    .font(.system(size: 19, weight: .heavy))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)
                Text("AI-powered substitution")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Apex.textFaint)
            }
            Spacer()
            Button {
                viewModel.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Apex.textDim)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Apex.surface))
                    .overlay(Circle().stroke(Apex.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Apex.pad)
        .padding(.vertical, 16)
        .overlay(Rectangle().fill(Apex.hairline).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if viewModel.isProcessing {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(.horizontal, Apex.pad)
                .padding(.vertical, 14)
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
            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                Text(message.displayText)
                    .font(.system(size: 15, weight: isUser ? .semibold : .medium))
                    .foregroundStyle(isUser ? Apex.onAccent : Apex.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                            .fill(isUser ? Apex.accent : Apex.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                            .stroke(isUser ? Color.clear : Apex.hairline, lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    ApexSectionLabel(text: "Swap to", color: Apex.accent)
                    Text(s.name)
                        .font(.system(size: 18, weight: .heavy))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            let weightLabel = s.suggestedWeightKg == 0 ? "BW" : "\(Int(s.suggestedWeightKg)) kg"
            Text("\(weightLabel) · \(s.suggestedReps) reps")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .fontWidth(.condensed)
                .foregroundStyle(Apex.textDim)

            Text(s.reasoning)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Apex.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard(emphasized: true)
    }

    private var thinkingIndicator: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Apex.accent.opacity(0.80))
                        .frame(width: 7, height: 7)
                        .scaleEffect(viewModel.isProcessing ? 1.0 : 0.5)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                            value: viewModel.isProcessing
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .fill(Apex.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .stroke(Apex.hairline, lineWidth: 1)
            )
            Spacer()
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Apex.hairline).frame(height: 1)

            VStack(spacing: 12) {
                // Quick reply chips — hidden once a suggestion is pending
                if viewModel.pendingSuggestion == nil && !viewModel.isProcessing {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.quickReplyChips, id: \.self) { chip in
                                Button {
                                    viewModel.sendChip(chip)
                                } label: {
                                    Text(chip)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Apex.text)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .background(Capsule().fill(Apex.surface))
                                        .overlay(Capsule().stroke(Apex.hairline, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Apex.pad)
                    }
                }

                // Confirm Swap button — appears only when a suggestion is present
                if viewModel.pendingSuggestion != nil {
                    Button {
                        viewModel.confirmSwap()
                    } label: {
                        ApexButton(title: "Confirm Swap", icon: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Apex.pad)
                }

                // Text input bar
                HStack(spacing: 10) {
                    TextField("", text: $viewModel.inputText, prompt:
                        Text("Message coach…").foregroundStyle(Apex.textFaint)
                    )
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Apex.text)
                        .tint(Apex.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Apex.surface))
                        .overlay(Capsule().stroke(Apex.hairline, lineWidth: 1))
                        .onSubmit { viewModel.sendMessage() }

                    let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty
                        && !viewModel.isProcessing
                    Button {
                        viewModel.sendMessage()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(canSend ? Apex.onAccent : Apex.textFaint)
                            .frame(width: 46, height: 46)
                            .background(
                                Circle().fill(canSend ? Apex.accent : Apex.surface)
                            )
                            .overlay(
                                Circle().stroke(canSend ? Color.clear : Apex.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
                .padding(.horizontal, Apex.pad)
                .padding(.bottom, 8)
            }
            .padding(.top, 12)
        }
        .background(Apex.bg)
    }
}
