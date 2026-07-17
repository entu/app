// Inline entity picker — the design's "Reference picker (inline)": the
// add-trigger row swaps to a text field in place, a compact results panel
// opens beneath it, and Esc / blur / click-outside / selection collapses
// back. The app's only reference-picking UI: Parents ("Select new
// parent"), Rights ("Add user"), advanced search (entity types), and the
// edit form's reference properties.
//
// Search mirrors webapp's `my-select-reference.vue`: the caller's scope
// `query` plus free-text `q`, sorted by name, limit 100. The design's
// "+ Create new …" row is not implemented — tracked in
// TODO-new-features.md.

import SwiftUI

/// Search-as-you-type inline entity picker with a floating results panel.
struct InlineReferencePicker: View {
    @Environment(APIClient.self) private var api

    /// Scope filter — URL-query formatted API filters (e.g. a property
    /// definition's `reference_query`). nil ⇒ unscoped.
    let query: String?

    /// Extra property fetched and preferred for row display (e.g. `label`
    /// on entity-type definitions — webapp shows label || name). The
    /// `onSelect` name stays the entity's `name` property.
    var labelProperty: String?

    /// Entity `name`s to hide from the results — used by multi-select
    /// hosts (advanced search types) so picked items don't repeat.
    var excludeNames: [String] = []

    /// Called with the picked entity's id and name.
    let onSelect: (String, String) -> Void

    /// Collapse back to the trigger row (Esc, blur, or selection).
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var results: [Match] = []
    @State private var totalCount: Int?
    @State private var isSearching = true
    @State private var highlighted = 0
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    #if os(macOS)
    /// Click-outside detection — macOS clicks on non-focusable controls
    /// (toggles, chips, empty sheet area) don't move keyboard focus, so
    /// the blur-based collapse alone would leave the panel open. A local
    /// event monitor closes the picker on any click outside its frame.
    @State private var clickMonitor: Any?
    @State private var pickerFrame: CGRect = .zero
    #endif

    private static let pageLimit = 100

    /// One dropdown row.
    private struct Match: Identifiable {
        let _id: String
        let name: String
        let label: String?
        let typeLabel: String?
        let hasPhoto: Bool
        var id: String { _id }

        var displayName: String { label ?? name }
    }

    var body: some View {
        VStack(spacing: 6) {
            searchField
            resultsPanel
        }
        .task { await runSearch() }
        .onAppear { focused = true }
        #if os(macOS)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { pickerFrame = $0 }
        .onAppear { installClickMonitor() }
        .onDisappear { removeClickMonitor() }
        #endif
    }

    #if os(macOS)
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handleGlobalClick(event)
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    /// Close when a click lands outside the picker. SwiftUI's `.global`
    /// frame is top-left-origin within the window's content view; AppKit
    /// event locations are bottom-left-origin — flip before comparing.
    private func handleGlobalClick(_ event: NSEvent) {
        guard let contentView = event.window?.contentView else { return }

        let point = contentView.convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(
            x: point.x,
            y: contentView.isFlipped ? point.y : contentView.bounds.height - point.y
        )
        if !pickerFrame.insetBy(dx: -4, dy: -4).contains(flipped) {
            onDismiss()
        }
    }
    #endif

    // MARK: - Field

    private var searchField: some View {
        TextField("search", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onKeyPress { press in handleKey(press) }
            .onChange(of: text) { scheduleSearch() }
            .onChange(of: focused) { collapseOnBlur() }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 2)
            }
    }

    /// Esc collapses; arrows move the highlight; Return picks it.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            onDismiss()
            return .handled
        case .downArrow:
            highlighted = min(highlighted + 1, results.count - 1)
            return .handled
        case .upArrow:
            highlighted = max(highlighted - 1, 0)
            return .handled
        case .return:
            guard results.indices.contains(highlighted) else { return .ignored }

            pick(results[highlighted])
            return .handled
        default:
            return .ignored
        }
    }

    /// Blur collapses the picker — after a beat, so a click/tap on a result
    /// row (which may drop field focus first) still lands.
    private func collapseOnBlur() {
        guard !focused else { return }

        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !focused else { return }

            onDismiss()
        }
    }

    // MARK: - Results panel

    @ViewBuilder
    private var resultsPanel: some View {
        if isSearching && results.isEmpty {
            EmptyView()
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, match in
                        resultRow(match, isHighlighted: index == highlighted)
                            .onHover { hovering in
                                if hovering { highlighted = index }
                            }
                    }

                    if results.isEmpty {
                        Text("noResults")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else if let total = totalCount, total > results.count {
                        Text("foundMore \(total - results.count)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 5)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Color("CardHairline"), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        }
    }

    /// Row metrics — matches the entity list's rows on touch platforms
    /// (avatar 24, spacing 9, ≈44pt targets); macOS uses the design's
    /// compact dropdown density.
    #if os(macOS)
    private static let rowAvatarSize: CGFloat = 20
    private static let rowSpacing: CGFloat = 8
    private static let rowVerticalPadding: CGFloat = 5
    #else
    private static let rowAvatarSize: CGFloat = 24
    private static let rowSpacing: CGFloat = 9
    private static let rowVerticalPadding: CGFloat = 10
    #endif

    private func resultRow(_ match: Match, isHighlighted: Bool) -> some View {
        Button {
            pick(match)
        } label: {
            HStack(spacing: Self.rowSpacing) {
                EntityAvatar(name: match.displayName, entityId: match._id, hasPhoto: match.hasPhoto, size: Self.rowAvatarSize)

                Text(highlightedName(match.displayName))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let typeLabel = match.typeLabel, !typeLabel.isEmpty {
                    Text(verbatim: typeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, Self.rowVerticalPadding)
            .padding(.horizontal, 8)
            .background(
                isHighlighted ? Color.accentColor.opacity(0.1) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The typed text emphasized inside the entity name, per the design
    /// ("**Roo**sleht, Milvi").
    private func highlightedName(_ name: String) -> AttributedString {
        var attributed = AttributedString(name)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty,
           let range = attributed.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }

    // MARK: - Search

    private func pick(_ match: Match) {
        onSelect(match._id, match.name)
        onDismiss()
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            await runSearch()
        }
    }

    private func runSearch() async {
        isSearching = true
        defer { isSearching = false }

        var params = (query ?? "").parseURLQuery()
        if !text.isEmpty {
            params["q"] = text
        }
        params["props"] = ["_type.string,name,photo", labelProperty].compactMap(\.self).joined(separator: ",")
        params["sort"] = "name.string"
        params["limit"] = "\(Self.pageLimit)"

        guard let response: EntityListResponse = try? await api.get("entity", params: params) else {
            results = []
            totalCount = nil
            return
        }

        results = response.entities.compactMap { entity in
            if excludeNames.contains(entity.displayName) { return nil }

            return Match(
                _id: entity._id,
                name: entity.displayName,
                label: labelProperty.flatMap { PropertyValue.localized(entity.additionalProperties?[$0]) },
                typeLabel: PropertyValue.localized(entity.additionalProperties?["_type"]),
                hasPhoto: entity.hasPhoto
            )
        }
        totalCount = response.count
        highlighted = 0
    }
}
