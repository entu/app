// App-wide registry of per-window session snapshots. SwiftUI's native window
// tabs don't restore per-window values on relaunch — every restored tab is
// recreated from the default seed — so a per-scene snapshot would collapse to
// the single shared `ui.session` and all tabs would show the same thing.
//
// Instead, each open window registers its "where I left off" snapshot here
// keyed by its window id, and the ordered set is persisted. On relaunch each
// restored window (all carry the default `.restore` seed) claims the next
// saved snapshot in order, so every tab restores its own state. Ordering is
// best-effort — restored windows are assumed to appear in their saved
// sequence; a swap is possible but harmless.

import Foundation
#if os(macOS)
import AppKit
#endif

/// Ordered, persisted collection of per-window session snapshots (see file
/// overview). Injected app-wide from `EntuApp`.
@MainActor @Observable
final class WindowSessionStore {
    /// Live windows' snapshots in registration order — persisted as-is so
    /// restored windows can claim them in the same order next launch.
    @ObservationIgnored private var entries: [(id: UUID, snapshot: SessionState.SceneSnapshot)] = []

    /// Snapshots loaded at launch, handed one per restored window in order.
    /// Stale-epoch entries (a previous user's) are dropped at load.
    @ObservationIgnored private var restoreQueue: [SessionState.SceneSnapshot]

    /// True once the app is terminating — window teardown on quit must NOT
    /// remove entries (they are exactly what the next launch restores).
    @ObservationIgnored private var isTerminating = false

    private static let key = "ui.windowSessions"

    init() {
        restoreQueue = Self.load()

        // Only launch-restored windows claim a saved snapshot (explicit New
        // Window / New Tab carry their own non-`.restore` seed). Drop the
        // queue shortly after launch so a window opened much later — e.g.
        // Dock-reopen after all windows were closed — can't grab a stale
        // leftover from a launch that restored fewer windows than saved.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            restoreQueue.removeAll()
        }

        #if os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTerminating = true }
        }
        #endif
    }

    /// A restored (default-seed) window claims the next saved snapshot, or
    /// nil once the launch queue is exhausted.
    func claim() -> SessionState.SceneSnapshot? {
        restoreQueue.isEmpty ? nil : restoreQueue.removeFirst()
    }

    /// Record or refresh a window's snapshot and re-persist the ordered set.
    func update(_ windowId: UUID, snapshot: SessionState.SceneSnapshot) {
        if let index = entries.firstIndex(where: { $0.id == windowId }) {
            entries[index].snapshot = snapshot
        } else {
            entries.append((windowId, snapshot))
        }
        persist()
    }

    /// Drop a window's snapshot when the user closes the tab. A no-op during
    /// app termination, so quitting keeps every window for the next launch.
    func remove(_ windowId: UUID) {
        guard !isTerminating else { return }

        entries.removeAll { $0.id == windowId }
        persist()
    }

    private func persist() {
        UserDefaults.standard.setCodable(entries.map(\.snapshot), forKey: Self.key)
    }

    /// Saved snapshots from the previous run, minus any written under an
    /// older sign-out epoch — invalidation lives here, next to the data it
    /// guards (`MainView` still checks the runtime databaseId on claim).
    private static func load() -> [SessionState.SceneSnapshot] {
        let saved = UserDefaults.standard.codable([SessionState.SceneSnapshot].self, forKey: key) ?? []
        return saved.filter { $0.epoch == SessionState.currentEpoch }
    }

    /// Wipe the persisted set on sign-out — mirrors `SessionState.clearStored()`
    /// so a different user on the same device can't restore the previous
    /// user's windows.
    static func clearStored() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
