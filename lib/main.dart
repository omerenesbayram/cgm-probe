import 'package:flutter/material.dart';

import 'ui/probe_screen.dart';

void main() {
  runApp(const CgmProbeApp());
}

class CgmProbeApp extends StatelessWidget {
  const CgmProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CGM Probe',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const ProbeScreen(),
    );
  }
}
