#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: This isolated AppKit preview requires macOS." >&2
    exit 1
fi
preview_root="$(mktemp -d "${TMPDIR:-/tmp}/desktop-privacy-ui.XXXXXX")"
preview_app="$preview_root/Desktop Privacy UI Preview.app"
mkdir -p "$preview_app/Contents/MacOS"
touch "$preview_root/.isolated-ui-fixture"
cd "$project_root"
xcrun swiftc -O -framework AppKit \
    Sources/Core.swift Sources/AppConfiguration.swift Sources/AppUI.swift Tests/UI/main.swift \
    -o "$preview_app/Contents/MacOS/DesktopPrivacyUIPreview"
python3 - "$preview_app/Contents/Info.plist" <<'PY'
import pathlib
import plistlib
import re
import sys

source = pathlib.Path("scripts/build.py").read_text()
version = re.search(r'^VERSION = "([^"]+)"', source, re.M).group(1)
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleExecutable": "DesktopPrivacyUIPreview",
    "CFBundleIdentifier": "io.github.jayzengcodetrip.desktop-privacy.ui-preview",
    "CFBundleName": "Desktop Privacy UI Preview",
    "CFBundleDisplayName": "桌面文件隐身 · 隔离 UI 测试",
    "CFBundleShortVersionString": version + " UI 测试",
    "CFBundleVersion": "1",
    "CFBundlePackageType": "APPL",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
}))
PY
codesign --force --sign - "$preview_app"
printf 'Built isolated UI preview (not launched):\n%s\n' "$preview_app"
printf 'After opening, inspect synthetic state here:\n%s/observation.json\n' "$preview_root"
printf 'Quit the preview after restoring, then remove only this temporary directory:\n%s\n' "$preview_root"
