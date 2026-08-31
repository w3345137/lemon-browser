#!/usr/bin/env bash

# Lemon 离线回归入口：逐个编译 Scripts/Test*.swift 与对应源码并运行。
# 用法：Scripts/run-tests.sh [测试名过滤，如 session]

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin_dir="$project_root/artifacts/tests/bin"
mkdir -p "$bin_dir"

filter="${1:-}"
failures=0

run_test() {
  local name="$1"; shift
  if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
    return
  fi
  local output="$bin_dir/$name"
  echo "==> $name"
  if ! xcrun swiftc -swift-version 5 "$@" -o "$output" 2>"$bin_dir/$name.build.log"; then
    echo "    编译失败，日志：$bin_dir/$name.build.log"
    failures=$((failures + 1))
    return
  fi
  if ! "$output"; then
    echo "    运行失败：$name"
    failures=$((failures + 1))
  fi
}

TAB_HARNESS=(
  "$project_root/Scripts/Fixtures/TestBrowserTabStubs.swift"
  "$project_root/Lemon/Browser/BrowserTab.swift"
  "$project_root/Lemon/Browser/WebKitFactory.swift"
  "$project_root/Lemon/Browser/MediaAudibilityBridge.swift"
)

# 真机级测试：真实 CredentialBridge / MediaAudibilityBridge / CredentialStore。
LIVE_HARNESS=(
  "$project_root/Scripts/Fixtures/TestBrowserTabLiveStubs.swift"
  "$project_root/Lemon/Browser/BrowserTab.swift"
  "$project_root/Lemon/Browser/WebKitFactory.swift"
  "$project_root/Lemon/Browser/MediaAudibilityBridge.swift"
  "$project_root/Lemon/Security/CredentialBridge.swift"
  "$project_root/Lemon/Security/CredentialStore.swift"
)

# 登录夹具服务器只在需要时拉起，结束后关闭。
login_server_pid=""
start_login_fixture() {
  if [ -z "$filter" ] || [[ "TestCredentialFillLive" == *"$filter"* ]]; then
    python3 "$project_root/Scripts/Fixtures/LoginFixtureServer.py" >/dev/null 2>&1 &
    login_server_pid=$!
    sleep 1
  fi
}
stop_login_fixture() {
  if [ -n "$login_server_pid" ]; then
    kill "$login_server_pid" 2>/dev/null || true
  fi
}
trap stop_login_fixture EXIT
start_login_fixture

run_test TestBrowserSession \
  "$project_root/Scripts/TestBrowserSession.swift" \
  "$project_root/Lemon/Data/BrowserSessionStore.swift"

run_test TestWebContentCrash \
  "$project_root/Scripts/TestWebContentCrash.swift" \
  "${TAB_HARNESS[@]}"

run_test TestMediaAudibility \
  "$project_root/Scripts/TestMediaAudibility.swift" \
  "${TAB_HARNESS[@]}"

run_test TestCredentialCapture \
  "$project_root/Scripts/TestCredentialCapture.swift" \
  "${TAB_HARNESS[@]}"

run_test TestCredentialFillLive \
  "$project_root/Scripts/TestCredentialFillLive.swift" \
  "${LIVE_HARNESS[@]}"

run_test TestMediaAudibilityLive \
  "$project_root/Scripts/TestMediaAudibilityLive.swift" \
  "${LIVE_HARNESS[@]}"

run_test TestBookmarkMoves \
  "$project_root/Scripts/TestBookmarkMoves.swift" \
  "$project_root/Lemon/Data/BookmarkStore.swift"

run_test TestBookmarkFolderLayout \
  "$project_root/Scripts/TestBookmarkFolderLayout.swift" \
  "$project_root/Lemon/Chrome/BookmarkFolderLayout.swift"

run_test TestOmniboxRanker \
  "$project_root/Scripts/TestOmniboxRanker.swift" \
  "$project_root/Lemon/Browser/OmniboxSuggestion.swift" \
  "$project_root/Lemon/Browser/OmniboxRanker.swift"

run_test TestContentBlockerRules \
  "$project_root/Scripts/TestContentBlockerRules.swift" \
  "$project_root/Lemon/Privacy/ContentBlockerRules.swift"

run_test TestCredentialSite \
  "$project_root/Scripts/TestCredentialSite.swift" \
  "$project_root/Lemon/Security/CredentialStore.swift"

run_test TestDownloadIntegrity \
  "$project_root/Scripts/TestDownloadIntegrity.swift" \
  "$project_root/Scripts/Fixtures/TestWebKitFactoryStubs.swift" \
  "$project_root/Lemon/Data/DownloadItem.swift" \
  "$project_root/Lemon/Data/DownloadStore.swift" \
  "$project_root/Lemon/Browser/WebKitFactory.swift" \
  "$project_root/Lemon/Browser/MediaAudibilityBridge.swift"

run_test TestDownloadStore \
  "$project_root/Scripts/TestDownloadStore.swift" \
  "$project_root/Scripts/Fixtures/TestWebKitFactoryStubs.swift" \
  "$project_root/Lemon/Data/DownloadItem.swift" \
  "$project_root/Lemon/Data/DownloadStore.swift" \
  "$project_root/Lemon/Browser/WebKitFactory.swift" \
  "$project_root/Lemon/Browser/MediaAudibilityBridge.swift"

run_test TestSessionCookieVault \
  "$project_root/Scripts/TestSessionCookieVault.swift" \
  "$project_root/Lemon/Security/SessionCookieVault.swift"

run_test TestSessionImportRequestPolicy \
  "$project_root/Scripts/TestSessionImportRequestPolicy.swift" \
  "$project_root/Lemon/Security/SessionImportRequestPolicy.swift"

run_test TestTabMemoryPressurePolicy \
  "$project_root/Scripts/TestTabMemoryPressurePolicy.swift" \
  "$project_root/Lemon/Browser/TabMemoryPressurePolicy.swift"

run_test TestTabCloseSelectionPolicy \
  "$project_root/Scripts/TestTabCloseSelectionPolicy.swift" \
  "$project_root/Lemon/Browser/TabCloseSelectionPolicy.swift"

run_test TestWebViewStack \
  "$project_root/Scripts/TestWebViewStack.swift" \
  "$project_root/Lemon/Browser/WebKitFactory.swift" \
  "$project_root/Lemon/Browser/MediaAudibilityBridge.swift"

if [ "$failures" -gt 0 ]; then
  echo "测试失败数：$failures"
  exit 1
fi
echo "全部测试通过"
