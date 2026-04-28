// Dashboard — shown as the default detail view when no menu item is selected.
// Displays database usage statistics (entities, properties, files, requests)
// with progress bars and a detail popover on tap.

import SwiftUI

/// Dashboard showing database usage statistics with interactive progress bars.
struct DashboardView: View {
    @Environment(APIClient.self) private var api

    @State private var stats: DatabaseStats?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let stats {
                VStack(spacing: 8) {
                    Spacer()

                    StatsRow(label: "entities",
                             usage: stats.entities.usage ?? 0,
                             limit: stats.entities.limit ?? 0,
                             deleted: stats.entities.deleted ?? 0,
                             color: .cyan)

                    StatsRow(label: "properties",
                             usage: stats.properties.usage ?? 0,
                             limit: 0,
                             deleted: stats.properties.deleted ?? 0,
                             color: .yellow)

                    StatsRow(label: "files",
                             usage: stats.files.usage ?? 0,
                             limit: stats.files.limit ?? 0,
                             deleted: stats.files.deleted ?? 0,
                             color: .green,
                             isBytes: true)

                    StatsRow(label: "requests",
                             usage: stats.requests.usage ?? 0,
                             limit: stats.requests.limit ?? 0,
                             deleted: 0,
                             color: .gray)

                    Spacer()
                }
                .padding(32)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            } else if let error {
                Spacer()
                Text(error)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            } else {
                Spacer()
                Text("statistics")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reloads when the active database changes (id: parameter triggers re-run).
        .task(id: api.databaseId) { await loadStats() }
    }

    private func loadStats() async {
        isLoading = true
        error = nil
        do {
            stats = try await api.get("")
        } catch {
            self.error = error.localizedDescription
            stats = nil
        }
        isLoading = false
    }
}

// MARK: - StatsRow

// Single stat row matching the webapp's stats-bar component:
// Top: label (left) + "limit" text (right, red if over)
// Bar: usage (solid) + deleted (lighter), red limit marker if over
// Bottom: total value (left) + limit value (right)
// Popover: grid with color squares and values
private struct StatsRow: View {
    let label: LocalizedStringKey
    let usage: Int
    let limit: Int
    let deleted: Int
    let color: Color
    var isBytes: Bool = false

    @State private var showDetail = false
    @State private var isHovered = false

    private var total: Int { usage + deleted }
    private var overLimit: Int { limit > 0 ? max(total - limit, 0) : 0 }
    private var isOverLimit: Bool { overLimit > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top: label + "limit" text
            HStack {
                Text(label)
                Spacer()
                if limit > 0 {
                    Text("statsLimit")
                        .foregroundStyle(isOverLimit ? .red : .secondary)
                }
            }

            // Progress bar
            if isOverLimit {
                // Over limit: filled = limit portion, red track = over-limit
                ProgressView(value: Double(limit), total: Double(total))
                    .tint(color)
                    .background(
                        Capsule().fill(.red.opacity(0.3)).frame(height: 4)
                    )
            } else {
                ProgressView(value: Double(total), total: Double(max(limit, total, 1)))
                    .tint(color)
            }

            // Bottom: total + limit value
            HStack {
                Text(formatValue(total)).monospacedDigit()
                Spacer()
                if limit > 0 {
                    Text(formatValue(limit))
                        .foregroundStyle(isOverLimit ? .red : .secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption)
        }
        .padding(8)
        .background {
            if isHovered || showDetail {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover {
            isHovered = $0
            showDetail = $0
        }
        .onTapGesture { showDetail.toggle() }
        .popover(isPresented: $showDetail) {
            detailPopover
        }
        .padding(.vertical, 4)
    }

    private var detailPopover: some View {
        Grid(alignment: .leading, verticalSpacing: 8) {
            if usage > 0 {
                GridRow {
                    HStack(spacing: 6) {
                        Rectangle().fill(color).frame(width: 14, height: 14)
                        Text("statsCurrent")
                    }
                    Text(formatValue(usage))
                        .gridColumnAlignment(.trailing)
                        .monospacedDigit()
                }
            }

            if deleted > 0 {
                GridRow {
                    HStack(spacing: 6) {
                        Rectangle().fill(color.opacity(0.3)).frame(width: 14, height: 14)
                        Text("statsDeleted")
                    }
                    Text(formatValue(deleted)).monospacedDigit()
                }
            }

            if limit > 0 {
                GridRow {
                    HStack(spacing: 6) {
                        Rectangle().fill(color.opacity(0.1)).frame(width: 14, height: 14)
                        Text("statsLimit")
                    }
                    Text(formatValue(limit)).monospacedDigit()
                }
            }

            if overLimit > 0 {
                GridRow {
                    HStack(spacing: 6) {
                        Rectangle().fill(.red.opacity(0.2)).frame(width: 14, height: 14)
                        Text("statsOverLimit")
                            .fontWeight(.bold)
                            .foregroundStyle(.red)
                    }
                    Text(formatValue(overLimit))
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .fixedSize()
    }

    private func formatValue(_ value: Int) -> String {
        isBytes ? ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) : value.formatted()
    }
}
