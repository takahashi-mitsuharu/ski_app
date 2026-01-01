import 'package:flutter/material.dart';
import 'game_scene.dart';

void main() {
  runApp(const SkiGameApp());
}

class SkiGameApp extends StatelessWidget {
  const SkiGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter 3D Ski Game',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, primarySwatch: Colors.blue),
      home: const SkiGamePage(),
    );
  }
}

class SkiGamePage extends StatefulWidget {
  const SkiGamePage({super.key});

  @override
  State<SkiGamePage> createState() => _SkiGamePageState();
}

class _SkiGamePageState extends State<SkiGamePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: GameScene());
  }
}
