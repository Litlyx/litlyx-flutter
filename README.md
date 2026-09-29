# litlyx_flutter

Cookie-free, privacy-friendly analytics for Flutter apps with
[Litlyx](https://litlyx.com), the open-source analytics platform.

Track screen views, custom events and sessions with a pure-Dart SDK. There is
no native code, no cookies and no device identifier.

- **Screen views** from named routes with `LitlyxNavigatorObserver`, or manual
  `Litlyx.screen`.
- **Custom events** with flat metadata.
- **Sessions** kept alive while the app is in the foreground, so session
  duration works in the dashboard.
- **Offline queue** stored on the device and retried with exponential backoff.
- **Opt-out and consent** switch, persisted across restarts.
- **Self-hosted Litlyx** support.
- **All platforms**: iOS, Android, macOS, Windows, Linux and web. It isn't a
  plugin, so there is no native setup.
- **Safe to call anywhere**: nothing throws and nothing blocks. Calls made
  before `init` are buffered.

## Install

```sh
flutter pub add litlyx_flutter
```

Requires Flutter 3.24 or later (Dart 3.5).

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:litlyx_flutter/litlyx_flutter.dart';

final litlyxObserver = LitlyxNavigatorObserver();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Litlyx.init(
    'YOUR_PROJECT_ID',           // From the Litlyx dashboard.
    website: 'com.example.app',  // Your bundle id / application id.
    appName: 'MyApp',
    appVersion: '1.2.3',
  );
  runApp(
    MaterialApp(
      navigatorObservers: [litlyxObserver],
      routes: {
        '/': (_) => const HomeScreen(),
        '/settings': (_) => const SettingsScreen(),
      },
    ),
  );
}
```

The project id is the one shown in the Litlyx dashboard. It is the same value
as `data-project` in the web snippet. You don't have to await `init`: calls
made before it completes are buffered (up to 100) and sent afterwards.

## Screen views

`LitlyxNavigatorObserver` records a screen view with the route's
`RouteSettings.name` in two cases:

- a named route is pushed, or replaces another route, and becomes visible;
- a named route is popped, and the route it reveals is recorded.

Routes without a name are ignored. Dialogs, menus and bottom sheets are
ignored too, unless you name them. Dismissing an ignored route doesn't record
the screen below it again.

```dart
Navigator.pushNamed(context, '/manga/detail');

// Routes that aren't named routes need RouteSettings:
Navigator.push(
  context,
  MaterialPageRoute(
    settings: const RouteSettings(name: '/manga/detail'),
    builder: (_) => const MangaDetailScreen(),
  ),
);

// Named dialogs are tracked too:
showDialog(
  context: context,
  routeSettings: const RouteSettings(name: '/rate-app'),
  builder: (_) => const RateAppDialog(),
);
```

Use route patterns (`/manga/detail`) rather than ids (`/manga/12345`) to keep
the dashboard readable. Query strings are removed. Routers built on Navigator
pages, such as go_router, work when their pages have a name. Otherwise, call
`Litlyx.screen` yourself:

```dart
Litlyx.screen('/settings');
Litlyx.screen('/paywall', referrer: 'push', utm: {'campaign': 'spring_sale'});
```

The referrer defaults to the previous screen, or `self` for the first one.
UTM keys may omit the `utm_` prefix.

## Events

```dart
Litlyx.event('chapter_read');
Litlyx.event('purchase', metadata: {'plan': 'yearly', 'price': 29.99});
```

Metadata rules:

- It is a flat map whose values are `String` or `num`.
- Up to 20 keys are kept, and strings are cut to 200 characters.
- In debug builds, an assertion fails on unsupported values and on keys that
  look like personal data. In release builds, unsupported values are dropped.

`event` is fire-and-forget: the event is queued and sent in the background.

## Consent and opt-out

```dart
// Consent first: track nothing until the user agrees.
await Litlyx.init('YOUR_PROJECT_ID', enabled: false);
// ...then, from your consent dialog:
await Litlyx.setEnabled(true);

