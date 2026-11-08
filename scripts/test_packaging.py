#!/usr/bin/env python3
"""Check package-tree safety and retention using disposable local directories.

The release DMG itself is audited by privacy_check.py after building; these
negative fixtures deliberately avoid mounting images or requesting privileges.
"""
from __future__ import annotations

import contextlib
import io
from pathlib import Path
import tempfile
import unittest

import build
from privacy_check import Checker


class PackagingTests(unittest.TestCase):
    def scan_fixture(self, configure, terms=None) -> Checker:
        with tempfile.TemporaryDirectory(prefix="desktop-privacy-package-test-") as temporary:
            root = Path(temporary)
            contents = root / "contents"
            contents.mkdir()
            configure(contents)
            checker = Checker(terms or [], None)
            checker.scan_tree(contents, prefix="synthetic-package!", disk_image_depth=1,
                              allow_applications_shortcut=True)
            return checker

    def test_installer_shortcut_is_not_followed(self):
        def configure(root):
            (root / "Applications").symlink_to("/Applications", target_is_directory=True)
            (root / "Installation.txt").write_text("Synthetic install instructions.")
        checker = self.scan_fixture(configure)
        self.assertEqual(checker.problems, [])
        # Only the regular file; nothing in /Applications was scanned.
        self.assertEqual(checker.files_checked, 1)

    def test_wrong_destination_and_nested_shortcuts_are_rejected(self):
        def configure(root):
            (root / "Applications").symlink_to("/tmp", target_is_directory=True)
            (root / "AnotherShortcut").symlink_to("/Applications", target_is_directory=True)
            (root / "nested").mkdir()
            (root / "nested" / "Applications").symlink_to("/Applications", target_is_directory=True)
        checker = self.scan_fixture(configure)
        self.assertEqual(len(checker.problems), 3)
        self.assertTrue(all("symbolic link" in reason for _, reason in checker.problems))

    def test_packaged_contents_are_inspected_including_hidden_directories(self):
        marker = "SYNTHETIC_PRIVATE_MARKER"
        def configure(root):
            (root / "manifest.json").write_text("{}")
            (root / ".git").mkdir()
            (root / ".git" / "private.txt").write_text(marker)
        checker = self.scan_fixture(configure, [marker])
        self.assertTrue(any("runtime/private metadata" in reason for _, reason in checker.problems))
        self.assertTrue(any("private term #1" in reason for _, reason in checker.problems))
        self.assertFalse(any("could not" in reason for _, reason in checker.problems))

    def test_retention_only_removes_recognized_older_release_files(self):
        with tempfile.TemporaryDirectory(prefix="desktop-privacy-retention-test-") as temporary:
            root = Path(temporary)
            for version in ["1.0.2", "1.1.0", "1.1.1"]:
                for ending in ["universal.dmg", "universal.zip", "source.zip"]:
                    (root / f"Desktop-Privacy-{version}-{ending}").write_text("synthetic")
                (root / f"SHA256SUMS-{version}.txt").write_text("synthetic")
            (root / "keep-this.dmg").write_text("unrelated")
            (root / "Desktop-Privacy-0.0.1-universal.dmg").symlink_to("keep-this.dmg")
            with contextlib.redirect_stdout(io.StringIO()):
                build.prune_old_packages(root)
            self.assertFalse(any("1.0.2" in p.name for p in root.iterdir()))
            self.assertEqual(len(list(root.iterdir())), 10)
            self.assertEqual((root / "keep-this.dmg").read_text(), "unrelated")
            self.assertTrue((root / "Desktop-Privacy-0.0.1-universal.dmg").is_symlink())


if __name__ == "__main__":
    unittest.main(verbosity=2)
