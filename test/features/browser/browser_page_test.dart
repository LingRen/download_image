import 'package:download_image/features/browser/browser_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pageOfUrl = {
    'https://a.com/1.png': 'https://a.com/p',
    'https://b.com/2.png': 'https://b.com/p',
  };

  test('urlsOfPage 只挑出属于指定页的 URL', () {
    expect(
      urlsOfPage(pageOfUrl, 'https://b.com/p'),
      {'https://b.com/2.png'},
      reason: 'A 页的资产不会因为 B→C 选清空而被删',
    );
  });

  test('页面不在映射里时返回空集', () {
    expect(
      urlsOfPage(pageOfUrl, 'https://c.com/p'),
      isEmpty,
      reason: '上一个页面 0 张时不弹对话框、也不清空列表',
    );
  });
}