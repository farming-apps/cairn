#!/usr/bin/env python3
"""Regression tests for tools/sanitize.py."""
import unittest

import sanitize


class EntropyDetectionTests(unittest.TestCase):
    def test_github_commit_url_is_not_a_secret(self):
        line = "([b170925](https://github.com/farming-apps/cairn/commit/b170925839a0dd8abdeb4ce10f4c08bef5178dc8))"
        self.assertEqual(sanitize.scan_text("CHANGELOG.md", line, []), [])

    def test_high_entropy_token_is_still_reported(self):
        findings = sanitize.scan_text("example.txt", "secret = QWERTYuiopASDFGHjklZXCVbnm123456", [])  # sanitize:allow
        self.assertTrue(any(finding[2] == "high-entropy" for finding in findings))


if __name__ == "__main__":
    unittest.main()
