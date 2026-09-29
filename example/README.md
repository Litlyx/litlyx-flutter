# litlyx_flutter example

A two-screen app that tracks screen views with `LitlyxNavigatorObserver`,
sends a custom event with metadata and toggles tracking at runtime.

```sh
# Generate the platform folders once (--empty keeps lib/main.dart and adds no test):
flutter create --empty --platforms=ios,android .
flutter run --dart-define=LITLYX_PROJECT_ID=<your project id>
```

`debug: true` is on, so every request and response is printed in the console.
