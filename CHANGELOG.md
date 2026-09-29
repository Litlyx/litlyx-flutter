## 0.1.0

Initial release.

- `Litlyx.init` for the hosted Litlyx broker or a self-hosted one (`host`,
  `port`, `secure`), with `website`, `appName` and `appVersion`.
- Screen views with `Litlyx.screen` and `LitlyxNavigatorObserver` (named
  routes; unnamed routes, dialogs and sheets are ignored unless named).
- Custom events with `Litlyx.event` and flat `String`/`num` metadata, with
  debug checks against unsupported values and personal data.
- Session keep-alives that follow the app lifecycle, and an optional
  `sessionNonce` for more accurate sessions behind shared IP addresses.
- Offline queue persisted in shared preferences: in-order delivery,
  exponential backoff, 500 requests / 7 days maximum.
- Persisted opt-out and consent with `Litlyx.setEnabled`.
- Browser-like user agent for iOS, Android, desktop and web, so Litlyx's bot
  filter doesn't reject the requests.
- Pure Dart: no platform plugin code.
