// Tracks reachability of any network interface using NWPathMonitor.
// Publishes `isOnline` on the main actor so SwiftUI views can react.
//
// NWPathMonitor invokes its update handler on a private background queue,
// so the closure is marked `@Sendable` and hops to MainActor before
// touching state — without that, Swift 6's runtime isolation check
// crashes when the closure tries to mutate @Observable state from off-main.

import Foundation
import Network

/// Observes overall network reachability and exposes `isOnline` to views.
@MainActor @Observable
final class NetworkMonitor {
    /// True while at least one network interface reports a satisfied path.
    var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.entu.network-monitor")

    init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
