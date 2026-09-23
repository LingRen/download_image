import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/image_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const defaults = FilterSettings();

  group('isFilteredOut', () {
    test('data: 与 blob: 协议一律过滤', () {
      expect(
        isFilteredOut(
          const ImageAsset(url: 'data:image/png;base64,AAAA'),
          defaults,
        ),
        isTrue,
      );
      expect(
        isFilteredOut(
          const ImageAsset(url: 'blob:https://a.com/abc'),
          defaults,
        ),
        isTrue,
      );
    });

    test('最小边小于阈值被过滤（含 1×1 像素）', () {
      expect(
        isFilteredOut(
          const ImageAsset(url: 'https://a.com/x.jpg', width: 1, height: 1),
          defaults,
        ),
        isTrue,
      );
      expect(
        isFilteredOut(
          const ImageAsset(url: 'https://a.com/x.jpg', width: 40, height: 1000),
          defaults,
        ),
        isTrue,
      );
      expect(
        isFilteredOut(
          const ImageAsset(url: 'https://a.com/x.jpg', width: 63, height: 900),
          defaults,
        ),
        isTrue,
      );
    });

    test('恰好等于阈值的保留', () {
      expect(
        isFilteredOut(
          const ImageAsset(url: 'https://a.com/x.jpg', width: 64, height: 64),
          defaults,
        ),
        isFalse,
      );
    });

    test('尺寸未知的不过滤（避免误杀）', () {
      const asset = ImageAsset(url: 'https://a.com/x.jpg');
      expect(asset.sizeKnown, isFalse);
      expect(isFilteredOut(asset, defaults), isFalse);
    });

    test('阈值可调', () {
      const asset = ImageAsset(
        url: 'https://a.com/x.jpg',
        width: 100,
        height: 100,
      );
      expect(isFilteredOut(asset, defaults), isFalse);
      expect(isFilteredOut(asset, const FilterSettings(minSide: 200)), isTrue);
    });

    test('格式不在启用集合里被过滤，jpeg 归一到 jpg', () {
      expect(
        isFilteredOut(const ImageAsset(url: 'https://a.com/x.png'), defaults),
        isFalse,
      );
      expect(
        isFilteredOut(
          const ImageAsset(url: 'https://a.com/x.png'),
          const FilterSettings(enabledFormats: {'jpg'}),
        ),
        isTrue,
      );
      expect(
        isFilteredOut(
          const ImageAsset(url: 'https://a.com/x.jpeg'),
          const FilterSettings(enabledFormats: {'jpg'}),
        ),
        isFalse,
      );
      expect(
        isFilteredOut(
          const ImageAsset(url: 'https://a.com/x', mimeType: 'image/webp'),
          const FilterSettings(enabledFormats: {'jpg'}),
        ),
        isTrue,
      );
    });

    test('格式无法判断时不过滤', () {
      expect(
        isFilteredOut(const ImageAsset(url: 'https://a.com/x'), defaults),
        isFalse,
      );
      expect(
        isFilteredOut(const ImageAsset(url: 'https://a.com/?id=3'), defaults),
        isFalse,
      );
    });

    test('来源不在启用集合里被过滤', () {
      const bg = ImageAsset(
        url: 'https://a.com/x.jpg',
        width: 300,
        height: 300,
        source: ImageSource.cssBackground,
      );
      expect(isFilteredOut(bg, defaults), isFalse);
      expect(
        isFilteredOut(
          bg,
          const FilterSettings(enabledSources: {ImageSource.img}),
        ),
        isTrue,
      );
    });
  });

  group('formatOf', () {
    test('从路径扩展名识别，带查询串也能识别', () {
      expect(
        formatOf(const ImageAsset(url: 'https://a.com/x.JPG?w=300')),
        'jpg',
      );
      expect(formatOf(const ImageAsset(url: 'https://a.com/x.webp')), 'webp');
      expect(formatOf(const ImageAsset(url: 'https://a.com/x.svg?v=2')), 'svg');
    });

    test('mimeType 优先于扩展名', () {
      expect(
        formatOf(
          const ImageAsset(url: 'https://a.com/x.png', mimeType: 'image/gif'),
        ),
        'gif',
      );
    });

    test('未知格式返回 null', () {
      expect(formatOf(const ImageAsset(url: 'https://a.com/x.avif')), isNull);
      expect(formatOf(const ImageAsset(url: 'https://a.com/x')), isNull);
    });
  });
}
