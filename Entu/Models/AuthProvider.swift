// Available sign-in methods and their visual grouping on the auth screen.
// Each provider maps to an API endpoint (e.g. /auth/apple, /auth/smart-id).

import Foundation

/// Available sign-in methods (Apple, Google, email, Estonian ID).
enum AuthProvider: String, CaseIterable {
    case passkey
    case email = "e-mail"
    case apple
    case google
    case smartId = "smart-id"
    case mobileId = "mobile-id"
    case idCard = "id-card"

    var label: String {
        switch self {
        case .passkey: return String(localized: "passkey")
        case .email: return String(localized: "email")
        case .apple: return "Apple"
        case .google: return "Google"
        case .smartId: return "Smart-ID"
        case .mobileId: return "Mobile-ID"
        case .idCard: return String(localized: "idCard")
        }
    }

    // Icon name — "sf:" prefix means SF Symbols (Apple's built-in icons),
    // otherwise it's a custom image from the asset catalog.
    var icon: String {
        switch self {
        case .passkey: return "sf:person.badge.key.fill"
        case .email: return "auth-e-mail"
        case .apple: return "auth-apple"
        case .google: return "auth-google"
        case .smartId: return "auth-smart-id"
        case .mobileId: return "auth-mobile-id"
        case .idCard: return "auth-id-card"
        }
    }

    var group: AuthProviderGroup {
        switch self {
        case .passkey: return .passkey
        case .email, .apple, .google: return .main
        case .smartId, .mobileId, .idCard: return .estonian
        }
    }

    // Passkey requires associated domains + AASA file on the server.
    // Disabled until that infrastructure is set up.
    var isEnabled: Bool {
        self != .passkey
    }
}

/// Visual grouping of auth providers on the sign-in screen.
enum AuthProviderGroup: CaseIterable {
    case passkey
    case main
    case estonian
}
