import 'package:download_image/features/browser/url_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeInputUrl', () {
    test('省略协议时补 https', () {
      expect(normalizeInputUrl('example.com/a'), 'https://example.com/a');
    });

    test('保留已有 http / https 协议', () {
      expect(normalizeInputUrl('http://example.com/a'), 'http://example.com/a');
      expect(normalizeInputUrl('https://example.com/a?b=1'), 'https://example.com/a?b=1');
    });

    test('去掉首尾空白', () {
      expect(normalizeInputUrl('   example.com  '), 'https://example.com');
    });

    test('非 http(s) 协议抛 FormatException', () {
      expect(() => normalizeInputUrl('ftp://example.com/a'), throwsFormatException);
      expect(() => normalizeInputUrl('javascript:alert(1)'), throwsFormatException);
    });

    test('空串或缺少主机名抛 FormatException', () {
      expect(() => normalizeInputUrl(''), throwsFormatException);
      expect(() => normalizeInputUrl('   '), throwsFormatException);
      expect(() => normalizeInputUrl('https:///a'), throwsFormatException);
    });
  });
}