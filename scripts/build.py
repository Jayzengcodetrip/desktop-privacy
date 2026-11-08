#!/usr/bin/env python3
"""Build a Universal 2 app, a public DMG, and a local compatibility ZIP."""
from __future__ import annotations

import hashlib
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.1.1"
BUILD_NUMBER = "5"
BUNDLE_ID = "io.github.jayzengcodetrip.desktop-privacy"
APP_NAME = "桌面文件隐身"
EXECUTABLE = "DesktopPrivacy"
ARCHITECTURES = ("arm64", "x86_64")
MINIMUM_MACOS = "13.0"


def prune_old_packages(dist: Path) -> None:
    """Keep two release versions; inspect only recognized files directly in dist."""
    if dist.is_symlink():
        raise RuntimeError("Refusing to clean a symlinked distribution directory.")
    package_pattern = re.compile(r"Desktop-Privacy-(\d+\.\d+\.\d+)-(?:universal\.(?:zip|dmg)|source\.zip)")
    checksum_pattern = re.compile(r"SHA256SUMS-(\d+\.\d+\.\d+)\.txt")
    packages: list[tuple[Path, tuple[int, ...]]] = []
    for path in dist.iterdir():
        if path.is_symlink() or not path.is_file():
            continue
        match = package_pattern.fullmatch(path.name) or checksum_pattern.fullmatch(path.name)
        if match:
            packages.append((path, tuple(int(part) for part in match.group(1).split("."))))
    retained = set(sorted({version for _, version in packages}, reverse=True)[:2])
    for path, version in packages:
        if version not in retained:
            path.unlink()
            print(f"Removed older release package: {path.name}", flush=True)


def run(*arguments: str) -> str:
    result = subprocess.run(arguments, cwd=ROOT, check=True, text=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            timeout=120 if arguments[0] == "hdiutil" else None)
    if result.stdout.strip():
        print(result.stdout.strip(), flush=True)
    return result.stdout.strip()


def create_disk_image(app: Path, build: Path) -> Path:
    """Use only the freshly built app and explicit, non-personal install files."""
    payload = build / "dmg-contents"
    payload.mkdir()
    shutil.copytree(app, payload / app.name)
    (payload / "Applications").symlink_to("/Applications", target_is_directory=True)
    (payload / "安装说明.txt").write_text(
        f"桌面文件隐身 {VERSION}\n\n"
        "安装：将“桌面文件隐身.app”拖到旁边的 Applications（应用程序）文件夹。\n"
        "然后在“应用程序”中打开，安装完成后可推出本磁盘映像。\n"
        "升级：先恢复旧版隐藏的文件并退出旧版，再替换应用；不要删除原来的用户数据。\n\n"
        "使用：单击菜单栏眼睛隐藏当前桌面全部文件，再点恢复。\n"
        "只想隐藏部分文件时，右键眼睛进入“管理指定文件”。\n\n"
        "系统：macOS 13 或以上，支持 Apple Silicon 和 Intel。\n"
        "当前采用 ad-hoc 签名，未经过 Apple 公证。DMG 只是安装包装，并不改变签名状态。\n"
        "若系统阻止打开，请先核对下载来源；确认可信后，按系统设置中的\n"
        "“隐私与安全性 → 仍要打开”提示操作，无需关闭系统安全保护。\n"
        "Apple 官方说明：https://support.apple.com/zh-cn/102445\n\n"
        "项目：https://github.com/Jayzengcodetrip/desktop-privacy\n",
        encoding="utf-8",
    )
    image = build / f"Desktop-Privacy-{VERSION}-universal.dmg"
    # Leave the source volume's ownership setting untouched. In particular,
    # -srcowners off can attempt to remount the source volume and ask for admin access.
    run("hdiutil", "create", "-srcfolder", str(payload), "-volname", f"桌面文件隐身 {VERSION}",
        "-fs", "HFS+", "-format", "UDZO", "-nospotlight", "-srcowners", "any", "-anyowners", str(image))
    run("hdiutil", "verify", str(image))
    return image


def main() -> None:
    if platform.system() != "Darwin":
        raise SystemExit("Building requires macOS and Apple's Command Line Tools or Xcode.")
    dist = ROOT / "dist"
    if dist.is_symlink():
        raise RuntimeError("The distribution directory must not be a symlink.")
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
            "CFBundleVersion": BUILD_NUMBER,
            "CFBundleShortVersionString": VERSION,
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": MINIMUM_MACOS,
            "LSUIElement": True,
            "NSHighResolutionCapable": True,
            "NSAppleEventsUsageDescription": "用于读取和恢复桌面图标的位置，保护名单外的图标布局；不读取文档内容。",
            "NSDesktopFolderUsageDescription": "用于一键隐藏当前桌面全部文件或你指定的项目，并在原处恢复；不会移动文件或读取正文。",
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copyfile(ROOT / "LICENSE", contents / "Resources" / "LICENSE")
        entitlements = build / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.automation.apple-events": True}))
        run("codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app))
        run("codesign", "--verify", "--strict", "--all-architectures", str(app))
        # Build and verify the image before replacing any current release files.
        disk_image = create_disk_image(app, build)
        # Only explicitly created app files are included. No Finder metadata,
        # personal configuration, extended attributes, or build history is copied.
        final_app = dist / app.name
        if final_app.exists():
            shutil.rmtree(final_app)
        shutil.copytree(app, final_app)
        final_disk_image = dist / disk_image.name
        shutil.copyfile(disk_image, final_disk_image)
        archive = dist / f"Desktop-Privacy-{VERSION}-universal.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
            for path in sorted(app.rglob("*")):
                if path.is_file():
                    package.write(path, str(path.relative_to(build)))
        checksums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
                            for path in [final_disk_image, archive])
        (dist / "SHA256SUMS.txt").write_text(checksums, encoding="utf-8")
        (dist / f"SHA256SUMS-{VERSION}.txt").write_text(checksums, encoding="utf-8")
        prune_old_packages(dist)
        print(f"Created dist/{app.name}")
        print(f"Created dist/{final_disk_image.name} (public installer)")
        print(f"Created dist/{archive.name}")
        print(checksums, end="")


if __name__ == "__main__":
    main()
