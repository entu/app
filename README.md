# Entu App

Native iOS, iPadOS, and macOS client for [Entu](https://entu.app), built with SwiftUI.

## Requirements

- Xcode 26+
- iOS 26+ / iPadOS 26+ / macOS 26+

## Development

```bash
open Entu.xcodeproj
```

Build and run from Xcode. The app talks to the production API at `https://api.entu.app`; no local configuration needed.

## Sign-in

Supported providers: Apple, Google, e-mail magic link, Smart-ID, Mobile-ID, ID-card, passkey.

Auth returns via Universal Link on `https://entu.app/auth/app-callback` — the webapp's associated-domains file registers this app (Team ID `6B4F7S5J46`, bundle ID `app.entu`) as the handler.

## Related repos

- [`webapp`](https://github.com/entu/webapp) — Nuxt web client
- [`api`](https://github.com/entu/api) — Nitro API server
- [`www`](https://github.com/entu/www) — documentation site
