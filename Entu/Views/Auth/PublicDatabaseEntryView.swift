// System alert with a text field for adding a public database by name.
//
// Validates the input against the API's database-name rules
// (lowercase letter prefix, then letters/digits/underscores), probes the API
// without a token to confirm the database exists and is publicly readable,
// then registers the database with `AuthModel` and selects it.
//
// Use via `.publicDatabaseEntry(isPresented: $flag)` modifier on any view —
// AuthView, DatabaseListView, and UserSheet all share the same dialog.

import SwiftUI

extension View {
    /// Attach the "Browse public database" prompt + result alert to this view.
    func publicDatabaseEntry(isPresented: Binding<Bool>) -> some View {
        modifier(PublicDatabaseEntryModifier(isPresented: isPresented))
    }
}

/// Matches `formatDatabaseName()` in api/utils/mongodb.js — must start with
/// a lowercase letter and contain only `[a-z0-9_]`. Computed each access
/// because `Regex` isn't `Sendable` and can't be stored in a top-level `let`
/// under Swift 6 strict concurrency.
private var publicDatabaseNameRegex: Regex<Substring> { /^[a-z][a-z0-9_]*$/ }

private struct PublicDatabaseEntryModifier: ViewModifier {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api

    @Binding var isPresented: Bool
    @State private var input: String = ""
    @State private var isSubmitting = false
    @State private var error: LocalizedStringKey?

    func body(content: Content) -> some View {
        content
            .alert("publicDatabaseTitle", isPresented: $isPresented) {
                TextField("databaseName", text: $input)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    #endif

                Button("open") { Task { await submit() } }

                Button("cancel", role: .cancel) {
                    input = ""
                }
            } message: {
                Text("publicDatabasePrompt")
            }
            .alert(
                "publicDatabaseTitle",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                )
            ) {
                Button("ok", role: .cancel) {
                    input = ""
                }
            } message: {
                if let error {
                    Text(error)
                }
            }
            .disabled(isSubmitting)
    }

    private func submit() async {
        let name = input
        guard name.wholeMatch(of: publicDatabaseNameRegex) != nil else {
            error = "databaseInvalidFormat"
            return
        }

        // Already known database? Skip the probe entirely.
        if let existing = auth.databases.first(where: { $0._id == name }) {
            auth.selectDatabase(existing)
            input = ""
            return
        }
        if auth.publicDatabases.contains(name) {
            auth.selectPublicDatabase(name)
            input = ""
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            switch try await api.probePublicDatabase(name) {
            case .found:
                auth.addPublicDatabase(name)
                auth.selectPublicDatabase(name)
                input = ""
            case .notFound:
                error = "databaseNotFound"
            case .notPublic:
                error = "databaseNotPublic"
            }
        } catch {
            self.error = "networkError"
        }
    }
}
