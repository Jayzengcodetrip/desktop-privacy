#!/usr/bin/env python3
"""Scan public sources and release bundles without storing a private denylist.

The default scan covers this repository, excluding version-control metadata and
Python bytecode caches. Pass an .app directory and/or .zip to inspect releases.
Private terms may be supplied as a JSON string array in a separate local file or
an environment variable. Matches are reported by index, never by their contents.
"""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import sys
import unicodedata
import zipfile

PROJECT_ROOT = Path(__file__).resolve().parents[1]
IGNORED_DIRECTORIES = {".git", "__pycache__"}
LEGACY_RESOURCE_STEM = "Fixed" + "Manifest"
RUNTIME_RECORD_NAMES = {
    LEGACY_RESOURCE_STEM.lower() + ".json",
    "manifest.json",
    "recovery.json",
    "last-restored.json",
    "operation.lock",
    ".ds_store",
}
HOME_PATH = re.compile(r"/(?:Users|home)/[^/\s\x00\"'<>]+")
HOST_TEMP_PATH = re.compile(r"/(?:private/)?var/folders/[A-Za-z0-9_-]+/")
BUNDLED_LEGACY_LOAD = re.compile(
    r"forResource\s*:\s*[\"']" + re.escape(LEGACY_RESOURCE_STEM) + r"[\"']"
)
MAX_ARCHIVE_DEPTH = 3
MAX_ENTRY_BYTES = 256 * 1024 * 1024


def read_terms(path: str | None, environment_name: str | None) -> list[str]:
    terms: list[str] = []
    if path:
        contents = Path(path).read_text(encoding="utf-8")
        try:
            values = json.loads(contents)
        except json.JSONDecodeError:
            values = contents.splitlines()
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
            raise ValueError("Private terms file must contain a JSON string array or one term per line.")
        terms.extend(values)
    if environment_name:
        raw = os.environ.get(environment_name)
        if raw is None:
            raise ValueError("The requested private-terms environment variable is not set.")
        values = json.loads(raw)
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
            raise ValueError("Private terms environment variable must contain a JSON string array.")
        terms.extend(values)
    return list(dict.fromkeys(value for value in terms if value))


def configured_bundle_identifier() -> str | None:
    source = PROJECT_ROOT / "Sources" / "AppConfiguration.swift"
    if not source.is_file():
        return None
    match = re.search(r'static\s+let\s+bundleIdentifier\s*=\s*"([^"\n]+)"', source.read_text(encoding="utf-8"))
    return match.group(1) if match else None


