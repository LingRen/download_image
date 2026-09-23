#!/usr/bin/env bash
# 把 `flutter build macos --release` 的产物打成可分发的 dmg。
#
# 用法（先跑构建，再跑本脚本）：
#   flutter build macos --release
#   bash scripts/package_macos.sh
#
# 产物：dist/download_image-<version>-macos.dmg
#
# 注意：dmg 未做代码签名与公证，他人首次打开会被 Gatekeeper 拦截，
# 需要右键「打开」，或执行 `xattr -dr com.apple.quarantine <app>`。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="download_image"
APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
  echo "找不到 $APP_PATH，请先执行：flutter build macos --release" >&2
  exit 1
fi

# 从 pubspec.yaml 的 `version:` 行解析出版本号，去掉 build 号（1.0.0+1 -> 1.0.0）。
VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9][^+[:space:]]*\).*/\1/p' pubspec.yaml | head -n 1)"
if [ -z "$VERSION" ]; then
  echo "无法从 pubspec.yaml 解析版本号" >&2
  exit 1
fi

mkdir -p dist
DMG_PATH="dist/${APP_NAME}-${VERSION}-macos.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

echo "已生成：$DMG_PATH"
