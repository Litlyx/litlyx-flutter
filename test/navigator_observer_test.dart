import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litlyx_flutter/litlyx_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_broker.dart';

void main() {
  late FakeBroker broker;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Litlyx.resetForTesting();
    broker = FakeBroker();
  });

  tearDown(Litlyx.resetForTesting);

  Future<void> initLitlyx({bool debug = false}) => Litlyx.init(
        'pid',
        trackLifecycle: false,
        debug: debug,
        client: broker.client,
      );

  Widget app(LitlyxNavigatorObserver observer, {String? initialRoute}) {
    return MaterialApp(
      navigatorObservers: <NavigatorObserver>[observer],
      initialRoute: initialRoute,
      routes: <String, WidgetBuilder>{
        '/': (_) => const Text('home'),
        '/detail': (_) => const Text('detail'),
        '/detail/chapters': (_) => const Text('chapters'),
      },
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await Litlyx.flush();
  }

  List<Object?> pages() =>
      broker.bodies('/visit').map((body) => body['page']).toList();

  List<Object?> referrers() =>
      broker.bodies('/visit').map((body) => body['referrer']).toList();

  NavigatorState navigator(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator));

  testWidgets('tracks pushed, replaced and revealed named routes', (
    tester,
  ) async {
    await initLitlyx();
    await tester.pumpWidget(app(LitlyxNavigatorObserver()));
    await settle(tester);
    expect(pages(), <String>['/']);

    unawaited(navigator(tester).pushNamed('/detail'));
    await settle(tester);
    unawaited(navigator(tester).pushReplacementNamed('/detail/chapters'));
    await settle(tester);
    navigator(tester).pop();
    await settle(tester);

    expect(pages(), <String>['/', '/detail', '/detail/chapters', '/']);
    expect(referrers(), <String>['self', '/', '/detail', '/detail/chapters']);
  });

  testWidgets('ignores unnamed routes, dialogs and sheets unless named', (
    tester,
  ) async {
    await initLitlyx();
    await tester.pumpWidget(app(LitlyxNavigatorObserver()));
    await settle(tester);
    final context = tester.element(find.text('home'));

    // Unnamed page: pushing and popping it doesn't count "/" again.
    unawaited(
      navigator(tester).push(
        MaterialPageRoute<void>(builder: (_) => const Text('unnamed')),
      ),
    );
    await settle(tester);
    navigator(tester).pop();
    await settle(tester);

    // Unnamed dialog and bottom sheet.
    unawaited(
      showDialog<void>(context: context, builder: (_) => const Text('dialog')),
    );
    await settle(tester);
    navigator(tester).pop();
    await settle(tester);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const Text('sheet'),
      ),
    );
    await settle(tester);
    navigator(tester).pop();
    await settle(tester);
    expect(pages(), <String>['/']);

    // A named dialog is a screen; dismissing it reveals "/" again.
    unawaited(
      showDialog<void>(
        context: context,
        routeSettings: const RouteSettings(name: '/rate-dialog'),
        builder: (_) => const Text('rate'),
      ),
    );
    await settle(tester);
    navigator(tester).pop();
    await settle(tester);
    expect(pages(), <String>['/', '/rate-dialog', '/']);
  });

  testWidgets('an initial route stack only reports the visible route', (
    tester,
  ) async {
    await initLitlyx();
    await tester.pumpWidget(
      app(LitlyxNavigatorObserver(), initialRoute: '/detail/chapters'),
    );
    await settle(tester);
    expect(pages(), <String>['/detail/chapters']);

    navigator(tester).pop();
    await settle(tester);
    expect(pages(), <String>['/detail/chapters', '/detail']);
  });

  testWidgets('screens seen before init are sent after init', (tester) async {
    await tester.pumpWidget(app(LitlyxNavigatorObserver()));
    await tester.pumpAndSettle();
    expect(broker.requests, isEmpty);

    await initLitlyx();
    await settle(tester);
    expect(pages(), <String>['/']);
  });

  testWidgets('debug mode logs each ignored route type once', (tester) async {
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      await initLitlyx(debug: true);
      await tester.pumpWidget(app(LitlyxNavigatorObserver()));
      await settle(tester);
      for (var i = 0; i < 2; i++) {
        unawaited(
          navigator(tester).push(
            MaterialPageRoute<void>(builder: (_) => const Text('unnamed')),
          ),
        );
        await settle(tester);
        navigator(tester).pop();
        await settle(tester);
      }
    } finally {
      debugPrint = originalDebugPrint;
    }
    final ignored = logs.where((line) => line.contains('ignores unnamed'));
    expect(ignored, hasLength(1));
    expect(ignored.single, contains('MaterialPageRoute<void>'));
  });
}
