#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_dir="$project_root/deliverables/app-store"
archive_path="$archive_dir/Lemon.xcarchive"

if [ "${LEMON_SKIP_TESTS:-0}" != "1" ]; then
  "$project_root/Scripts/run-tests.sh"
fi

mkdir -p "$archive_dir"
rm -rf "$archive_path"

xcodebuild \
  -project "$project_root/Lemon.xcodeproj" \
  -scheme Lemon \
  -configuration AppStore \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  archive

app_path="$archive_path/Products/Applications/Lemon.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
entitlements="$(/usr/bin/codesign -d --entitlements - "$app_path" 2>&1)"
grep -q 'com.apple.security.app-sandbox' <<<"$entitlements"
if grep -q 'com.apple.security.network.server' <<<"$entitlements"; then
  echo "App Store 归档不应包含网络服务端权限。" >&2
  exit 1
fi

if [ "${LEMON_UPLOAD_APP_STORE:-0}" = "1" ]; then
  xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportOptionsPlist "$project_root/Scripts/AppStoreExportOptions.plist" \
    -exportPath "$archive_dir/upload" \
    -allowProvisioningUpdates
else
  open "$archive_path"
  echo "归档已生成并打开。请先在 Organizer 中 Validate App；确认无误后再上传。"
fi

echo "App Store 归档：$archive_path"
