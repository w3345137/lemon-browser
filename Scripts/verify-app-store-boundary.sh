#!/usr/bin/env bash
set -euo pipefail
app_path="${1:?请指定准确的 App Store Lemon.app 路径}"
binary="$app_path/Contents/MacOS/Lemon"
test -f "$binary"
task_strings="$(/usr/bin/strings "$binary")"
if rg -q 'SessionImportServer|SessionImportRequestPolicy|PasswordCSVImporter|WangfeiPlaybackBridge|__lemonWangfeiPlaybackInstalled|演示窗口不显示个人设置' <<<"$task_strings"; then
  echo "商店包仍含非商店功能或旧版功能隐藏占位文本。" >&2
  exit 1
fi
if [ -e "$app_path/Contents/Resources/360SessionBridge" ]; then
  echo "商店包不得含 360 迁移扩展。" >&2
  exit 1
fi
entitlements="$(/usr/bin/codesign -d --entitlements - "$app_path" 2>/dev/null)"
if ! rg -q 'com.apple.security.app-sandbox' <<<"$entitlements" ||
   rg -q 'com.apple.security.network.server|com.apple.security.get-task-allow' <<<"$entitlements"; then
  echo "商店权限边界不符合要求。" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app_path"
echo "app-store-binary-and-resource-boundary=passed"
