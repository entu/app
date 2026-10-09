// Window anchor for the AuthenticationServices sheets — the OAuth browser
// (`ASWebAuthenticationSession`) and the passkey prompt
// (`ASAuthorizationController`). Both ask a context provider for a window;
// SwiftUI hands a service none, so this looks one up. It is the app's only
// `connectedScenes` lookup: these UIKit-anchored APIs need a real window
// and the SwiftUI environment equivalents cannot take over here (OAuth
// callbacks also arrive out of band through `AuthService.handleIncoming`).

import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Resolves the window the system auth sheets present over.
enum AuthPresentationAnchor {
    /// The key window of the frontmost scene, falling back to any window
    /// the app has. Called from the providers' nonisolated callbacks, which
    /// the system delivers on the main thread.
    nonisolated static func current() -> ASPresentationAnchor {
        MainActor.assumeIsolated { () -> ASPresentationAnchor in
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first

            if let window = scene?.keyWindow ?? scene?.windows.first {
                return window
            }

            if let scene {
                return UIWindow(windowScene: scene)
            }

            return ASPresentationAnchor()
            #endif
        }
    }
}
