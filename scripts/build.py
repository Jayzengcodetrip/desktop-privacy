#!/usr/bin/env python3
"""Build a self-contained Universal 2 app and a distributable ZIP on macOS."""
from __future__ import annotations

import hashlib
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.0.1"
BUNDLE_ID = "io.github.jayzengcodetrip.desktop-privacy"
APP_NAME = "桌面文件隐身"
EXECUTABLE = "DesktopPrivacy"
ARCHITECTURES = ("arm64", "x86_64")
MINIMUM_MACOS = "13.0"


def run(*arguments: str) -> str:
    result = subprocess.run(arguments, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE)
    if result.stdout.strip():
        print(result.stdout.strip(), flush=True)
    return result.stdout.strip()


def main() -> None:
    if platform.system() != "Darwin":
        raise SystemExit("Building requires macOS and Apple's Command Line Tools or Xcode.")
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    sources = [str(path.relative_to(ROOT)) for path in sorted((ROOT / "Sources").glob("*.swift"))]
    with tempfile.TemporaryDirectory(prefix="desktop-privacy-build-") as temporary:
        build = Path(temporary)
        app = build / (APP_NAME + ".app")
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        binaries = []
        for architecture in ARCHITECTURES:
            print(f"Building {architecture}, minimum macOS {MINIMUM_MACOS}…", flush=True)
            binary = build / (EXECUTABLE + "-" + architecture)
            run("xcrun", "swiftc", "-O", "-target", f"{architecture}-apple-macos{MINIMUM_MACOS}",
                "-module-name", EXECUTABLE, "-framework", "AppKit",
                "-file-prefix-map", f"{ROOT}=.", "-debug-prefix-map", f"{ROOT}=.",
                *sources, "-o", str(binary))
            binaries.append(str(binary))
        executable = contents / "MacOS" / EXECUTABLE
        run("xcrun", "lipo", "-create", *binaries, "-output", str(executable))
        architectures = run("xcrun", "lipo", "-archs", str(executable)).split()
        if set(architectures) != set(ARCHITECTURES):
            raise RuntimeError("The universal executable does not contain both required architectures.")
        info = {
            "CFBundleExecutable": EXECUTABLE,
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleName": APP_NAME,
            "CFBundleDisplayName": APP_NAME,
            "CFBundleVersion": "2",
            "CFBundleShortVersionString": VERSION,
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": MINIMUM_MACOS,
            "LSUIElement": True,
            "NSHighResolutionCapable": True,
            "NSAppleEventsUsageDescription": "用于读取和恢复桌面图标的位置，保护名单外的图标布局；不读取文档内容。",
            "NSDesktopFolderUsageDescription": "用于隐藏你选中的桌面项目，并在原处恢复；首次名单为空。",
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copyfile(ROOT / "LICENSE", contents / "Resources" / "LICENSE")
        entitlements = build / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.automation.apple-events": True}))
        run("codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app))
        run("codesign", "--verify", "--strict", "--all-architectures", str(app))
        # Only explicitly created app files are included. No Finder metadata,
        # personal configuration, extended attributes, or build history is copied.
        final_app = dist / app.name
        if final_app.exists():
            shutil.rmtree(final_app)
        shutil.copytree(app, final_app)
        archive = dist / f"Desktop-Privacy-{VERSION}-universal.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
            for path in sorted(app.rglob("*")):
                if path.is_file():
                    package.write(path, str(path.relative_to(build)))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (dist / "SHA256SUMS.txt").write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
        print(f"Created dist/{app.name}")
        print(f"Created dist/{archive.name}")
        print(f"SHA-256: {digest}")


if __name__ == "__main__":
    main()
