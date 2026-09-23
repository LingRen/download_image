import 'package:download_image/features/download/file_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildFileName', () {
    test('取路径最后一段，解码百分号转义', () {
      expect(buildFileName('https://a.com/p/img%20a.JPG'), 'img_a.JPG');
      expect(buildFileName('https://a.com/p/i.jpg?w=300'), 'i.jpg');
    });

    test('pathSegments 已解码，不能再解码一次', () {
      // 含 % 与非 ASCII 的文件名若被二次解码会抛 ArgumentError。
      expect(buildFileName('https://a.com/100%25.jpg'), '100_.jpg');
      expect(buildFileName('https://a.com/%E4%B8%AD%E6%96%87.jpg'), '__.jpg');
    });

    test('路径没有文件名时回退为 image，用 mime 补扩展名', () {
      expect(buildFileName('https://a.com/'), 'image');
      expect(buildFileName('https://a.com/p', mimeType: 'image/png'), 'p.png');
      expect(
        buildFileName('https://a.com/', mimeType: 'image/svg+xml'),
        'image.svg',
      );
    });

    test('没有扩展名时用 mime 补', () {
      expect(
        buildFileName('https://a.com/photo', mimeType: 'image/webp'),
        'photo.webp',
      );
      expect(
        buildFileName('https://a.com/photo', mimeType: 'image/jpeg'),
        'photo.jpg',
      );
    });

    test('危险字符被替换成下划线', () {
      expect(buildFileName('https://a.com/../../etc/passwd'), 'passwd');
      expect(buildFileName('https://a.com/a:b*c.jpg'), 'a_b_c.jpg');
    });

    test('mime 无法识别时不补扩展名', () {
      expect(
        buildFileName(
          'https://a.com/photo',
          mimeType: 'application/octet-stream',
        ),
        'photo',
      );
    });
  });

  group('uniqueFileName', () {
    test('第 0 个保持原名，之后追加序号', () {
      expect(uniqueFileName('i.jpg', 0), 'i.jpg');
      expect(uniqueFileName('i.jpg', 1), 'i (1).jpg');
      expect(uniqueFileName('i.jpg', 12), 'i (12).jpg');
    });

    test('无扩展名时直接追加', () {
      expect(uniqueFileName('image', 2), 'image (2)');
    });
  });

  group('buildArchiveName', () {
    test('按 yyyyMMdd-HHmmss 打时间戳', () {
      expect(
        buildArchiveName(DateTime(2026, 9, 23, 15, 30, 5)),
        'imgcat-20260923-153005.zip',
      );
    });

    test('个位数补零', () {
      expect(
        buildArchiveName(DateTime(2026, 1, 2, 3, 4, 5)),
        'imgcat-20260102-030405.zip',
      );
    });
  });
}
