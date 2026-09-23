import 'dart:convert';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BridgeMessage.parse', () {
    test('解析 batch（JSON 字符串）', () {
      final raw = jsonEncode({
        'type': 'batch',
        'pageUrl': 'https://a.com/p',
        'assets': [
          {
            'url': 'https://a.com/a.jpg',
            'w': 300,
            'h': 200,
            'size': 1024,
            'mime': 'image/jpeg',
            'source': 'img',
          },
          {'url': 'https://a.com/b.png', 'source': 'cssBackground'},
        ],
      });

      final message = BridgeMessage.parse(raw);
      expect(message, isA<CaptureBatch>());
      final batch = message! as CaptureBatch;
      expect(batch.pageUrl, 'https://a.com/p');
      expect(batch.assets.length, 2);
      expect(batch.assets.first.width, 300);
      expect(batch.assets.last.source, ImageSource.cssBackground);
      expect(batch.assets.last.sizeKnown, isFalse);
    });

    test('解析 batch（已解码的 Map，兼容 callHandler 直传对象）', () {
      final message = BridgeMessage.parse({
        'type': 'batch',
        'pageUrl': 'https://a.com/p',
        'assets': <Object?>[],
      });
      expect((message! as CaptureBatch).assets, isEmpty);
    });

    test('解析 scan', () {
      final message = BridgeMessage.parse(
        jsonEncode({
          'type': 'scan',
          'state': 'progress',
          'pageUrl': 'https://a.com/p',
          'screen': 12,
          'maxScreens': 40,
          'found': 30,
        }),
      );
      final scan = message! as ScanProgress;
      expect(scan.state, ScanState.progress);
      expect(scan.screen, 12);
      expect(scan.maxScreens, 40);
      expect(scan.found, 30);
    });

    test('解析 blob（正常分块与错误分块）', () {
      final ok =
          BridgeMessage.parse(
                jsonEncode({
                  'type': 'blob',
                  'id': 'dl-1',
                  'seq': 2,
                  'data': 'aGVsbG8=',
                  'last': false,
                  'mime': 'image/png',
                }),
              )!
              as BlobChunk;
      expect(ok.id, 'dl-1');
      expect(ok.seq, 2);
      expect(ok.data, 'aGVsbG8=');
      expect(ok.last, isFalse);
      expect(ok.mime, 'image/png');
      expect(ok.error, isNull);

      final failed =
          BridgeMessage.parse(
                jsonEncode({
                  'type': 'blob',
                  'id': 'dl-2',
                  'seq': 0,
                  'data': '',
                  'last': true,
                  'error': 'HTTP 403',
                }),
              )!
              as BlobChunk;
      expect(failed.error, 'HTTP 403');
    });

    test('未知类型、坏 JSON、非对象一律返回 null 而不抛异常', () {
      expect(BridgeMessage.parse(jsonEncode({'type': 'nope'})), isNull);
      expect(BridgeMessage.parse('{ this is not json'), isNull);
      expect(BridgeMessage.parse('42'), isNull);
      expect(BridgeMessage.parse(null), isNull);
      expect(BridgeMessage.parse(<Object?>[]), isNull);
    });

    test('scan 状态未知时回退为 done', () {
      final scan =
          BridgeMessage.parse(jsonEncode({'type': 'scan', 'state': 'weird'}))!
              as ScanProgress;
      expect(scan.state, ScanState.done);
      expect(scan.maxScreens, 40, reason: '缺省上限为 40 屏');
    });

    test('单条 asset 字段类型不对只跳过该张，不丢整批', () {
      final batch =
          BridgeMessage.parse(
                jsonEncode({
                  'type': 'batch',
                  'pageUrl': 'https://a.com/p',
                  'assets': [
                    {'url': 'https://a.com/good.jpg', 'w': 300, 'h': 200},
                    {'url': 'https://a.com/dirty.jpg', 'w': '300'},
                    {'w': 5},
                    'not-a-map',
                  ],
                }),
              )!
              as CaptureBatch;
      expect(batch.assets.length, 1);
      expect(batch.assets.single.url, 'https://a.com/good.jpg');
    });

    test('scan 的 state 非字符串时回退为 done 而不丢弃整条', () {
      final scan =
          BridgeMessage.parse(jsonEncode({'type': 'scan', 'state': 5}))!
              as ScanProgress;
      expect(scan.state, ScanState.done);
    });
  });

  test('kBlobChunkBytes 为 512KB', () {
    expect(kBlobChunkBytes, 512 * 1024);
  });
}
