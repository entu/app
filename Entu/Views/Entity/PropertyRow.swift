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

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var previewURL: URL?

    /// Stack label above value on iPhone — and at accessibility Dynamic
    /// Type sizes on every platform, where the trailing-aligned label
    /// column would clip the scaled-up label.
    private var isCompact: Bool {
        sizeClass == .compact || dynamicTypeSize.isAccessibilitySize
    }

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
            Group {
                if isCompact {
                    // iPhone: label above value, full width
                    VStack(alignment: .leading, spacing: 2) {
                        Text(definition.displayLabel(valueCount: displayValues.count))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(displayValues.enumerated()), id: \.offset) { _, value in
                                renderValue(value)
                            }
                        }
                    }
                } else {
                    // macOS/iPad: label left, value right
                    HStack(alignment: .top, spacing: 16) {
                        Text(definition.displayLabel(valueCount: displayValues.count))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 80, idealWidth: 140, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(displayValues.enumerated()), id: \.offset) { _, value in
                                renderValue(value)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            default: stringValue(value)
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

    /// Tappable link that navigates to the referenced entity via `onNavigate`.
    private func referenceButton(id: String, name: String?) -> some View {
        Button { onNavigate?(id) } label: {
            Text(name ?? id).foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Auth provider

    /// Login-linked value (e.g. `entu_user`) — provider icon + email/string.
    /// Mirrors the webapp's `property/value.vue` provider branch.
    private func providerValue(_ value: PropertyValue) -> some View {
        HStack(spacing: 8) {
            providerIcon(value.provider)
            Text(value.email ?? value.string ?? "")
                .textSelection(.enabled)
        }
    }

    /// Provider glyph — reuses `AuthProvider`'s icon (custom asset or `sf:`
    /// SF Symbol), falling back to a generic glyph for unknown providers.
    @ViewBuilder
    private func providerIcon(_ provider: String?) -> some View {
        if let icon = provider.flatMap({ AuthProvider(rawValue: $0) })?.icon {
            if icon.hasPrefix("sf:") {
                Image(systemName: String(icon.dropFirst(3)))
            } else {
                Image(icon).resizable().scaledToFit().frame(width: 16, height: 16)
            }
        } else {
            Image(systemName: "person.circle").foregroundStyle(.secondary)
        }
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

// MARK: - File chip

/// Accent file chip — "name · size" pill per the design, with a circular
/// thumbnail for previewable files (images, PDFs), mirroring the webapp.
private struct FileChip: View {
    @Environment(APIClient.self) private var api

    let propertyId: String
    let filename: String?
    let filesize: Int?
    let action: () -> Void

    @State private var thumbnail: Image?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let thumbnail {
                    thumbnail
                        .resizable()
                        .scaledToFill()
                        .frame(width: 16, height: 16)
                        .clipShape(Circle())
                }

                Group {
                    if let filesize {
                        Text(verbatim: "\(filename ?? propertyId) · \(filesize.fileSizeString)")
                    } else {
                        Text(verbatim: filename ?? propertyId)
                    }
                }
            }
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.tint)
            // Pin the content row to the thumbnail's height so the uniform
            // inset is truly uniform — the text's own line height would
            // otherwise stretch the capsule and unbalance top/bottom vs left.
            .frame(height: 16)
            .padding(2)
            .padding(.leading, thumbnail == nil ? 6 : 0)
            .padding(.trailing, 6)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .task(id: propertyId) {
            // Non-previewable files simply return no URL — chip stays text-only.
            guard let url = await api.propertyThumbnailURL(propertyId: propertyId, size: 50) else { return }
            thumbnail = await loadImage(from: url)
        }
    }
}
