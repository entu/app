// Database picker — shown when the user has access to more than one
// database (any combination of authenticated tenants and saved public
// databases) and none is currently active. Each authenticated database is
// a card carrying its usage inline: capacity bars for entities and files
// plus a current/deleted/limit mini-table (stats fetched concurrently per
// database, like the webapp's select page). Selecting a card sets the
// active databaseId for all subsequent API calls.

import SwiftUI

/// Database picker — select a database or sign out. Used in the post-login auth flow.
struct DatabaseListView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api

    @State private var stats: [String: DatabaseStats] = [:]
    @State private var failedStats: Set<String> = []
    @State private var showingPublicEntry = false
    @State private var isProbingPublicDatabase = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header

            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .padding(.top, 44)
                .padding(.bottom, 14)

            VStack(spacing: 4) {
                Text("selectDatabaseTitle")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("selectDatabaseDescription")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)
            // MARK: - Database cards + sign out / browse public

            ScrollView {
                VStack(spacing: CardMetrics.gap) {
                    ForEach(auth.databases) { database in
                        DatabaseCard(
                            database: database,
                            stats: stats[database.id],
                            statsFailed: failedStats.contains(database.id)
                        ) {
                            auth.selectDatabase(database)
                        }
                    }

                    if !auth.publicDatabases.isEmpty {
                        Text("publicDatabasesSection")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)

                        ForEach(auth.publicDatabases, id: \.self) { id in
                            Button {
                                auth.selectPublicDatabase(id)
                            } label: {
                                DatabaseCardHeader(id: id, name: id) {
                                    Text("viewingAsGuest")
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 14)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .cardSurface()
                        }
                    }

                    // Scrolls with the cards, sitting right below the last one.
                    HStack {
                        Button { auth.logOut() } label: {
                            Text("signOut")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        BrowsePublicDatabaseButton(
                            isWorking: showingPublicEntry || isProbingPublicDatabase
                        ) {
                            showingPublicEntry = true
                        }
                    }
                    // 34 + the stack's 10pt gap = the canonical 44pt
                    // section gap under the database cards.
                    .padding(.top, 34)
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 32)
                // Canonical 44pt section gap below the title block.
                .padding(.top, 44)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollFadeMask()
        }
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        // Design-token window background behind the fixed header and the
        // Form's scroll area alike.
        .background(Color("WindowBackground").ignoresSafeArea())
        .publicDatabaseEntry(
            isPresented: $showingPublicEntry,
            isSubmitting: $isProbingPublicDatabase
        )
        .task(id: auth.databases) { loadAllStats() }
    }

    /// Fetches usage stats for every authenticated database concurrently
    /// (`GET /{db}`, one independent task each), updating each card as its
    /// result lands — mirrors the webapp's select page.
    private func loadAllStats() {
        for database in auth.databases where stats[database.id] == nil {
            let id = database.id

            Task {
                if let result: DatabaseStats = try? await api.get(id) {
                    stats[id] = result
                } else {
                    failedStats.insert(id)
                }
            }
        }
    }
}

// MARK: - DatabaseCard

/// One database card: header row (letter tile, name, user, chevron), then —
/// once stats arrive — entities/files capacity bars and a
/// current/deleted/limit mini-table.
private struct DatabaseCard: View {
    let database: Database
    let stats: DatabaseStats?
    let statsFailed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                DatabaseCardHeader(id: database.id, name: database.name) {
                    // Organization (the database's description) arrives with
                    // the stats; the signed-in user's name fills in until then.
                    if let organization = PropertyValue.localized(stats?.organization) {
                        Text(verbatim: organization)
                    } else if let userName = database.user?.name {
                        Text(verbatim: userName)
                    }
                }

                if let stats {
                    HStack(alignment: .top, spacing: 14) {
                        CapacityBar(label: "entities", stat: stats.entities, color: .accentColor)
                        CapacityBar(label: "files", stat: stats.files, color: .green, isBytes: true)
                    }

                    StatsMiniTable(stats: stats)
                } else if statsFailed {
                    Text("loadError")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cardSurface()
    }
}