// An "anonymous statistics" switch in your settings:
SwitchListTile(
  title: const Text('Share anonymous usage statistics'),
  value: Litlyx.isEnabled,
  onChanged: (value) async {
    await Litlyx.setEnabled(value);
    setState(() {});
  },
);
```

The choice is saved on the device and wins over the `enabled` argument at the
next launch. Disabling tracking clears the buffer and the offline queue and
stops every request.

## Sessions

With `trackLifecycle: true` (the default), the SDK sends a keep-alive when the
app comes to the foreground and then one per minute of foreground time.
Litlyx uses these keep-alives to compute session duration. The queue is also
flushed when the app is resumed or paused. Launches in the background, such as
notification handling or background fetch, don't open a session.

### `sessionNonce`

Litlyx has no cookies and no device ids. The server identifies a session with
a daily hash of the website, the IP address and the user agent. Two users with
the same phone model and app version on the same network share an IP address
and a user agent, for example behind a mobile carrier NAT or on office Wi-Fi,
so they are merged into one session.

`sessionNonce: true` adds a random ` s/1a2b3c` token to the user agent. The
token is renewed at every cold start and after 30 minutes in the background.
When a new session starts this way, the current screen is recorded again.

- **Pro:** session counts, durations and flows stay accurate on shared
  networks.
- **Con:** each new session counts as a new unique visitor, so someone who
  opens the app three times a day counts as three visitors.

Leave it off (the default) if unique-visitor counts matter more than session
accuracy.

## Offline queue and delivery

- `/visit` and `/event` requests are stored in shared preferences and sent in
  order.
- When a request fails, delivery stops and is retried with backoff: after 5 s
  at first, doubling up to 10 min, with ±20% jitter. Resuming the app, pausing
  it and calling `Litlyx.flush()` retry immediately.
- `4xx` responses (except `408` and `429`) are dropped. `5xx`, `408` and `429`
  responses, timeouts (10 s) and network errors are retried.
- The queue keeps at most `maxQueueSize` requests (500 by default, the oldest
  are dropped first), for at most 7 days.
- Keep-alives are best-effort and are never queued.
- Litlyx timestamps a request when it receives it, so events sent later from
  the queue appear at delivery time. Delivery is at-least-once: a request that
  timed out may be counted twice.

## `website` and the domain whitelist

Each request carries a `website` field. On the web this is the domain; in an
app, use your bundle id (`website: 'com.example.app'`, default
`flutter-app`). Litlyx matches it against the project's **domain whitelist**,
if one is configured. Add the value to the whitelist, otherwise Litlyx
answers `400` and the events are dropped. The IP blacklist and bot blocking
also answer `400`.

## Self-hosting

```dart
await Litlyx.init(
  'YOUR_PROJECT_ID',
  host: 'analytics.example.com', // Host name only, no scheme.
  port: 443,
  secure: true,                  // false = http.
);
```

Plain `http` needs an App Transport Security exception on iOS and cleartext
traffic enabled on Android.

## Privacy

- **Stored on the device:** no cookies, no advertising or vendor ids, no
  persistent user id. The SDK only keeps the offline queue and the tracking
  choice.
- **Sent to Litlyx:** the screen or event, your metadata and a browser-like
  user agent (device type, OS and app version). Litlyx also sees the IP
  address, which it uses for the session hash and to look up the country.
- **Never send personal data** such as names, e-mails, phone numbers, user
  ids or tokens in metadata or screen names.
- **App Store privacy label:** declare *Product Interaction*, used for
  *Analytics*, **not linked** to the user's identity and **not used for
  tracking**. Litlyx derives the country from the IP address, so you may also
  declare *Coarse Location* for *Analytics*, not linked.
- **Google Play data safety:** declare *App activity → App interactions*,
  collected for *Analytics* and not shared.

## Platform notes

- **Android:** release builds need
  `<uses-permission android:name="android.permission.INTERNET" />` in
  `android/app/src/main/AndroidManifest.xml`. Flutter adds it only to the
  debug and profile manifests.
- **macOS:** sandboxed apps need the `com.apple.security.network.client`
  entitlement.
- **Web:** browsers don't allow changing the `User-Agent` header, so the SDK
  sends the browser's own user agent.

## How the user agent is built

Litlyx derives device statistics and sessions from the user agent, and bot
blocking rejects user agents that look like HTTP libraries. The SDK therefore
sends a browser-like string with your app appended:

```text
Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MyApp/1.2.3
Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 MyApp/1.2.3
```

- iPads and Android tablets are detected from the screen size.
- `appName` keeps only `[A-Za-z0-9]`. Don't use words that bot blocking may
  match, such as `bot`, `crawl`, `spider` or `http`.
- The Android version is a best-effort value read from the kernel release,
  because Dart doesn't expose the Android version without a plugin. It may be
  missing or lag behind the installed version.

## Debugging

`Litlyx.init(..., debug: true)` prints every request, response and dropped
call:

```text
[litlyx] -> POST https://broker.litlyx.com/event {"pid":"…","name":"purchase",…}
[litlyx] <- 200 /event in 84 ms
```

In your own tests, either don't call `Litlyx.init` (calls stay in the
in-memory buffer and are never sent) or pass a mock HTTP client:
`Litlyx.init('test', client: MockClient(...))`. `Litlyx.resetForTesting()`
restores a clean state between tests.

## License

MIT. See [LICENSE](LICENSE).
