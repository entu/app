// Read-only property row for the entity detail view — label column plus
// type-specific value rendering (references as tappable pills, files as
// QuickLook chips, markdown text, …).

import QuickLook
import SwiftUI

/// Single property row — label left, type-specific value(s) right.
/// Handles type-specific formatting: string, number, boolean, reference,
/// date, datetime, file, and auth-provider values. File properties use
/// QuickLook for native preview.
struct PropertyRow: View {
    @Environment(APIClient.self) private var api
    @Environment(\.locale) private var locale

    let definition: PropertyDefinition
    let values: [PropertyValue]

    /// Called when user taps a reference — navigates to that entity.
    var onNavigate: ((String) -> Void)?

    @State private var previewURL: URL?

    /// Filter multilingual values to the user's preferred language.
    /// Priority matches `PropertyValue.best`: in-app language → no language
    /// → first available. Reads from `AppLanguage.resolvedLanguageCode` so
    /// the in-app toggle is honoured (not just system locale).
    private var displayValues: [PropertyValue] {
        let language = AppLanguage.resolvedLanguageCode
        let localized = values.filter { $0.language == language }
        if !localized.isEmpty { return localized }
        let untagged = values.filter { $0.language == nil }
        if !untagged.isEmpty { return untagged }
        return values
    }

    // Hide empty non-mandatory properties in read-only view.
    var isVisible: Bool {
        !displayValues.isEmpty || definition.mandatory
    }