/// Shared card header row — derived-color letter tile, name, subtitle,
/// trailing chevron. Used by both authenticated and public database rows.
private struct DatabaseCardHeader<Subtitle: View>: View {
    let id: String
    let name: String
    @ViewBuilder let subtitle: () -> Subtitle

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.derivedGradient(from: id))
                .frame(width: 32, height: 32)
                .overlay {
                    Text(verbatim: String(name.prefix(1)).uppercased())
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .fontWeight(.semibold)

                subtitle()
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - CapacityBar

/// Compact capacity bar: label + "current / limit" line over a 4pt track.
/// Deleted items still occupy the limit, so they render as a lighter
/// segment right after the solid current segment, and the ≥90% warning
/// tint triggers on current + deleted.
private struct CapacityBar: View {
    let label: LocalizedStringKey
    let stat: UsageStat
    let color: Color
    var isBytes: Bool = false

    private var usage: Int { stat.usage ?? 0 }
    private var deleted: Int { stat.deleted ?? 0 }
    private var limit: Int { stat.limit ?? 0 }
    private var total: Int { usage + deleted }

    private var isNearLimit: Bool {
        limit > 0 && Double(total) / Double(limit) >= 0.9
    }

    /// Deleted items occupy the limit too, so the total is what overflows.
    private var isOverLimit: Bool {
        limit > 0 && total > limit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .foregroundStyle(.tertiary)

                Spacer()

                // Total (current + deleted) — the limit and the breakdown
                // are in the mini-table below.
                Text(verbatim: format(total))
                    .fontWeight(isNearLimit ? .semibold : .regular)
                    .foregroundStyle(isNearLimit ? AnyShapeStyle(Color("WarningText")) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
            }
            .font(.caption)

            UsageBar(
                color: isNearLimit ? .orange : color,
                usageFraction: usageFraction,
                deletedFraction: deletedFraction,
                limitMarkFraction: isOverLimit ? Double(limit) / Double(total) : nil
            )
        }
    }

    /// Webapp parity: bar denominator is the limit, switching to the total
    /// when over it (the segments then fill the bar and the red overlay
    /// marks the excess).
    private var usageFraction: Double {
        guard limit > 0 else { return 0 }

        return Double(usage) / Double(isOverLimit ? total : limit)
    }

    private var deletedFraction: Double {
        guard limit > 0 else { return 0 }

        return Double(deleted) / Double(isOverLimit ? total : limit)
    }

    private func format(_ value: Int) -> String {
        isBytes ? value.fileSizeString : value.formatted()
    }
}

// MARK: - StatsMiniTable

/// Quiet-fill grid of all four usage metrics with Current / Deleted / Limit
/// columns. Missing values (no deleted bytes, no limit) render as an em dash.
private struct StatsMiniTable: View {
    let stats: DatabaseStats

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 2) {
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                Text("statsTableCurrent")
                Text("statsTableDeleted")
                Text("statsTableLimit")
            }
            .foregroundStyle(.quaternary)

            row(label: "entities", stat: stats.entities)
            row(label: "properties", stat: stats.properties)
            row(label: "files", stat: stats.files, isBytes: true)

            if let tokens = stats.tokens {
                row(label: "aiTokens", stat: tokens)
            }
        }
        .font(.caption)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(label: LocalizedStringKey, stat: UsageStat, isBytes: Bool = false) -> some View {
        let isNearLimit = (stat.limit ?? 0) > 0
            && Double((stat.usage ?? 0) + (stat.deleted ?? 0)) / Double(stat.limit ?? 1) >= 0.9

        return GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: format(stat.usage, isBytes: isBytes) ?? "0")
                .fontWeight(.semibold)
                .foregroundStyle(isNearLimit ? AnyShapeStyle(Color("WarningText")) : AnyShapeStyle(.primary))

            Text(verbatim: format(stat.deleted, isBytes: isBytes) ?? "—")
                .foregroundStyle(.tertiary)

            Text(verbatim: format(stat.limit, isBytes: isBytes, zeroAsMissing: true) ?? "—")
                .foregroundStyle(.tertiary)
        }
        .monospacedDigit()
    }

    /// Formats a metric value; `nil` means "render as missing". Zero bytes
    /// read better as missing, zero counts as an actual 0.
    private func format(_ value: Int?, isBytes: Bool, zeroAsMissing: Bool = false) -> String? {
        guard let value else { return nil }
        if value == 0 && (isBytes || zeroAsMissing) { return nil }

        return isBytes ? value.fileSizeString : value.formatted()
    }
}
