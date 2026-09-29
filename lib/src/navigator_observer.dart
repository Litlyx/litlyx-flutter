import 'package:flutter/widgets.dart';

import 'litlyx.dart';

/// Records named routes as Litlyx screen views.
///
/// Add one instance to your app's navigator and give your routes names
/// (named routes, `onGenerateRoute`, or `RouteSettings(name: '/detail')` on
/// a `MaterialPageRoute`):
///
/// ```dart
/// final litlyxObserver = LitlyxNavigatorObserver();
///
/// MaterialApp(
///   navigatorObservers: [litlyxObserver],
///   routes: {'/': (_) => const HomeScreen()},
/// );
/// ```
///
/// A screen view ([Litlyx.screen]) is sent with the route's
/// `RouteSettings.name`:
///
/// * when a route is pushed, or replaces another one, and becomes the
///   visible route;
/// * when a named route is popped, for the route it reveals.
///
/// Routes without a name are ignored, and so are popup routes such as
/// dialogs, menus and modal bottom sheets unless you name them. Dismissing
/// an ignored route doesn't count the screen below it again. With
/// `Litlyx.init(debug: true)`, the first ignored route of each type is
/// logged.
class LitlyxNavigatorObserver extends NavigatorObserver {
  /// Creates an observer. Keep a single instance per navigator (don't create
  /// it inside a `build` method).
  LitlyxNavigatorObserver();

  final Set<String> _reportedUnnamedTypes = <String>{};

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _track(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _track(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // An ignored route never replaced the screen below it.
    if (previousRoute == null || _screenName(route) == null) return;
    _track(previousRoute);
  }

  void _track(Route<dynamic> route) {
    final name = _screenName(route);
    if (name == null) {
      _reportUnnamed(route);
      return;
    }
    // Skip routes that are not visible, such as the lower entries of an
    // initial route stack or a route replaced below the top one.
    if (!route.isCurrent) return;
    Litlyx.screen(name);
  }

  static String? _screenName(Route<dynamic> route) {
    final name = route.settings.name;
    return (name == null || name.trim().isEmpty) ? null : name;
  }

  void _reportUnnamed(Route<dynamic> route) {
    if (!litlyxDebugLogging) return;
    final type = route.runtimeType.toString();
    if (!_reportedUnnamedTypes.add(type)) return;
    debugPrint('[litlyx] LitlyxNavigatorObserver ignores unnamed $type '
        "routes; give them RouteSettings(name: '/...') to track them as "
        'screens (logged once per route type)');
  }
}
