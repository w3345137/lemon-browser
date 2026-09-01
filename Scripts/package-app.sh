#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deliverables_path="$project_root/deliverables"
app_path="$deliverables_path/Lemon.app"
release_path="$deliverables_path/release"

if [ ! -d "$app_path" ]; then
  echo "缺少 $app_path，请先运行 Scripts/build-app.sh" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$app_path"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
archive_name="Lemon-${version}-build${build}-macOS-universal.zip"

rm -rf "$release_path"
mkdir -p "$release_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_path/$archive_name"

verification_dir="$(mktemp -d)"
trap 'rm -rf "$verification_dir"' EXIT
/usr/bin/ditto -x -k "$release_path/$archive_name" "$verification_dir"
/usr/bin/codesign --verify --deep --strict "$verification_dir/Lemon.app"

(
  cd "$release_path"
  /usr/bin/shasum -a 256 "$archive_name" > SHA256SUMS.txt
)

echo "已打包：$release_path/$archive_name"
echo "校验：$release_path/SHA256SUMS.txt"
