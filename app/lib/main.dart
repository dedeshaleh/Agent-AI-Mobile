import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final controller = AppController()..init();
  runApp(AgentHqApp(controller: controller));
}

class AgentHqApp extends StatelessWidget {
  const AgentHqApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent HQ',
      debugShowCheckedModeBanner: false,
      theme: buildHqTheme(),
      home: HomeScreen(controller: controller),
    );
  }
}
