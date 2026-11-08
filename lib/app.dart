import 'package:flutter/material.dart';

import 'services/app_controller.dart';
import 'services/error_hooks.dart';
import 'ui/app_scope.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Starts the app: loads settings, conversations and models, then shows the interface.
class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  late final Future<AppController> _app = AppController.create().then((app) {
    // errors nobody caught are reported (only in the app itself: tests have their own handlers)
    installErrorHooks((error, stack) => app.reportProblem('crash', '$error', error: error, stack: stack));
    return app;
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<AppController>(
        future: _app,
        builder: (context, snapshot) {
          final app = snapshot.data;
          if (app != null) return ArceApp(app: app);
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'ARCE.AI',
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Center(
                child: snapshot.hasError
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('起動できませんでした\n\n${snapshot.error}', textAlign: TextAlign.center),
                      )
                    : const BrandMark(size: 64),
              ),
            ),
          );
        },
      );
}

class ArceApp extends StatefulWidget {
  const ArceApp({super.key, required this.app});
  final AppController app;

  @override
  State<ArceApp> createState() => _ArceAppState();
}

class _ArceAppState extends State<ArceApp> with WidgetsBindingObserver {
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // a notification is for the user who is not looking: the app is in front only while it is resumed
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => app.inForeground = state == AppLifecycleState.resumed;

  @override
  Widget build(BuildContext context) => ArceScope(
        app: app,
        child: ListenableBuilder(
          listenable: app.settings,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'ARCE.AI',
            themeMode: app.settings.value.theme,
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            // the text size of the settings comes on top of the system's own
            builder: (context, child) {
              final media = MediaQuery.of(context);
              final system = media.textScaler.scale(14) / 14;
              return MediaQuery(
                data: media.copyWith(textScaler: TextScaler.linear(system * app.settings.value.fontScale)),
                child: child!,
              );
            },
            home: const AppShell(),
          ),
        ),
      );
}

