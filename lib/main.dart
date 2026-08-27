import 'package:flutter/material.dart';

void main() => runApp(const PrivetApp());

class PrivetApp extends StatelessWidget {
  const PrivetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Privet',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const Scaffold(body: Center(child: Text('Privet'))),
    );
  }
}
