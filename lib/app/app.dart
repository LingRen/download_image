import 'package:flutter/material.dart';

import 'home_shell.dart';

class ImageCaptureApp extends StatelessWidget {
  const ImageCaptureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '网页图片抓取下载器',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomeShell(),
    );
  }
}