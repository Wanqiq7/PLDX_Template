#!/usr/bin/env python3
"""Negative coverage for the sentry transport configuration gate."""

from contextlib import contextmanager, redirect_stderr, redirect_stdout
from copy import deepcopy
from io import StringIO
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
GIMBAL_CONFIG = ROOT / "User/RobotConfig/sentry_gimbal.yaml"
CHASSIS_CONFIG = ROOT / "User/RobotConfig/sentry_chassis.yaml"
sys.path.insert(0, str(ROOT))

from tools import check_sentry_transport_config as check


class SentryTransportConfigTest(unittest.TestCase):
    @contextmanager
    def temporary_configs(self, mutator=None):
        with TemporaryDirectory() as directory:
            directory_path = Path(directory)
            gimbal_path = directory_path / "sentry_gimbal.yaml"
            chassis_path = directory_path / "sentry_chassis.yaml"
            gimbal_config = yaml.safe_load(GIMBAL_CONFIG.read_text(encoding="ascii"))
            chassis_config = yaml.safe_load(CHASSIS_CONFIG.read_text(encoding="ascii"))
            if mutator is not None:
                mutator(gimbal_config, chassis_config)
            gimbal_path.write_text(
                yaml.safe_dump(gimbal_config, sort_keys=False), encoding="ascii"
            )
            chassis_path.write_text(
                yaml.safe_dump(chassis_config, sort_keys=False), encoding="ascii"
            )
            yield gimbal_path, chassis_path

    def assert_gate_rejected(self, gimbal_path, chassis_path, expected_error):
        stderr = StringIO()
        with (
            patch.object(check, "GIMBAL_CONFIG", gimbal_path),
            patch.object(check, "CHASSIS_CONFIG", chassis_path),
            redirect_stderr(stderr),
            redirect_stdout(StringIO()),
        ):
            self.assertEqual(check.main(), 1)
        self.assertIn(expected_error, stderr.getvalue())

    def test_rejects_duplicate_yaml_mapping_key(self):
        with TemporaryDirectory() as directory:
            directory_path = Path(directory)
            gimbal_path = directory_path / "sentry_gimbal.yaml"
            chassis_path = directory_path / "sentry_chassis.yaml"
            gimbal_text = GIMBAL_CONFIG.read_text(encoding="ascii")
            gimbal_path.write_text(
                gimbal_text.replace(
                    "    cmd: '@&cmd'\n",
                    "    cmd: '@&cmd'\n    cmd: '@&cmd'\n",
                    1,
                ),
                encoding="ascii",
            )
            chassis_path.write_text(
                CHASSIS_CONFIG.read_text(encoding="ascii"), encoding="ascii"
            )
            self.assert_gate_rejected(gimbal_path, chassis_path, "duplicate key")

    def test_rejects_duplicate_dual_board_module(self):
        def add_duplicate_dual_board(gimbal_config, chassis_config):
            dual_board = next(
                module for module in gimbal_config["modules"]
                if module["name"] == "DualBoard"
            )
            gimbal_config["modules"].append(deepcopy(dual_board))

        with self.temporary_configs(add_duplicate_dual_board) as paths:
            self.assert_gate_rejected(*paths, "gimbal DualBoard: expected exactly one")

    def test_rejects_duplicate_shared_topic_input(self):
        def duplicate_target_input(gimbal_config, chassis_config):
            shared_topic = next(
                module for module in gimbal_config["modules"]
                if module["name"] == "SharedTopic"
                and module["constructor_args"].get("uart_name") == check.USB_UART
            )
            shared_topic["constructor_args"]["topic_configs"].append("target_euler")

        with self.temporary_configs(duplicate_target_input) as paths:
            self.assert_gate_rejected(
                *paths, "gimbal SharedTopic contains duplicate topics: target_euler"
            )

    def test_rejects_usb_decision_topic(self):
        def add_decision_input(gimbal_config, chassis_config):
            shared_topic = next(
                module for module in gimbal_config["modules"]
                if module["name"] == "SharedTopic"
                and module["constructor_args"].get("uart_name") == check.USB_UART
            )
            shared_topic["constructor_args"]["topic_configs"].append("sentry_state")

        with self.temporary_configs(add_decision_input) as paths:
            self.assert_gate_rejected(
                *paths,
                "gimbal USB SharedTopic must not expose navigation decision topics: sentry_state",
            )

    def test_rejects_chassis_usb_client(self):
        def add_chassis_usb_client(gimbal_config, chassis_config):
            chassis_config["modules"].append(
                {
                    "id": "unexpected_usb_client",
                    "name": "SharedTopicClient",
                    "constructor_args": {
                        "uart_name": "usb_otg_hs_cdc",
                        "slot_count": 16,
                        "topic_configs": ["ahrs_quaternion"],
                    },
                }
            )

        with self.temporary_configs(add_chassis_usb_client) as paths:
            self.assert_gate_rejected(
                *paths,
                "expected exactly one SharedTopicClient on usb_otg_hs_cdc, found 2",
            )


if __name__ == "__main__":
    unittest.main()
