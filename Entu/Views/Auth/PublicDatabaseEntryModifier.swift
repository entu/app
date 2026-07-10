// Alert that adds a public database by name: validates the input,
// probes the API to confirm it's publicly readable, then registers and
// selects it via `AuthModel`. Used from AuthView, DatabaseListView, and
// UserSheet via the `.publicDatabaseEntry(...)` modifier.

import SwiftUI

extension View {
    /// Attach the public-database entry prompt + result alert to this view.
    /// Pass `isSubmitting` to drive a spinner on the parent's button while
    /// the API probe runs; defaults to `.constant(false)` for callers that
    /// don't need the state.
    func publicDatabaseEntry(
        isPresented: Binding<Bool>,
        isSubmitting: Binding<Bool> = .constant(false)
    ) -> some View {
        modifier(PublicDatabaseEntryModifier(
            isPresented: isPresented,
            isSubmitting: isSubmitting
        ))
    }
}

/// Matches `formatDatabaseName()` in `api/utils/mongodb.js`. Computed each
/// access because `Regex` isn't `Sendable` under Swift 6 strict concurrency.
private var publicDatabaseNameRegex: Regex<Substring> { /^[a-z][a-z0-9_]*$/ }

private struct PublicDatabaseEntryModifier: ViewModifier {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api

    @Binding var isPresented: Bool
    @Binding var isSubmitting: Bool
    @State private var input: String = ""
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
            .appLanguageScoped()
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
