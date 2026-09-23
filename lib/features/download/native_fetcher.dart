import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/model/image_asset.dart';

/// 原生直下失败，交由上层标记该项失败。
class NativeFetchException implements Exception {
  NativeFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 降级通道：Dio 携带 WebView 导出的 Cookie 与 Referer 直接下载。
/// 用 download 直接落盘（不驻留内存），大图也安全。
class NativeFetcher {
  NativeFetcher({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<File> fetchToFile(
    ImageAsset asset,
    File destination, {
    String? referer,
    void Function(int received, int? total)? onProgress,
  }) async {
    try {
      final headers = <String, String>{'Accept': 'image/*,*/*;q=0.8'};
      if (referer != null && referer.isNotEmpty) headers['Referer'] = referer;
      final cookieHeader = await _cookieHeader(asset.url);
      if (cookieHeader.isNotEmpty) headers['Cookie'] = cookieHeader;

      await destination.parent.create(recursive: true);
      // validateStatus 已让 >=400 走 DioException，这里不需要再判 statusCode。
      await _dio.download(
        asset.url,
        destination.path,
        options: Options(
          headers: headers,
          followRedirects: true,
          validateStatus: (code) => code != null && code < 400,
        ),
        onReceiveProgress: onProgress,
      );
      return destination;
    } on DioException catch (e) {
      throw NativeFetchException(
        '原生直下失败：${e.response?.statusCode ?? e.type.name}',
      );
    }
  }

  Future<String> _cookieHeader(String url) async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      return cookies
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    } catch (_) {
      return '';
    }
  }
}
