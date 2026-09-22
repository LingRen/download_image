import 'package:flutter/material.dart';

import 'core/bridge/js_channel.dart';
import 'features/browser/browser_controller.dart';
import 'features/browser/browser_page.dart';
import 'features/capture/capture_controller.dart';

/// Task 11 的临时接线（Task 17 会替换为正式应用壳）。
void main() => runApp(const SpikeApp());

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});

  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> {
  final BrowserController _browser = BrowserController();
  final CaptureController _capture = CaptureController();
  final JsChannelHolder _jsChannel = JsChannelHolder();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spike',
      home: Scaffold(
        appBar: AppBar(title: const Text('平台可行性验证')),
        body: BrowserPage(
          initialUrl: Uri.parse('https://example.com'),
          browser: _browser,
          capture: _capture,
          jsChannel: _jsChannel,
        ),
      ),
    );
  }
}