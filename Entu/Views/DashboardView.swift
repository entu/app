// Dashboard — shown as the default detail view when no menu item is selected.
// In an authenticated session, a centered column: logo + database name +
// organization header with an "updated" caption, then four stat tiles
// (entities, properties, files, AI tokens) with thin capacity bars. In a
// public-database session, the stats endpoint requires auth so this falls
// back to a "Viewing as guest" placeholder card.

import SwiftUI

/// Dashboard showing database usage statistics as stat tiles.
struct DashboardView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api

    @State private var stats: DatabaseStats?
    @State private var isLoading = false
    @State private var error: String?

    /// Two tiles per row at full width, one column when the pane is narrow.
    private let columns = [GridItem(.adaptive(minimum: 240), spacing: CardMetrics.gap)]

    var body: some View {
        VStack {
            if auth.isCurrentDatabasePublic {
                publicPlaceholder
            } else if isLoading {
                StatsPlaceholder()
            } else if let stats {
                content(stats)
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
        // Grayish window behind white/elevated cards, matching the design's
        // surface hierarchy (the macOS semantic window color renders white
        // in the split view's detail column, so the token is explicit).
        .background(Color("WindowBackground").ignoresSafeArea())
        // Reloads when the active database changes (id: parameter triggers re-run).
        .task(id: api.databaseId) { await loadStats() }
    }

    // MARK: - Content

    /// Header + tile grid, vertically centered while it fits, scrollable
    /// when the pane is shorter than the content.
    private func content(_ stats: DatabaseStats) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 26) {
                    header(stats)
                    tiles(stats)
                }
                .frame(maxWidth: 640)
                .padding(32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
            }
        }
    }

    private func header(_ stats: DatabaseStats) -> some View {
        HStack(spacing: 18) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: api.databaseId ?? "")
                    .font(.title.bold())

                if let organization = PropertyValue.localized(stats.organization) {
                    Text(verbatim: organization)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
    }

    private func tiles(_ stats: DatabaseStats) -> some View {
        LazyVGrid(columns: columns, spacing: CardMetrics.gap) {
            StatTile(label: "entities", stat: stats.entities, color: .accentColor)
            StatTile(label: "properties", stat: stats.properties, color: .indigo)
            StatTile(label: "files", stat: stats.files, color: .green, isBytes: true)

            if let tokens = stats.tokens {
                StatTile(label: "aiTokens", stat: tokens, color: .orange, isMonthly: true)
            }
        }
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

// MARK: - StatTile

/// One usage metric as a card: uppercase kicker, large current value,
/// deleted line, thin capacity bar, limit caption. Metrics without a limit
/// (properties) show a current-vs-deleted proportion bar captioned "no
/// limit"; the monthly AI-token metric notes its reset date instead of a
/// deleted line.
private struct StatTile: View {
    let label: LocalizedStringKey
    let stat: UsageStat
    let color: Color
    var isBytes: Bool = false
    var isMonthly: Bool = false

    private var usage: Int { stat.usage ?? 0 }
    private var deleted: Int { stat.deleted ?? 0 }
    private var limit: Int { stat.limit ?? 0 }
    private var total: Int { usage + deleted }

    /// Deleted items occupy the limit too, so the total is what overflows.
    private var isOverLimit: Bool {
        limit > 0 && total > limit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            Text(verbatim: format(usage))
                .font(.title2.bold())
                .monospacedDigit()
                .padding(.top, 3)

            Group {
                if isMonthly {
                    Text("statsTokensUsage \(Date.tokensResetDate)")
                } else {
                    Text("statsDeletedCount \(format(deleted))")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            UsageBar(
                color: barColor,
                usageFraction: usageFraction,
                deletedFraction: deletedFraction,
                limitMarkFraction: isOverLimit ? Double(limit) / Double(total) : nil
            )
            .padding(.top, 9)

            Group {
                if limit == 0 {
                    Text("statsNoLimit")
                } else if isMonthly {
                    Text("statsMonthlyLimit \(format(limit))")
                } else {
                    Text("statsOfLimit \(format(limit))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .cardSurface()
        // One VoiceOver element per tile — kicker and values read together.
        .accessibilityElement(children: .combine)
    }

    /// Warning tint as capacity runs out — orange from 90% of the limit
    /// (deleted items occupy it too, so the trigger is the total). Over the
    /// limit the red overlay marks the excess, webapp-style.
    private var barColor: Color {
        guard limit > 0, Double(total) / Double(limit) >= 0.9 else { return color }

        return .orange
    }

    /// Webapp parity: bar denominator is the limit, switching to the total
    /// when over it (the segments then fill the bar and the red overlay
    /// marks the excess). Without a limit the bar shows the
    /// current-vs-deleted proportion.
    private var usageFraction: Double {
        guard limit > 0 else {
            return total > 0 ? Double(usage) / Double(total) : 0
        }

        return Double(usage) / Double(isOverLimit ? total : limit)
    }

    private var deletedFraction: Double {
        guard limit > 0 else {
            return total > 0 ? Double(deleted) / Double(total) : 0
        }

        return Double(deleted) / Double(isOverLimit ? total : limit)
    }

    private func format(_ value: Int) -> String {
        isBytes ? value.fileSizeString : value.formatted()
    }
}

// MARK: - Date helpers

private extension Date {
    /// First day of the next month, e.g. "Aug 1" — when monthly AI token
    /// usage resets.
    static var tokensResetDate: String {
        let nextMonth = Calendar.current.dateInterval(of: .month, for: .now)?.end ?? .now

        return nextMonth.formatted(.dateTime.month(.abbreviated).day())
    }
}
