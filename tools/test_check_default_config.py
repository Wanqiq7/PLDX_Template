#!/usr/bin/env python3
"""Negative coverage for the default xrobot configuration checker."""

from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "tools/check_default_config.py"
VALID = """\
global_settings: {monitor_sleep_ms: 1000}
modules:
- id: blink_led
  name: BlinkLED
  constructor_args: {blink_cycle: 250}
"""


class DefaultConfigCheckTest(unittest.TestCase):
    def run_config(self, text):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            path.write_text(text, encoding="ascii")
            return subprocess.run(
                ["python3", str(CHECKER), str(path)],
                capture_output=True,
                encoding="ascii",
                check=False,
            )

    def test_accepts_valid_config(self):
        result = self.run_config(VALID)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_duplicate_led(self):
        result = self.run_config(VALID + "- id: second\n  name: BlinkLED\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("exactly one BlinkLED", result.stderr)

    def test_rejects_malformed_module_id(self):
        result = self.run_config(VALID.replace("id: blink_led", "id: []"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("non-empty string ID", result.stderr)

    def test_rejects_malformed_constructor_args(self):
        result = self.run_config(VALID.replace("{blink_cycle: 250}", "[]"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("constructor_args must be a mapping", result.stderr)


if __name__ == "__main__":
    unittest.main()