class Checker:
    def __init__(self, terms: list[str], expected_bundle_id: str | None) -> None:
        self.terms = terms
        self.expected_bundle_id = expected_bundle_id
        self.files_checked = 0
        self.plists_checked = 0
        self.problems: list[tuple[str, str]] = []
        self.encoded_terms: list[tuple[int, set[bytes]]] = []
        for number, term in enumerate(terms, 1):
            variants = {unicodedata.normalize(form, term) for form in ("NFC", "NFD")}
            encodings = {value.encode(encoding) for value in variants for encoding in ("utf-8", "utf-16-le", "utf-16-be")}
            self.encoded_terms.append((number, encodings))

    def fail(self, location: str, reason: str) -> None:
        # File and ZIP member names can themselves be private. Redact labels as
        # well as suppressing payload excerpts in all diagnostics.
        for number, term in sorted(enumerate(self.terms, 1), key=lambda item: len(item[1]), reverse=True):
            for form in ("NFC", "NFD"):
                location = location.replace(unicodedata.normalize(form, term), f"[private-term-{number}]")
        location = HOME_PATH.sub("[private-home]", location)
        location = HOST_TEMP_PATH.sub("[host-temporary-path]/", location)
        finding = (location, reason)
        if finding not in self.problems:
            self.problems.append(finding)

    def scan_payload(self, location: str, name: str, payload: bytes, depth: int = 0) -> None:
        self.files_checked += 1
        basename = PurePosixPath(name).name.lower()
        if basename in RUNTIME_RECORD_NAMES:
            self.fail(location, "runtime/private metadata must not be distributed")
        for number, encodings in self.encoded_terms:
            if any(encoded in payload or encoded in location.encode("utf-8") for encoded in encodings):
                self.fail(location, f"private term #{number} found")

        # Inspect ordinary text and UTF-16 strings embedded in plist/binary data.
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            text = location + "\n" + payload.decode(encoding, errors="ignore")
            if HOME_PATH.search(text):
                self.fail(location, "absolute user home path found")
            if HOST_TEMP_PATH.search(text):
                self.fail(location, "host-specific temporary path found")
            if LEGACY_RESOURCE_STEM + ".json" in text or BUNDLED_LEGACY_LOAD.search(text):
                self.fail(location, "bundled fixed personal list reference found")

        if basename == "info.plist":
            try:
                plist = plistlib.loads(payload)
            except Exception:
                self.fail(location, "Info.plist could not be parsed")
            else:
                self.plists_checked += 1
                if not isinstance(plist, dict):
                    self.fail(location, "Info.plist root is not a dictionary")
                elif self.expected_bundle_id and plist.get("CFBundleIdentifier") != self.expected_bundle_id:
                    self.fail(location, "bundle identifier differs from the public application configuration")

        if payload.startswith(b"PK\x03\x04") and zipfile.is_zipfile(io.BytesIO(payload)):
            if depth >= MAX_ARCHIVE_DEPTH:
                self.fail(location, "archive nesting limit exceeded; contents were not fully checked")
                return
            try:
                with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                    for entry in archive.infolist():
                        if entry.is_dir():
                            continue
                        parts = PurePosixPath(entry.filename).parts
                        member = location + "!" + entry.filename
                        if entry.filename.startswith("/") or ".." in parts:
                            self.fail(member, "unsafe archive path")
                        if stat.S_ISLNK(entry.external_attr >> 16):
                            self.fail(member, "archive symbolic links require a separate review")
                        if entry.file_size > MAX_ENTRY_BYTES:
                            self.fail(member, "archive entry exceeds inspection size limit")
                            continue
                        self.scan_payload(member, entry.filename, archive.read(entry), depth + 1)
            except Exception as error:
                self.fail(location, "archive scan failed: " + type(error).__name__)

    def scan_path(self, supplied: Path) -> None:
        path = supplied.absolute()
        if not path.exists():
            self.fail(path.name, "requested scan path does not exist")
            return
        if path.is_symlink():
            self.fail(path.name, "top-level symbolic link was not followed")
            return
        if path.is_file():
            self.scan_file(path, path.name)
            return
        for current, directories, files in os.walk(path, followlinks=False):
            current_path = Path(current)
            directories[:] = sorted(name for name in directories if name not in IGNORED_DIRECTORIES)
            for directory in list(directories):
                candidate = current_path / directory
                if candidate.is_symlink():
                    self.fail(str(candidate.relative_to(path)), "directory symbolic link was not followed")
                    directories.remove(directory)
            for name in sorted(files):
                candidate = current_path / name
                location = str(candidate.relative_to(path))
                if candidate.is_symlink():
                    self.fail(location, "file symbolic link was not followed")
                    continue
                self.scan_file(candidate, location)

    def scan_file(self, path: Path, location: str) -> None:
        try:
            if path.stat().st_size > MAX_ENTRY_BYTES:
                self.fail(location, "file exceeds inspection size limit")
                return
            self.scan_payload(location, path.name, path.read_bytes())
        except Exception as error:
            self.fail(location, "file scan failed: " + type(error).__name__)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", help="Source tree, application bundle, archive, or individual file to inspect.")
    parser.add_argument("--private-terms-file", metavar="LOCAL_FILE", help="Local JSON string array or line-separated private terms; keep outside the repository.")
    parser.add_argument("--private-terms-env", metavar="VARIABLE", help="Environment variable containing a JSON string array of private terms.")
    parser.add_argument("--expected-bundle-id", default=None, help="Require this bundle identifier in every Info.plist; otherwise infer it from AppConfiguration.swift.")
    args = parser.parse_args()
    try:
        terms = read_terms(args.private_terms_file, args.private_terms_env)
    except Exception as error:
        print("ERROR: Could not read private check inputs: " + type(error).__name__, file=sys.stderr)
        return 2
    checker = Checker(terms, args.expected_bundle_id or configured_bundle_identifier())
    for supplied in args.paths or [str(PROJECT_ROOT)]:
        checker.scan_path(Path(supplied))
    if checker.problems:
        print(f"FAIL: {len(checker.problems)} privacy/package finding(s) across {checker.files_checked} inspected file(s).")
        for location, reason in checker.problems:
            print(f"- {location}: {reason}")
        return 1
    print(f"PASS: {checker.files_checked} file(s) checked, including {checker.plists_checked} Info.plist file(s).")
    print(f"Private inputs: {len(terms)} supplied term(s); no private values were printed or saved.")
    if not terms:
        print("NOTE: Generic paths/resources were checked. Supply a local private-term list for a person-specific release audit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
