import SwiftUI

/// Keyboard-navigable "pick a type" chooser shown when a create shortcut
/// (⌘N / ⌃⌘N) fires and several types are possible — the toolbar's Add menu
/// can't be opened programmatically, so this stands in for it.
///
/// Uses the same chrome as the entity edit / duplicate / rights sheets: a
/// `NavigationStack` with the shared `CloseButton` in `.cancellationAction`
/// and the confirm button in `.confirmationAction`, plus an in-content
/// header on macOS (sheets don't render the toolbar's title slot there).
///
/// The type list is a selectable `List` — the only macOS control that gets
/// arrow-key navigation natively, independent of "Full Keyboard Access". The
/// list is focused shortly after appear (a beat late, or the sheet steals
/// focus back) so Up/Down move the selection immediately, Return (the
/// default Create button) or Space confirm, Escape closes.
///
/// The chosen option is reported via `onSelect` and the sheet dismisses
/// itself; the caller runs the create in the sheet's `onDismiss` so the
/// editor sheet doesn't try to present while this one is still closing.
struct TypePickerSheet: View {
    let title: String.LocalizationValue
    let options: [EntityCreateOption]
    let onSelect: (EntityCreateOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
                SheetHeader(title: headerTitle)
                #endif

                List(options, selection: $selection) { option in
                    Text(option.label)
                        .tag(option.id)
                }
                .focused($listFocused)
                // Space confirms; arrows are handled natively by the list;
                // Return is the default Create button.
                .onKeyPress(.space) { confirm() }
                // Plain style: no bordered box on macOS, and no section
                // insets on iOS — clean full-width rows on both.
                .listStyle(.plain)
            }
            .sheetNavigationTitle(headerTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        _ = confirm()
                    } label: {
                        Text("create")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: sheetHeight)
        #else
        // Standard centered iPad form sheet (a height detent would anchor it
        // to the bottom and clip; `.fitted` collapses with a List inside).
        .presentationSizing(.form)
        #endif
        .appLanguageScoped()
        .onAppear { selection = options.first?.id }
        .task {
            // The sheet grabs focus on present; hand it to the list a beat
            // later so arrow keys drive the selection without a click first.
            try? await Task.sleep(for: .milliseconds(120))
            listFocused = true
        }
    }

    private var headerTitle: String {
        String(localized: title, bundle: .currentLocalized)
    }

    #if os(macOS)
    /// macOS sheet min height — one row per type (capped) plus the header +
    /// toolbar chrome, so the window fits its content.
    private var sheetHeight: CGFloat {
        min(CGFloat(options.count), 8) * 28 + 92
    }
    #endif

    @discardableResult
    private func confirm() -> KeyPress.Result {
        guard let id = selection,
              let option = options.first(where: { $0.id == id }) else {
            return .ignored
        }
        onSelect(option)
        dismiss()
        return .handled
    }
}
