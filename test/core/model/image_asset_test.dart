import 'package:download_image/core/model/image_asset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageAsset', () {
    test('尺寸齐全时 sizeKnown 为 true，minSide 取较小边', () {
      const asset = ImageAsset(url: 'https://a.com/x.jpg', width: 300, height: 200);
      expect(asset.sizeKnown, isTrue);
      expect(asset.minSide, 200);
    });

    test('缺少任一边时 sizeKnown 为 false，minSide 为 0', () {
      const asset = ImageAsset(url: 'https://a.com/x.jpg', width: 300);
      expect(asset.sizeKnown, isFalse);
      expect(asset.minSide, 0);
    });

    test('fromJson 解析 JS 侧字段，未知 source 回退为 img', () {
      final asset = ImageAsset.fromJson(const {
        'url': 'https://a.com/x.jpg',
        'w': 900,
        'h': 600,
        'size': 20480,
        'mime': 'image/jpeg',
        'source': 'cssBackground',
      });
      expect(asset.url, 'https://a.com/x.jpg');
      expect(asset.width, 900);
      expect(asset.height, 600);
      expect(asset.byteSize, 20480);
      expect(asset.mimeType, 'image/jpeg');
      expect(asset.source, ImageSource.cssBackground);

      final unknown = ImageAsset.fromJson(const {'url': 'https://a.com/y.png', 'source': 'whatever'});
      expect(unknown.source, ImageSource.img);
      expect(unknown.width, isNull);
    });

    test('toJson 与 fromJson 往返一致', () {
      const asset = ImageAsset(
        url: 'https://a.com/x.webp',
        width: 10,
        height: 20,
        byteSize: 3,
        mimeType: 'image/webp',
        source: ImageSource.srcset,
      );
      final again = ImageAsset.fromJson(asset.toJson());
      expect(again.url, asset.url);
      expect(again.width, asset.width);
      expect(again.height, asset.height);
      expect(again.byteSize, asset.byteSize);
      expect(again.mimeType, asset.mimeType);
      expect(again.source, asset.source);
    });

    test('merge 保留已知尺寸、较大尺寸与非空字段', () {
      const a = ImageAsset(url: 'https://a.com/x.jpg', width: 300, height: 300, source: ImageSource.img);
      const b = ImageAsset(url: 'https://a.com/x.jpg', width: 900, height: 900, mimeType: 'image/jpeg', source: ImageSource.dynamic);

      final merged = a.merge(b);
      expect(merged.width, 900);
      expect(merged.height, 900);
      expect(merged.mimeType, 'image/jpeg');
      expect(merged.source, ImageSource.img, reason: '保留先出现的来源，来源更具体的信息不丢');

      final mergedBack = b.merge(a);
      expect(mergedBack.width, 900);
      expect(mergedBack.mimeType, 'image/jpeg');
      expect(mergedBack.source, ImageSource.dynamic);
    });
  });
}