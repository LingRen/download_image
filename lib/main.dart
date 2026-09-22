import 'package:flutter/material.dart';

import 'features/browser/browser_page.dart';

void main() => runApp(const SpikeApp());

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spike',
      home: Scaffold(
        appBar: AppBar(title: const Text('平台可行性验证')),
        body: BrowserPage(initialUrl: Uri.parse('https://example.com')),
      ),
    );
  }
}