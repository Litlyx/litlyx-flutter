import 'package:flutter/material.dart';
import 'package:litlyx_flutter/litlyx_flutter.dart';

/// Litlyx project id: `flutter run --dart-define=LITLYX_PROJECT_ID=...`.
const String projectId = String.fromEnvironment(
  'LITLYX_PROJECT_ID',
  defaultValue: 'YOUR_PROJECT_ID',
);

/// A single observer for the app's navigator: it records named routes as
/// screen views.
final LitlyxNavigatorObserver litlyxObserver = LitlyxNavigatorObserver();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Litlyx.init(
    projectId,
    website: 'com.example.litlyx_demo', // Your bundle id / application id.
    appName: 'LitlyxDemo',
    appVersion: '1.0.0',
    debug: true, // Prints every request and response.
  );
  runApp(const DemoApp());
}

/// The example app: two named routes tracked by [litlyxObserver].
class DemoApp extends StatelessWidget {
  /// Creates the app.
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Litlyx demo',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      navigatorObservers: <NavigatorObserver>[litlyxObserver],
      routes: <String, WidgetBuilder>{
        '/': (_) => const HomeScreen(),
        '/details': (_) => const DetailsScreen(),
      },
    );
  }
}

/// Home screen (`/`): events, navigation and the tracking switch.
class HomeScreen extends StatefulWidget {
  /// Creates the home screen.
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _likes = 0;
  bool _trackingEnabled = Litlyx.isEnabled;

  void _like() {
    setState(() => _likes++);
    // Metadata values must be String or num, and never personal data.
    Litlyx.event(
      'like_tapped',
      metadata: <String, Object>{'screen': 'home', 'total': _likes},
    );
  }

  Future<void> _setTracking(bool enabled) async {
    await Litlyx.setEnabled(enabled); // Persisted across restarts.
    setState(() => _trackingEnabled = Litlyx.isEnabled);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Litlyx demo')),
      body: ListView(
        children: <Widget>[
          SwitchListTile(
            title: const Text('Share anonymous usage statistics'),
            value: _trackingEnabled,
            onChanged: _setTracking,
          ),
          ListTile(
            leading: const Icon(Icons.thumb_up_outlined),
            title: Text('Like ($_likes)'),
            subtitle: const Text('Sends the "like_tapped" event'),
            onTap: _like,
          ),
          ListTile(
            leading: const Icon(Icons.arrow_forward),
            title: const Text('Open details'),
            subtitle: const Text('Named route, recorded as /details'),
            onTap: () => Navigator.pushNamed(context, '/details'),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Show a dialog'),
            subtitle: const Text('Unnamed dialogs are not recorded'),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                content: const Text('Name a route to track it as a screen.'),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.cloud_upload_outlined),
            title: Text('Send queued requests now'),
            onTap: Litlyx.flush,
          ),
        ],
      ),
    );
  }
}

/// Details screen (`/details`).
class DetailsScreen extends StatelessWidget {
  /// Creates the details screen.
  const DetailsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Details')),
      body: Center(
        child: FilledButton(
          onPressed: () {
            Litlyx.event(
              'purchase',
              metadata: <String, Object>{'plan': 'yearly', 'price': 29.99},
            );
            Navigator.pop(context);
          },
          child: const Text('Buy the yearly plan'),
        ),
      ),
    );
  }
}
