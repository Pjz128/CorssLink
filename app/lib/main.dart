import 'package:flutter/material.dart';
import 'screens/main_shell.dart';
import 'services/settings_service.dart';

void main() {
  runApp(const CrossLinkApp());
}

class CrossLinkApp extends StatefulWidget {
  const CrossLinkApp({super.key});

  @override
  State<CrossLinkApp> createState() => _CrossLinkAppState();
}

class _CrossLinkAppState extends State<CrossLinkApp> {
  @override
  void initState() {
    super.initState();
    SettingsService.open();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: SettingsService.themeNotifier,
      builder: (context, themeColor, _) {
        return MaterialApp(
          title: 'CrossLink',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: themeColor,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: const MainShell(),
        );
      },
    );
  }
}
