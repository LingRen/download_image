import 'dart:convert';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/capture_controller.dart';
import 'package:flutter_test/flutter_test.dart';

String _batch(
  List<Map<String, Object?>> assets, {
  String pageUrl = 'https://a.com/p',
}) {
  return jsonEncode({'type': 'batch', 'pageUrl': pageUrl, 'assets': assets});
}

void main() {
  test('batch 增量聚合，同 URL 合并为一条', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        _batch([
          {'url': 'https://a.com/a.jpg', 'w': 300, 'h': 300, 'source': 'img'},
        ]),
      )!,
    );
    expect(controller.rawAssets.length, 1);

    controller.accept(
      BridgeMessage.parse(
        _batch([
          {'url': 'https://a.com/a.jpg', 'w': 900, 'h': 900, 'source': 'img'},
          {'url': 'https://a.com/b.png', 'w': 100, 'h': 100, 'source': 'img'},
        ]),
      )!,
    );

    expect(controller.rawAssets.length, 2);
    expect(controller.rawAssets.first.width, 900);
    expect(controller.pageUrl, 'https://a.com/p');
    expect(controller.notifyCount, greaterThanOrEqualTo(2));
  });

  test('visibleAssets 应用过滤与去重', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        _batch([
          {'url': 'https://a.com/small.jpg', 'w': 10, 'h': 10, 'source': 'img'},
          {
            'url': 'https://a.com/big.jpg?w=300',
            'w': 300,
            'h': 300,
            'source': 'img',
          },
          {
            'url': 'https://a.com/big.jpg?w=900',
            'w': 900,
            'h': 900,
            'source': 'img',
          },
          {'url': 'data:image/png;base64,AAAA', 'source': 'img'},
        ]),
      )!,
    );

    expect(controller.rawAssets.length, 4);
    final visible = controller.visibleAssets;
    expect(visible.length, 1);
    expect(visible.single.url, 'https://a.com/big.jpg?w=900');
  });

  test('调整最小边阈值即时生效', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        _batch([
          {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
        ]),
      )!,
    );
    expect(controller.visibleAssets.length, 1);

    controller.setMinSide(200);
    expect(controller.filter.minSide, 200);
    expect(controller.visibleAssets, isEmpty);
  });

  test('切换格式 chip 即时生效', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        _batch([
          {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
          {'url': 'https://a.com/b.png', 'w': 100, 'h': 100, 'source': 'img'},
        ]),
      )!,
    );
    expect(controller.visibleAssets.length, 2);

    controller.toggleFormat('png');
    expect(controller.visibleAssets.map((e) => e.url), ['https://a.com/a.jpg']);
  });

  test('切换来源 chip 即时生效', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        _batch([
          {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
          {
            'url': 'https://a.com/bg.jpg',
            'w': 100,
            'h': 100,
            'source': 'cssBackground',
          },
        ]),
      )!,
    );

    controller.setSources({ImageSource.cssBackground});
    expect(controller.visibleAssets.map((e) => e.url), [
      'https://a.com/bg.jpg',
    ]);
  });

  test('关闭二级去重后尺寸变体都保留', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        _batch([
          {
            'url': 'https://a.com/big.jpg?w=300',
            'w': 300,
            'h': 300,
            'source': 'img',
          },
          {
            'url': 'https://a.com/big.jpg?w=900',
            'w': 900,
            'h': 900,
            'source': 'img',
          },
        ]),
      )!,
    );
    expect(controller.visibleAssets.length, 1);

    controller.setMergeVariants(false);
    expect(controller.visibleAssets.length, 2);
  });

  test('scan 进度写入 scan 字段，不是 running 状态', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        jsonEncode({
          'type': 'scan',
          'state': 'progress',
          'screen': 5,
          'maxScreens': 40,
          'found': 12,
        }),
      )!,
    );
    expect(controller.scan?.state, ScanState.progress);
    expect(controller.scan?.screen, 5);

    controller.accept(
      BridgeMessage.parse(
        jsonEncode({
          'type': 'scan',
          'state': 'limit',
          'screen': 40,
          'maxScreens': 40,
          'found': 90,
        }),
      )!,
    );
    expect(controller.scanReachedLimit, isTrue);

    controller.accept(
      BridgeMessage.parse(jsonEncode({'type': 'scan', 'state': 'start'}))!,
    );
    expect(controller.scanReachedLimit, isFalse, reason: '新一次扫描要清掉上次的上限提示');
  });

  test('选中态流转：单选、全选可见项、清空、切换页面时清空', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        _batch([
          {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
          {'url': 'https://a.com/b.jpg', 'w': 100, 'h': 100, 'source': 'img'},
        ]),
      )!,
    );

    controller.toggleSelection('https://a.com/a.jpg');
    expect(controller.selectedUrls, {'https://a.com/a.jpg'});
    controller.toggleSelection('https://a.com/a.jpg');
    expect(controller.selectedUrls, isEmpty);

    controller.selectAllVisible();
    expect(controller.selectedUrls.length, 2);
    controller.clearSelection();
    expect(controller.selectedUrls, isEmpty);

    controller.toggleSelection('https://a.com/a.jpg');
    controller.clear();
    expect(controller.rawAssets, isEmpty);
    expect(controller.selectedUrls, isEmpty);
    expect(controller.pageUrl, isNull);
  });

  test('selectedAssets 只返回还可见的选中项', () {
    final controller = CaptureController();
    controller.accept(
      BridgeMessage.parse(
        _batch([
          {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
        ]),
      )!,
    );
    controller.toggleSelection('https://a.com/a.jpg');
    expect(controller.selectedAssets.length, 1);

    controller.setMinSide(500);
    expect(controller.selectedAssets, isEmpty);
    expect(controller.selectedUrls.length, 1, reason: '选中态不因筛选变化被隐式清除');
  });
}
