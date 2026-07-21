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
    /// Live snapshots this session, keyed by window id.
    @ObservationIgnored private var live: [UUID: SessionState.SceneSnapshot] = [:]

    /// Registration order — persisted as a stable sequence so restored
    /// windows can be handed snapshots in the same order next launch.
    @ObservationIgnored private var order: [UUID] = []

    /// Snapshots loaded at launch, handed one per restored window in order.
    @ObservationIgnored private var restoreQueue: [SessionState.SceneSnapshot]

    /// True once the app is terminating — window teardown on quit must NOT
    /// remove entries (they are exactly what the next launch restores).
    @ObservationIgnored private var isTerminating = false

    private static let key = "ui.windowSessions"

    init() {
        restoreQueue = Self.load()

        // Only launch-restored windows should claim a saved snapshot; drop
        // the queue shortly after launch so a later New Window / New Tab
        // doesn't grab a leftover.
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
        if live[windowId] == nil {
            order.append(windowId)
        }
        live[windowId] = snapshot
        persist()
    }

    /// Drop a window's snapshot when the user closes the tab. A no-op during
    /// app termination, so quitting keeps every window for the next launch.
    func remove(_ windowId: UUID) {
        guard !isTerminating else { return }

        live[windowId] = nil
        order.removeAll { $0 == windowId }
        persist()
    }

    private func persist() {
        let ordered = order.compactMap { live[$0] }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private static func load() -> [SessionState.SceneSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SessionState.SceneSnapshot].self, from: data)
        else { return [] }
        return decoded
    }

    /// Wipe the persisted set on sign-out — mirrors `SessionState.clearStored()`
    /// so a different user on the same device can't restore the previous
    /// user's windows.
    static func clearStored() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
