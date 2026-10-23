import 'package:flutter/material.dart';

void main() {
  runApp(const GoldenLouageApp());
}

class GoldenLouageApp extends StatelessWidget {
  const GoldenLouageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Golden louage',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Golden louage'),
          backgroundColor: Colors.amber,
        ),
        body: const Center(
          child: Text(
            'مرحبا بيك في Golden louage',
            textDirection: TextDirection.rtl,
            style: TextStyle(fontSize: 24),
          ),
        ),
      ),
    );
  }
}
