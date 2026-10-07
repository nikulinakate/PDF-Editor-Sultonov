#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/validate.py
if command -v swift >/dev/null 2>&1; then
  swift test
else
  echo "Swift is unavailable here; Swift tests require a Mac with Xcode."
fi
if [[ "${1:-}" == "--ios" ]]; then
  python3 Scripts/test_ios.py
fi
