#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$project_root/build/DerivedData"
deliverables_path="$project_root/deliverables"
output_app="$deliverables_path/Lemon.app"
install_app="${LEMON_INSTALL_APP:-1}"

# 使用本机已有的 Apple Development 身份保持稳定 designated requirement。
# 临时 ad-hoc 签名会随每次构建改变 cdhash，导致 macOS Keychain 把新版 App
# 视为新的访问者并反复弹出授权提示。没有可用身份时才回退为 ad-hoc。
codesign_identity="${LEMON_CODESIGN_IDENTITY:-}"
if [ -z "$codesign_identity" ]; then
  codesign_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development:/{print $2; exit}')"
fi
if [ -z "$codesign_identity" ]; then
  codesign_identity="-"
fi

mkdir -p "$deliverables_path"

/usr/bin/swift "$project_root/Scripts/GenerateAppIcon.swift" \
  "$project_root/Lemon/Assets.xcassets/AppIcon.appiconset" \
  "$project_root/Scripts/lemon-logo-white-generated.png"

xcodebuild \
  -project "$project_root/Lemon.xcodeproj" \
  -scheme Lemon \
  -configuration Release \
  -sdk macosx \
  -derivedDataPath "$derived_data_path" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  build

if [ -e "$output_app" ]; then
  rm -rf "$output_app"
fi

ditto "$derived_data_path/Build/Products/Release/Lemon.app" "$output_app"
/usr/bin/ditto "$project_root/Tools/360SessionBridge" "$output_app/Contents/Resources/360SessionBridge"
/usr/bin/codesign --force --deep --sign "$codesign_identity" --options runtime \
  --entitlements "$project_root/Lemon/Lemon.entitlements" \
  "$output_app"
/usr/bin/codesign --verify --deep --strict "$output_app"

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 同一 Bundle ID 的旧副本会抢走 http/https 默认处理程序。
for stale_app in \
  "$derived_data_path/Build/Products/Debug/Lemon.app" \
  "$derived_data_path/Build/Products/Release/Lemon.app" \
  "$project_root/.build/DerivedData/Build/Products/Debug/Lemon.app" \
  "$project_root/.build/DerivedData/Build/Products/Release/Lemon.app" \
  "$project_root/build-debug/Build/Products/Debug/Lemon.app"
do
  if [ -d "$stale_app" ]; then
    "$lsregister" -u "$stale_app" >/dev/null 2>&1 || true
  fi
done

touch "$output_app"
"$lsregister" -f -R "$output_app"

if [ "$install_app" = "1" ]; then
  applications_app="/Applications/Lemon.app"
  if /usr/bin/ditto "$output_app" "$applications_app"; then
    /usr/bin/codesign --force --deep --sign "$codesign_identity" --options runtime \
      --entitlements "$project_root/Lemon/Lemon.entitlements" \
      "$applications_app" >/dev/null
    "$lsregister" -f -R "$applications_app"
    echo "已安装：$applications_app"
  else
    echo "未能写入 /Applications/Lemon.app，系统“默认网页浏览器”列表可能看不到 Lemon。"
  fi
else
  echo "已跳过安装到 /Applications（LEMON_INSTALL_APP=${install_app}）"
fi

echo "已生成：$output_app"
echo "签名身份：$codesign_identity"