    var body: some View {
        if isVisible {
            LabeledRow(alignment: .top) {
                Text(definition.displayLabel(valueCount: displayValues.count))
                    .font(.subheadline)
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(displayValues.enumerated()), id: \.offset) { _, value in
                        renderValue(value)
                    }
                }
            }
            .padding(.vertical, 4)
            .quickLookPreview($previewURL)
        }
    }

    // MARK: - Type dispatch

    /// Dispatch a single value to the renderer matching its declared type.
    /// Values with a reference are always rendered as tappable links, regardless of declared type.
    @ViewBuilder
    private func renderValue(_ value: PropertyValue) -> some View {
        if let ref = value.reference {
            referenceButton(id: ref, name: value.string)
        } else if value.provider != nil {
            providerValue(value)
        } else {
            switch definition.type {
            case "boolean": booleanValue(value)
            case "number": numberValue(value)
            case "date": dateValue(value)
            case "datetime": datetimeValue(value)
            case "file": fileValue(value)
            case "text": textValue(value)
            default:
                if definition.name == "entu_passkey" {
                    passkeyValue(value)
                } else if definition.name == "entu_api_key" {
                    apiKeyValue
                } else {
                    stringValue(value)
                }
            }
        }
    }

    // MARK: - String and text

    /// Render a string value, as Markdown when the definition flag is set.
    @ViewBuilder
    private func stringValue(_ value: PropertyValue) -> some View {
        if definition.markdown, let str = value.string,
           let attributed = try? AttributedString(markdown: str) {
            Text(attributed)
        } else if let str = value.string {
            Text(str).textSelection(.enabled)
        }
    }

    /// Render a multi-line text value with unlimited line count.
    @ViewBuilder
    private func textValue(_ value: PropertyValue) -> some View {
        if let str = value.string {
            Text(str)
                .textSelection(.enabled)
                .lineLimit(nil)
        }
    }

    // MARK: - Number and boolean

    /// Render a number value, respecting the definition's decimal precision.
    /// `decimals` defaults to 0 (whole-number display) when not declared.
    @ViewBuilder
    private func numberValue(_ value: PropertyValue) -> some View {
        if let num = value.number {
            let format: FloatingPointFormatStyle<Double> = .number
                .precision(.fractionLength(definition.decimals ?? 0))
                .locale(locale)
            Text(num, format: format)
                .monospacedDigit()
        }
    }

    /// Render a boolean — shown as a green checkmark when true, empty otherwise.
    @ViewBuilder
    private func booleanValue(_ value: PropertyValue) -> some View {
        if value.boolean == true {
            Image(systemName: "checkmark").foregroundStyle(.green)
        }
    }

    // MARK: - Date and datetime

    /// Render a date — parsed from the API's ISO 8601 string, formatted
    /// client-side against the env locale (mirrors webapp's
    /// `d(value.date, 'date')`).
    @ViewBuilder
    private func dateValue(_ value: PropertyValue) -> some View {
        if let iso = value.date, let date = ISO8601DateFormatter.parse(iso) {
            Text(
                date,
                format: Date.FormatStyle()
                    .year(.defaultDigits)
                    .month(.twoDigits)
                    .day(.twoDigits)
            )
        } else if let str = value.string {
            Text(str)
        }
    }

    /// Render a datetime — locale chooses 12h (EN) vs 24h (ET)
    /// automatically, matching webapp's i18n format options.
    @ViewBuilder
    private func datetimeValue(_ value: PropertyValue) -> some View {
        if let iso = value.datetime, let date = ISO8601DateFormatter.parse(iso) {
            Text(
                date,
                format: Date.FormatStyle()
                    .year(.defaultDigits)
                    .month(.twoDigits)
                    .day(.twoDigits)
                    .hour(.twoDigits(amPM: .abbreviated))
                    .minute(.twoDigits)
            )
        } else if let str = value.string {
            Text(str)
        }
    }

    // MARK: - Reference

    /// Reference chip (same pill as the edit sheet, sans ×) — navigates to
    /// the referenced entity via `onNavigate`. Carries the same entity-
    /// actions context menu as list and child-table rows.
    private func referenceButton(id: String, name: String?) -> some View {
        ReferenceChip(entityId: id, name: name) {
            onNavigate?(id)
        }
        .entityRowContextMenu(entityId: id) {
            onNavigate?(id)
        }
    }

    // MARK: - Auth provider

    /// Login-linked value (e.g. `entu_user`) — provider glyph + email in
    /// the shared auth pill, same capsule language as reference/file chips.
    private func providerValue(_ value: PropertyValue) -> some View {
        AuthChip(provider: value.provider, label: value.email ?? value.string ?? "")
    }

    /// Saved passkey value — masked "{device} {last4}" name in the auth
    /// pill with the passkey glyph.
    private func passkeyValue(_ value: PropertyValue) -> some View {
        AuthChip(provider: nil, fallbackIcon: "person.badge.key", label: value.string ?? "")
    }

    /// API key value — always server-masked to `***`, shown as a labeled
    /// key pill instead of the raw mask.
    private var apiKeyValue: some View {
        AuthChip(provider: nil, fallbackIcon: "key", label: String(localized: "apiKey", bundle: .currentLocalized))
    }

    // MARK: - File (QuickLook preview)

    /// File property — tap to download (signed URL via `GET /property/{id}`)
    /// and preview via QuickLook.
    @ViewBuilder
    private func fileValue(_ value: PropertyValue) -> some View {
        if let propId = value._id {
            FileChip(propertyId: propId, filename: value.filename, filesize: value.filesize) {
                Task { previewURL = await api.downloadFileForPreview(propertyId: propId, filename: value.filename) }
            }
        }
    }
}

// MARK: - Reference chip

/// Entity-tinted reference pill — circular thumbnail (letter tile until /
/// unless the entity has a photo) + name on the entity's identity color.
/// Shared between the detail view (tap navigates) and the edit sheet
/// (tap replaces, `onDelete` renders the trailing ×). The avatar also
/// seeds the color cache from the thumbnail, so the pill adopts the
/// cover's dominant color once loaded.
/// Chip metrics — compact pointer chips on macOS, taller touch chips on
/// iPad/iPhone. Shared by `ReferenceChip` and `FileChip`.
enum ValueChipMetrics {
    #if os(macOS)
    static let contentHeight: CGFloat = 16
    static let font = Font.caption
    static let deleteFont = Font.caption2
    #else
    static let contentHeight: CGFloat = 24
    static let font = Font.subheadline
    static let deleteFont = Font.caption
    #endif
}

