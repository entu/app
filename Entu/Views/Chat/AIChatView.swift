// Entu AI assistant panel. Presents the conversation, the close + input
// controls (standard bottom-toolbar items on iOS; a hand-built glass bar
// on macOS, whose custom column has no bottom toolbar), example prompts on
// an empty conversation, and the proposal review flow. Mirrors the webapp's
// `components/chat/drawer.vue`. Presented from the sidebar's Entu AI
// button; account-scoped state lives in `AIChatModel`.

import SwiftUI

/// Chat conversation UI hosted in a sheet.
struct AIChatView: View {
    @Environment(AIChatModel.self) private var chat

    /// Open a created entity in the main layout (dismisses this sheet).
    let onOpenEntity: (String) -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    /// Example prompt keys — displayed localized and sent as resolved text.
    private let examplePromptKeys = ["aiExample1", "aiExample2", "aiExample3", "aiExample4", "aiExample5"]

    var body: some View {
        platformBody
            // The assistant links entities as relative URLs ("/{db}/{id}",
            // per the API's system prompt). The OS can't open those — route
            // them to in-app navigation instead.
            .environment(\.openURL, OpenURLAction { url in
                if let entityId = entityId(from: url) {
                    openEntity(entityId)
                    return .handled
                }
                return .systemAction
            })
            .appLanguageScoped()
            .onAppear { inputFocused = true }
    }

    /// iOS hosts close + input as standard bottom-toolbar items (system
    /// glass, matching the sidebar's toolbars) — the `NavigationStack`
    /// exists only to provide the toolbar context. macOS keeps the
    /// hand-built glass bar: its custom trailing column has no bottom
    /// toolbar to target.
    @ViewBuilder
    private var platformBody: some View {
        #if os(iOS)
        NavigationStack {
            messageList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Panel tone — the white card surface, a step lighter
                // than the window background.
                .background(Color("CardBackground").ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        closeButton
                    }

                    // Fixed spacer splits the shared glass pod — close and
                    // input render as separate capsules (same pattern as
                    // the list column's filter · search · New).
                    ToolbarSpacer(.fixed, placement: .bottomBar)

                    ToolbarItem(placement: .bottomBar) {
                        inputCore
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            // No in-content title — the panel is self-evidently the
            // assistant.
            messageList
        }
        // The input bar floats over the message scroll as a glass surface —
        // messages scroll under it, per the Liquid Glass controls-layer
        // guidance.
        .safeAreaBar(edge: .bottom) { bottomBar }
        // Panel tone — the white card surface, a step lighter than the
        // window background, covering the toolbar strip too.
        .background(Color("CardBackground").ignoresSafeArea())
        #endif
    }

    /// Extracts the entity id from an AI-generated entity link — the last
    /// path component when it looks like a MongoDB ObjectId.
    private func entityId(from url: URL) -> String? {
        guard url.scheme == nil || url.scheme == "https" || url.scheme == "entu" else { return nil }

        let last = url.lastPathComponent
        guard last.count == 24, last.allSatisfy(\.isHexDigit) else { return nil }

        return last
    }

    // MARK: - Messages

    @ViewBuilder
    private var messageList: some View {
        if chat.visibleMessages.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(chat.visibleMessages) { message in
                            ChatMessageView(
                                message: message,
                                isPending: message.id == chat.pendingMessageId,
                                isExecuting: chat.isExecuting,
                                onApply: { Task { await chat.confirm(message.id) } },
                                onCancel: { chat.reject(message.id) },
                                onOpenEntity: openEntity
                            )
                            .id(message.id)
                        }

                        if chat.isLoading {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.indigo)
                                    .symbolEffect(.pulse, options: .repeating)
                                Text("aiThinking")
                                    .foregroundStyle(.secondary)
                            }
                            .id(loadingAnchor)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: chat.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: chat.isLoading) {
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(.indigo)

            Text("aiEmptyHint")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Suggestion pills flow inline, wrapping as needed.
            FlowLayout(spacing: 6, centered: true) {
                ForEach(examplePromptKeys, id: \.self) { key in
                    Button {
                        send(String(localized: String.LocalizationValue(key), bundle: .currentLocalized))
                    } label: {
                        Text(LocalizedStringKey(key))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            // The edit form's quiet-input fill — reads as a
                            // chip on the panel's white.
                            .background(Color.primary.opacity(0.05), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
    }

    // MARK: - Input

    /// The bare input field. iOS: single-line in a bottom-toolbar item
    /// (the toolbar supplies the glass); Return sends via `onSubmit` —
    /// a multi-line field would swallow the software keyboard's Return
    /// as a newline. macOS: multi-line, wrapped in its own glass surface
    /// (`inputField`).
    @ViewBuilder
    private var inputCore: some View {
        #if os(iOS)
        TextField("aiInputPrompt", text: $input)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .disabled(chat.isLoading)
            .submitLabel(.send)
            .onSubmit { send(input) }
        #else
        TextField("aiInputPrompt", text: $input, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($inputFocused)
            .disabled(chat.isLoading)
            // Enter sends; Shift+Enter inserts a newline (handled explicitly —
            // the field's default Shift+Return isn't a newline).
            .onKeyPress { keyPress in
                guard keyPress.key == .return else { return .ignored }

                if keyPress.modifiers.contains(.shift) {
                    input += "\n"
                } else {
                    send(input)
                }
                return .handled
            }
        #endif
    }

    #if os(iOS)
    /// Standard toolbar close button — plain, system-drawn chrome, like
    /// the sidebar's toolbar buttons.
    private var closeButton: some View {
        Button {
            chat.isOpen = false
        } label: {
            Image(systemName: "xmark")
        }
        .accessibilityLabel("close")
    }

    #endif

    #if os(macOS)
    /// Circular glass close (X) next to the glass input field. Wrapped in a
    /// `GlassEffectContainer` so the two glass shapes blend correctly when
    /// they come close.
    private var bottomBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    chat.isOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("close")

                inputField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var inputField: some View {
        inputCore
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            // Standard glass surface — blends with the glass close button
            // via the shared GlassEffectContainer.
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
    #endif

    // MARK: - Actions

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chat.isLoading else { return }

        input = ""
        Task {
            await chat.send(trimmed)
            inputFocused = true
        }
    }

    /// Open a created entity: close the chat first so navigation is visible.
    private func openEntity(_ id: String) {
        chat.isOpen = false
        onOpenEntity(id)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if chat.isLoading {
                proxy.scrollTo(loadingAnchor, anchor: .bottom)
            } else if let lastId = chat.visibleMessages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    private let loadingAnchor = "ai-loading-anchor"
}
