import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/capture_controller.dart';
import 'package:download_image/features/gallery/image_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_download.dart';

void main() {
  CaptureController controllerWith(List<ImageAsset> assets) {
    final controller = CaptureController();
    for (final asset in assets) {
      controller.accept(CaptureBatch(pageUrl: 'https://a.com/p', assets: [asset]));
    }
    return controller;
  }

  Widget wrap(CaptureController capture, {double width = 420}) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 700,
          child: ImagePanel(
            capture: capture,
            download: fakeDownloadController(),
            onOpenPreview: (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('空列表显示扫描提示', (tester) async {
    await tester.pumpWidget(wrap(controllerWith(const [])));
    expect(find.byKey(const Key('panel-empty')), findsOneWidget);
  });

  testWidgets('渲染每个可见图片的图块', (tester) async {
    await tester.pumpWidget(wrap(controllerWith(const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
      ImageAsset(url: 'https://a.com/b.png', width: 300, height: 300),
    ])));
    await tester.pump();

    expect(find.byKey(const Key('tile-https://a.com/a.jpg')), findsOneWidget);
    expect(find.byKey(const Key('tile-https://a.com/b.png')), findsOneWidget);
  });

  testWidgets('点选图块切换选中态，操作栏显示已选数量', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
      ImageAsset(url: 'https://a.com/b.png', width: 300, height: 300),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();

    expect(find.text('已选 0 张'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tile-https://a.com/a.jpg')));
    await tester.pump();
    expect(capture.selectedUrls, {'https://a.com/a.jpg'});
    expect(find.text('已选 1 张'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(capture.selectedUrls.length, 2);
    expect(find.text('已选 2 张'), findsOneWidget);
  });

  testWidgets('拖动最小边滑块会即时过滤列表', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/small.jpg', width: 80, height: 80),
      ImageAsset(url: 'https://a.com/big.jpg', width: 400, height: 400),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();
    expect(find.byKey(const Key('tile-https://a.com/small.jpg')), findsOneWidget);

    capture.setMinSide(200);
    await tester.pump();
    expect(find.byKey(const Key('tile-https://a.com/small.jpg')), findsNothing);
    expect(find.byKey(const Key('tile-https://a.com/big.jpg')), findsOneWidget);
  });

  testWidgets('格式 chip 可切换', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
      ImageAsset(url: 'https://a.com/b.png', width: 300, height: 300),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();

    await tester.tap(find.byKey(const Key('format-chip-jpg')));
    await tester.pump();
    expect(capture.filter.enabledFormats, {'png', 'gif', 'webp', 'svg'});
    expect(find.byKey(const Key('tile-https://a.com/a.jpg')), findsNothing);
  });

  testWidgets('来源 chip 可切换', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300, source: ImageSource.img),
      ImageAsset(url: 'https://a.com/bg.jpg', width: 300, height: 300, source: ImageSource.cssBackground),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();

    await tester.ensureVisible(find.byKey(const Key('source-chip-img')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('source-chip-img')));
    await tester.pump();
    expect(find.byKey(const Key('tile-https://a.com/a.jpg')), findsNothing);
    expect(find.byKey(const Key('tile-https://a.com/bg.jpg')), findsOneWidget);
  });

  testWidgets('去重开关可切换', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/i.jpg?w=300', width: 300, height: 300),
      ImageAsset(url: 'https://a.com/i.jpg?w=900', width: 900, height: 900),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();
    expect(find.byKey(const Key('tile-https://a.com/i.jpg?w=900')), findsOneWidget);
    expect(find.byKey(const Key('tile-https://a.com/i.jpg?w=300')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('dedupe-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dedupe-switch')));
    await tester.pump();
    expect(capture.filter.mergeVariants, isFalse);
    expect(find.byKey(const Key('tile-https://a.com/i.jpg?w=300')), findsOneWidget);
  });

  testWidgets('尺寸未知的图块显示未知角标', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/unknown.jpg'),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();
    expect(find.byKey(const Key('tile-badge-unknown-https://a.com/unknown.jpg')), findsOneWidget);
  });
}