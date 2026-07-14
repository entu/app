// Dashboard — shown as the default detail view when no menu item is selected.
// In an authenticated session, displays database usage statistics
// (entities, properties, files, AI tokens) with progress bars and a detail
// popover on tap. In a public-database session, the stats endpoint requires
// auth so this falls back to a "Viewing as guest" placeholder card.

import SwiftUI

/// Dashboard showing database usage statistics with interactive progress bars.
struct DashboardView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api

    @State private var stats: DatabaseStats?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack {
            if auth.isCurrentDatabasePublic {
                publicPlaceholder
            } else if isLoading {
                StatsPlaceholder()
            } else if let stats {
                VStack(spacing: 8) {
                    Spacer()

                    StatsRow(label: "entities",
                             usage: stats.entities.usage ?? 0,
                             limit: stats.entities.limit ?? 0,
                             deleted: stats.entities.deleted ?? 0,
                             color: .statEntities)

                    StatsRow(label: "properties",
                             usage: stats.properties.usage ?? 0,
                             limit: 0,
                             deleted: stats.properties.deleted ?? 0,
                             color: .statProperties)

                    StatsRow(label: "files",
                             usage: stats.files.usage ?? 0,
                             limit: stats.files.limit ?? 0,
                             deleted: stats.files.deleted ?? 0,
                             color: .statFiles,
                             isBytes: true)

                    if let tokens = stats.tokens {
                        StatsRow(label: "aiTokens",
                                 usage: tokens.usage ?? 0,
                                 limit: tokens.limit ?? 0,
                                 deleted: 0,
                                 color: .statTokens)
                    }

                    Spacer()
                }
                .padding(32)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("loadError", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                        .textSelection(.enabled)
                } actions: {
                    Button("retry") {
                        Task { await loadStats() }
                    }
                }
            } else {
                ContentUnavailableView("statistics", systemImage: "chart.bar.xaxis")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reloads when the active database changes (id: parameter triggers re-run).
        .task(id: api.databaseId) { await loadStats() }
    }

    /// Card shown instead of stats when the active database is being browsed
    /// as a guest — the stats endpoint requires auth so we have nothing to
    /// fetch, but we still want a friendly empty state.
    private var publicPlaceholder: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: api.databaseId ?? "")
            } icon: {
                Image(systemName: "globe")
            }
        } description: {
            Text("viewingAsGuest")
        }
    }

    private func loadStats() async {
        guard !auth.isCurrentDatabasePublic else { return }
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

/// Single stat row matching the webapp's stats-bar component:
/// top label + over-limit indicator; usage + deleted bar with a red
/// over-limit marker; total / limit values below; popover with a
/// colour-keyed value grid.
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

            // Progress bar — explicit capsule fill. `ProgressView` + `.tint`
            // renders all bars in a uniform system color in dark mode,
            // losing the per-stat hue.
            bar

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
        // One VoiceOver element per stat — label and values read together;
        // the button trait exposes the tap-for-details popover.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $showDetail) {
            detailPopover
                .appLanguageScoped()
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

    /// Filled fraction of the bar — the limit's share when over limit
    /// (the red track behind shows the excess), usage otherwise.
    private var fillFraction: Double {
        isOverLimit
            ? Double(limit) / Double(total)
            : Double(total) / Double(max(limit, total, 1))
    }

    /// Capsule track + fill. Stat colours come from the `Stat*` asset
    /// colorsets (webapp's `db-stats.vue` values, slightly darkened for
    /// dark mode) via the generated `Color.stat*` symbols.
    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isOverLimit ? Color.red.opacity(0.3) : color.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * fillFraction)
            }
        }
        .frame(height: 5)
    }

    private func formatValue(_ value: Int) -> String {
        isBytes ? value.fileSizeString : value.formatted()
    }
}
