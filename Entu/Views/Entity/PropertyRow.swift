// Renders a single property as a row: label on the left, value(s) on the right.
// Handles type-specific formatting: string, number, boolean, reference, date, datetime, file.
// File properties use QuickLook for native preview on all platforms.

import QuickLook
import SwiftUI

/// Single property row — label left, type-specific value(s) right.
struct PropertyRow: View {
    @Environment(APIClient.self) private var api

    let definition: PropertyDefinition
    let values: [PropertyValue]

    // Called when user taps a reference — navigates to that entity.
    var onNavigate: ((String) -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var previewURL: URL?

    // Filter to the user's preferred language for multilingual properties.
    private var displayValues: [PropertyValue] {
        let locale = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"

        let localized = values.filter { $0.language == locale }
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
                if sizeClass == .compact {
                    // iPhone: label above value, full width
                    VStack(alignment: .leading, spacing: 2) {
                        Text(definition.displayLabel(valueCount: displayValues.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

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
                            .foregroundStyle(.secondary)
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
    @ViewBuilder
    private func numberValue(_ value: PropertyValue) -> some View {
        if let num = value.number {
            if let decimals = definition.decimals {
                Text(num, format: .number.precision(.fractionLength(decimals))).monospacedDigit()
            } else {
                Text(num, format: .number).monospacedDigit()
            }
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

    /// Render a date value — the API formats this server-side so we just show the string.
    @ViewBuilder
    private func dateValue(_ value: PropertyValue) -> some View {
        if let str = value.string { Text(str) }
    }

    /// Render a datetime value — the API formats this server-side so we just show the string.
    @ViewBuilder
    private func datetimeValue(_ value: PropertyValue) -> some View {
        if let str = value.string { Text(str) }
    }

    // MARK: - Reference

    /// Tappable link that navigates to the referenced entity via `onNavigate`.
    private func referenceButton(id: String, name: String?) -> some View {
        Button { onNavigate?(id) } label: {
            Text(name ?? id).foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - File (QuickLook preview)

    // API response from GET /{db}/property/{propId} — contains a pre-signed S3 URL (60s expiry).
    private struct FilePropertyResponse: Codable {
        let url: String?
    }

    /// Render a file property as a tappable row that downloads and previews via QuickLook.
    @ViewBuilder
    private func fileValue(_ value: PropertyValue) -> some View {
        if let propId = value._id {
            Button {
                Task { await downloadAndPreview(propId: propId, filename: value.filename) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(value.filename ?? propId).foregroundStyle(.tint)

                    if let filesize = value.filesize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(filesize), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // Fetch signed URL from API, download to temp file, show in QuickLook.
    private func downloadAndPreview(propId: String, filename: String?) async {
        guard let response: FilePropertyResponse = try? await api.get("property/\(propId)"),
              let urlString = response.url,
              let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let _ = try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(filename ?? propId))
        else { return }

        previewURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename ?? propId)
    }
}
