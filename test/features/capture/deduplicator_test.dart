import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/deduplicator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('variantKey', () {
    test('去掉 w / h / width / height / size 查询参数', () {
      expect(variantKey('https://a.com/i.jpg?w=300'), variantKey('https://a.com/i.jpg?w=900'));
      expect(variantKey('https://a.com/i.jpg?width=300'), variantKey('https://a.com/i.jpg'));
      expect(variantKey('https://a.com/i.jpg?size=large'), variantKey('https://a.com/i.jpg'));
    });

    test('保留其他查询参数', () {
      expect(variantKey('https://a.com/i.jpg?token=abc'), isNot(variantKey('https://a.com/i.jpg?token=def')));
      expect(variantKey('https://a.com/i.jpg?w=300&token=abc'), 'https://a.com/i.jpg?token=abc');
    });

    test('编码参数与同名参数不同的 URL 不被误合并', () {
      expect(variantKey('https://a.com/i.jpg?a=b&c=d'), isNot(variantKey('https://a.com/i.jpg?a=b%26c%3Dd')));
      expect(variantKey('https://a.com/i.jpg?token=a&token=b'), isNot(variantKey('https://a.com/i.jpg?token=b')));
    });

    test('无 scheme 时原样返回，不做任何剥离', () {
      expect(variantKey('//a.com/i.jpg?w=300'), '//a.com/i.jpg?w=300');
      expect(variantKey('relative/path.jpg'), 'relative/path.jpg');
    });

    test('去掉 _300x300 / -300x300 路径后缀', () {
      expect(variantKey('https://a.com/pic_300x300.jpg'), 'https://a.com/pic.jpg');
      expect(variantKey('https://a.com/pic-600x600.jpg'), 'https://a.com/pic.jpg');
      expect(variantKey('https://a.com/pic.jpg'), 'https://a.com/pic.jpg');
    });

    test('不误伤正常路径', () {
      expect(variantKey('https://a.com/2024/01/a.jpg'), 'https://a.com/2024/01/a.jpg');
      expect(variantKey('https://a.com/v2-ab_300x300_extra.jpg'), 'https://a.com/v2-ab_300x300_extra.jpg');
    });
  });

  group('deduplicate', () {
    test('一级去重：URL 完全相同合并为一条，尺寸取更大者', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/i.jpg', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/i.jpg', width: 900, height: 900),
          ImageAsset(url: 'https://a.com/i.jpg', width: 300, height: 300),
        ],
        mergeVariants: false,
      );
      expect(result.length, 1);
      expect(result.single.width, 900);
    });

    test('二级去重：同路径尺寸变体只保留像素最大的一个', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/i.jpg?w=300', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/i.jpg?w=900', width: 900, height: 900),
          ImageAsset(url: 'https://a.com/i.jpg'),
        ],
        mergeVariants: true,
      );
      expect(result.length, 1);
      expect(result.single.url, 'https://a.com/i.jpg?w=900');
      expect(result.single.width, 900);
    });

    test('二级去重支持 _300x300 后缀', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/pic_300x300.jpg', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/pic_900x900.jpg', width: 900, height: 900),
        ],
        mergeVariants: true,
      );
      expect(result.length, 1);
      expect(result.single.url, 'https://a.com/pic_900x900.jpg');
    });

    test('尺寸都未知时保留先出现的那条', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/i.jpg?w=300'),
          ImageAsset(url: 'https://a.com/i.jpg?w=900'),
        ],
        mergeVariants: true,
      );
      expect(result.length, 1);
      expect(result.single.url, 'https://a.com/i.jpg?w=300');
    });

    test('关闭二级去重后尺寸变体都保留', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/i.jpg?w=300', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/i.jpg?w=900', width: 900, height: 900),
        ],
        mergeVariants: false,
      );
      expect(result.length, 2);
    });

    test('不同路径不被合并', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/b.jpg', width: 300, height: 300),
        ],
        mergeVariants: true,
      );
      expect(result.length, 2);
    });
  });
}