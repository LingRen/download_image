import 'package:download_image/features/capture/srcset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSrcset', () {
    test('解析 w 描述符', () {
      final list = parseSrcset('/a.jpg 300w, /b.jpg 900w, /c.jpg 600w');
      expect(list.length, 3);
      expect(list[0].url, '/a.jpg');
      expect(list[0].width, 300);
      expect(list[1].width, 900);
    });

    test('解析 x 描述符，按 1x=1000 折算成可比数值', () {
      final list = parseSrcset('/a.jpg 1x, /b.jpg 2x');
      expect(list[0].width, 1000);
      expect(list[1].width, 2000);
    });

    test('没有描述符时宽度为 null', () {
      final list = parseSrcset('/only.jpg');
      expect(list.single.url, '/only.jpg');
      expect(list.single.width, isNull);
    });

    test('忽略多余空白与空段', () {
      final list = parseSrcset('  /a.jpg   300w ,, /b.jpg 600w  ');
      expect(list.map((e) => e.url).toList(), ['/a.jpg', '/b.jpg']);
    });
  });

  group('pickLargest', () {
    test('取宽度描述符最大的候选', () {
      final best = pickLargest('/a.jpg 300w, /b.jpg 900w, /c.jpg 600w');
      expect(best?.url, '/b.jpg');
      expect(best?.width, 900);
    });

    test('宽度相同时取先出现的', () {
      final best = pickLargest('/a.jpg 900w, /b.jpg 900w');
      expect(best?.url, '/a.jpg');
    });

    test('全部没有描述符时取第一个', () {
      final best = pickLargest('/a.jpg, /b.jpg');
      expect(best?.url, '/a.jpg');
      expect(best?.width, isNull);
    });

    test('空串或 null 返回 null', () {
      expect(pickLargest(''), isNull);
      expect(pickLargest(null), isNull);
    });
  });
}