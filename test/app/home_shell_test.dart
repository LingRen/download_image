import 'package:download_image/app/breakpoints.dart';
import 'package:download_image/app/home_shell.dart';
import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/browser/browser_controller.dart';
import 'package:download_image/features/capture/capture_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_download.dart';

/// 记录自己被挂载的次数：用于断言跨断点时 BrowserPage 的子树没有被重建。
class _MountCounter extends StatefulWidget {
  const _MountCounter();

  static int mounts = 0;

  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    _MountCounter.mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  test('断点为 900dp', () {
    expect(kPanelBreakpoint, 900);
  });

  testWidgets('≥900dp：左右分栏，图片面板常驻', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(browserContentOverride: const SizedBox.expand()),
      ),
    );

    expect(find.byKey(const Key('panel-docked')), findsOneWidget);
    expect(find.byKey(const Key('capture-fab')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('<900dp：WebView 全屏 + 浮动按钮，点开为 BottomSheet', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(browserContentOverride: const SizedBox.expand()),
      ),
    );

    expect(find.byKey(const Key('panel-docked')), findsNothing);
    expect(find.byKey(const Key('capture-fab')), findsOneWidget);
    expect(find.textContaining('已捕获'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture-fab')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-panel')), findsOneWidget);
  });

  testWidgets('折叠按钮在宽屏下隐藏面板', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(browserContentOverride: const SizedBox.expand()),
      ),
    );

    await tester.tap(find.byKey(const Key('panel-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-panel')), findsNothing);
    expect(find.byKey(const Key('panel-expand')), findsOneWidget);
  });

  testWidgets('已捕获数量用 CaptureController 的真实数据', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final capture = CaptureController();
    capture.accept(
      CaptureBatch(
        pageUrl: 'https://a.com/p',
        assets: const [
          ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(
          browserContentOverride: const SizedBox.expand(),
          capture: capture,
        ),
      ),
    );

    expect(find.text('已捕获 1 张'), findsOneWidget);
  });

  testWidgets('页面加载时显示细进度条，随 BrowserController 进度更新', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final browser = BrowserController();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(
          browser: browser,
          browserContentOverride: const SizedBox.expand(),
        ),
      ),
    );

    expect(find.byKey(const Key('page-loading')), findsNothing);

    browser.updateLoading(loading: true, progress: 0.4);
    await tester.pump();
    final bar = find.byKey(const Key('page-loading'));
    expect(bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, 0.4);

    browser.updateLoading(loading: false, progress: 1);
    await tester.pump();
    expect(find.byKey(const Key('page-loading')), findsNothing);
  });

  testWidgets('跨越 900dp 断点不重建浏览器子树', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    _MountCounter.mounts = 0;
    await tester.pumpWidget(
      const MaterialApp(
        home: HomeShell(browserContentOverride: _MountCounter()),
      ),
    );

    expect(_MountCounter.mounts, 1);
    expect(find.byKey(const Key('panel-docked')), findsOneWidget);

    tester.view.physicalSize = const Size(420, 900);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('panel-docked')), findsNothing);
    expect(_MountCounter.mounts, 1, reason: '跨越 900dp 断点不应重建浏览器子树');
  });

  testWidgets('窄屏面板下载失败弹 SnackBar', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final executor = FakeDownloadExecutor(failingUrls: {'https://a.com/a.jpg'});
    final capture = CaptureController();
    capture.accept(
      CaptureBatch(
        pageUrl: 'https://a.com/p',
        assets: const [
          ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(
          capture: capture,
          download: fakeDownloadController(executor: executor),
          browserContentOverride: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('capture-fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('select-all')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('download-selected')));
    await tester.pumpAndSettle();

    expect(find.textContaining('镜像 403'), findsOneWidget);
  });

  testWidgets('宽屏预览页「下载这张」失败弹 SnackBar', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final executor = FakeDownloadExecutor(failingUrls: {'https://a.com/a.jpg'});
    final capture = CaptureController();
    capture.accept(
      CaptureBatch(
        pageUrl: 'https://a.com/p',
        assets: const [
          ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(
          capture: capture,
          download: fakeDownloadController(executor: executor),
          browserContentOverride: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('tile-preview-https://a.com/a.jpg')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preview-download')));
    await tester.pumpAndSettle();

    expect(find.textContaining('镜像 403'), findsOneWidget);
  });

  testWidgets('桌面端面板提供打包入口，打包完成后弹提示', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final capture = CaptureController();
    capture.accept(
      CaptureBatch(
        pageUrl: 'https://a.com/p',
        assets: const [
          ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(
          capture: capture,
          download: fakeDownloadController(archiver: FakeArchiver()),
          browserContentOverride: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('archive-menu')), findsOneWidget);

    await tester.tap(find.byKey(const Key('archive-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打包全部可见 (1)'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已打包 1 张到'), findsOneWidget);
  });
}
