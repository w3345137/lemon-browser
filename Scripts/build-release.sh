#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${LEMON_SKIP_TESTS:-0}" != "1" ]; then
  "$project_root/Scripts/run-tests.sh"
fi

LEMON_INSTALL_APP="${LEMON_INSTALL_APP:-0}" \
  "$project_root/Scripts/build-app.sh"
"$project_root/Scripts/package-app.sh"
