// Bespoke editors for the reserved auth properties (`entu_api_key`,
// `entu_user`, `entu_passkey`) — string-typed properties whose names carry
// special server-side behaviour. Mirrors the reserved-name branches of the
// webapp's `components/property/edit.vue` template (lines 447–547): the
// client sends sentinel strings ('generate' / 'send-invite' / 'self-invite')
// through the normal property commit and the API does the real work.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension PropertyEditor {
    /// Reserved property names that get a bespoke editor instead of the
    /// plain string field. `EntityEditView` also consults this to suppress
    /// the generic list-row delete × (these editors own their delete
    /// affordances) and to skip them for first-field auto-focus.
    static let reservedAuthNames: Set<String> = ["entu_api_key", "entu_user", "entu_passkey"]

    /// True when this row renders via `authPropertyEditor`. Type-gated to
    /// `string` like the webapp's `type === 'string' && property === …`.
    var isReservedAuthProperty: Bool {
        definition.type == "string" && Self.reservedAuthNames.contains(definition.name)
    }

    var authPropertyEditor: some View {
        Group {
            switch definition.name {
            case "entu_api_key": apiKeyEditor
            case "entu_user": userEditor
            default: passkeyEditor
            }
        }
        // Every × routes here — deletes are confirmed, same as the saved
        // file row's dialog in `PropertyEditor+File.savedFileRow`.
        .confirmationDialog(
            Text("deleteAuthConfirmTitle \(authValueLabel)"),
            isPresented: $showingDeleteAuthConfirm,
            titleVisibility: .visible
        ) {
            // Question and action share the verb (ET: Kustuta …? → Kustuta).
            Button("delete", role: .destructive) {
                Task { await onDelete() }
            }
            Button("cancel", role: .cancel) {}
        }
    }

    /// Display name of the value being deleted, for the confirm title —
    /// the same text the row's pill shows.
    private var authValueLabel: String {
        switch definition.name {
        case "entu_api_key":
            return String(localized: "apiKey", bundle: .currentLocalized)
        case "entu_user":
            if value.invite != nil { return value.email ?? "" }
            return userDisplayLabel
        default:
            return value.stringValue
        }
    }

    /// Registered-login display text — the login string, falling back to
    /// the email. Shared by the pill and the confirm title.
    private var userDisplayLabel: String {
        value.stringValue.isEmpty ? (value.email ?? "") : value.stringValue
    }

    /// Saved-value row: the pill hugging leading, like the other chips.
    private func authChipRow(_ chip: AuthChip) -> some View {
        HStack(spacing: 8) {
            chip
            Spacer(minLength: 0)
        }
    }

    // MARK: - entu_api_key

    /// Generate → one-time raw key with copy → masked (`***`) with delete.
    /// The server stores only the key's SHA-256 hash; the raw key exists
    /// solely in this row until the sheet closes.
    @ViewBuilder
    private var apiKeyEditor: some View {
        if value._id != nil && value.stringValue == "***" {
            authChipRow(AuthChip(
                provider: nil,
                fallbackIcon: "key",
                label: String(localized: "apiKey", bundle: .currentLocalized),
                onDelete: { showingDeleteAuthConfirm = true }
            ))
        } else if value._id != nil {
            HStack(spacing: 8) {
                Text(verbatim: value.stringValue)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button {
                    copyToPasteboard(value.stringValue)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.tint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("copy")

                Spacer(minLength: 0)
            }
        } else {
            authAddChip("generateApiKey", systemImage: "plus") {
                // Sentinel — the API generates a key for any `entu_api_key`
                // insert; webapp sends the same marker string.
                value.stringValue = "generate"
                await onCommit()
            }
        }
    }

    // MARK: - entu_user

    /// Pending invite → cancel; registered login → provider icon + delete;
    /// empty on another user → send invite; empty on own entity → add
    /// login method (self-invite → provider sheet via `EntityEditView`).
    @ViewBuilder
    private var userEditor: some View {
        if value._id != nil && value.invite != nil {
            HStack(spacing: 8) {
                if let email = value.email {
                    Text("invitePending \(email)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Same × as the auth pills — cancels the pending invite.
                ChipDeleteButton(accessibilityKey: "cancelInvite") {
                    showingDeleteAuthConfirm = true
                }
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
        } else if value._id != nil {
            authChipRow(AuthChip(
                provider: value.provider,
                label: userDisplayLabel,
                onDelete: { showingDeleteAuthConfirm = true }
            ))
        } else if isOwnEntity {
            authAddChip("addLoginMethod", systemImage: "envelope") {
                value.stringValue = "self-invite"
                await onCommit()
            }
        } else {
            authAddChip("sendInvite", systemImage: "envelope") {
                // The API reads the entity's `email` property and mails the
                // invite link; 400 "No email" surfaces via `commitError`.
                value.stringValue = "send-invite"
                await onCommit()
            }
        }
    }

    // MARK: - entu_passkey

    /// Saved passkey → masked-name pill with the trailing ×; empty on own
    /// entity → register via `PasskeyService`; otherwise an own-entity-only
    /// note. Deviation from webapp: saved rows also show the server-masked
    /// "{device} {last4}" name so multiple passkeys stay tellable apart
    /// (webapp shows only a delete button).
    @ViewBuilder
    private var passkeyEditor: some View {
        if value._id != nil {
            authChipRow(AuthChip(
                provider: nil,
                fallbackIcon: "person.badge.key",
                label: value.stringValue,
                onDelete: { showingDeleteAuthConfirm = true }
            ))
        } else if isOwnEntity {
            authAddChip("registerPasskey", systemImage: "person.badge.key") {
                await onRegisterPasskey()
            }
        } else {
            Text("passkeyOwnOnly")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared pieces

    /// Dashed add chip (shared `DashedAddLabel`) wrapping an async action —
    /// used for every add-type auth action.
    private func authAddChip(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            DashedAddLabel(titleKey: titleKey, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}