struct ReferenceChip: View {
    let entityId: String
    let name: String?
    let action: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 6) {
                    EntityAvatar(name: name ?? "", entityId: entityId, hasPhoto: true, size: ValueChipMetrics.contentHeight)
                        .clipShape(Circle())

                    Text(verbatim: name ?? entityId)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "xmark")
                        .font(ValueChipMetrics.deleteFont.weight(.semibold))
                        .opacity(0.6)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("removeValue")
            }
        }
        .font(ValueChipMetrics.font)
        .fontWeight(.medium)
        .foregroundStyle(Color.entityTintText(for: entityId))
        // Pin to the avatar's height so the capsule inset stays uniform.
        .frame(height: ValueChipMetrics.contentHeight)
        .padding(2)
        .padding(.trailing, 6)
        .background(Color.entityTintFill(for: entityId), in: Capsule())
    }
}

// MARK: - File chip

/// Accent file chip — "name · size" pill per the design, with a circular
/// thumbnail for previewable files (images, PDFs), mirroring the webapp.
/// Shared between the detail view and the edit sheet (which passes
/// `onDelete` to get the trailing ×).
struct FileChip: View {
    @Environment(APIClient.self) private var api

    let propertyId: String
    let filename: String?
    let filesize: Int?
    let action: () -> Void
    var onDelete: (() -> Void)?

    @State private var thumbnail: Image?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 6) {
                    if let thumbnail {
                        thumbnail
                            .resizable()
                            .scaledToFill()
                            .frame(width: ValueChipMetrics.contentHeight, height: ValueChipMetrics.contentHeight)
                            .clipShape(Circle())
                    }

                    Group {
                        if let filesize {
                            Text(verbatim: "\(filename ?? propertyId) · \(filesize.fileSizeString)")
                        } else {
                            Text(verbatim: filename ?? propertyId)
                        }
                    }
                    .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "xmark")
                        .font(ValueChipMetrics.deleteFont.weight(.semibold))
                        .opacity(0.6)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("removeValue")
            }
        }
        .font(ValueChipMetrics.font)
        .fontWeight(.medium)
        .foregroundStyle(.tint)
        // Pin the content row to the thumbnail's height so the uniform
        // inset is truly uniform — the text's own line height would
        // otherwise stretch the capsule and unbalance top/bottom vs left.
        .frame(height: ValueChipMetrics.contentHeight)
        .padding(2)
        .padding(.leading, thumbnail == nil ? 6 : 0)
        .padding(.trailing, 6)
        .background(Color.accentColor.opacity(0.1), in: Capsule())
        .task(id: propertyId) {
            // Non-previewable files simply return no URL — chip stays text-only.
            guard let url = await api.propertyThumbnailURL(propertyId: propertyId, size: 50) else { return }
            thumbnail = await loadImage(from: url)
        }
    }
}

// MARK: - Auth chip

/// Gray pill for auth values — `entu_user` logins (provider glyph +
/// email) and `entu_passkey` passkeys (key glyph + masked device name).
/// Same capsule language as `FileChip`, in the neutral gray tier since
/// auth values aren't tappable. The edit sheet passes `onDelete` to get
/// the trailing ×.
struct AuthChip: View {
    /// `AuthProvider` raw value driving the glyph; nil (or an unknown
    /// provider) falls back to `fallbackIcon`.
    let provider: String?
    var fallbackIcon: String = "person.circle"
    let label: String
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                glyph
                Text(verbatim: label)
                    .lineLimit(1)
            }

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "xmark")
                        .font(ValueChipMetrics.deleteFont.weight(.semibold))
                        .opacity(0.6)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("removeValue")
            }
        }
        .font(ValueChipMetrics.font)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .frame(height: ValueChipMetrics.contentHeight)
        .padding(2)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .background(.fill.tertiary, in: Capsule())
    }

    /// Provider glyph in a fixed 12pt box so it centres against the text
    /// regardless of the asset's intrinsic size.
    private var glyph: some View {
        Group {
            if let icon = provider.flatMap({ AuthProvider(rawValue: $0) })?.icon {
                if icon.hasPrefix("sf:") {
                    Image(systemName: String(icon.dropFirst(3)))
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(icon).resizable().scaledToFit()
                }
            } else {
                Image(systemName: fallbackIcon)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 12, height: 12)
    }
}
