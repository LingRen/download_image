import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/gallery/image_preview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(
    ImageAsset asset, {
    Future<void> Function(ImageAsset asset)? onDownload,
  }) {
    return MaterialApp(
      home: ImagePreviewPage(
        asset: asset,
        pageUrl: 'https://a.com/p',
        onDownload: onDownload ?? (_) async {},
      ),
    );
  }

  testWidgets('标题显示尺寸与格式', (tester) async {
    await tester.pumpWidget(
      wrap(const ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 200)),
    );
    await tester.pump();

    expect(find.textContaining('300×200'), findsOneWidget);
    expect(find.textContaining('JPG'), findsOneWidget);
  });

  testWidgets('尺寸未知时标题显示尺寸未知', (tester) async {
    await tester.pumpWidget(wrap(const ImageAsset(url: 'https://a.com/a.jpg')));
    await tester.pump();

    expect(find.textContaining('尺寸未知'), findsOneWidget);
  });

  testWidgets('点复制直链写入剪贴板并提示', (tester) async {
    String? copied;
    // SystemChannels.platform 还承载 SystemChrome 等方法，只对 Clipboard.setData 断言。
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(
      wrap(const ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 200)),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('preview-copy-link')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(copied, 'https://a.com/a.jpg');
    expect(find.text('直链已复制'), findsOneWidget);
  });

  testWidgets('点下载这张回调一次且参数为该 asset', (tester) async {
    final asset = const ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 200);
    final received = <ImageAsset>[];
    await tester.pumpWidget(wrap(asset, onDownload: (value) async => received.add(value)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('preview-download')));
    await tester.pump();

    expect(received, hasLength(1));
    expect(received.single.url, 'https://a.com/a.jpg');
  });
}