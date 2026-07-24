#!/usr/bin/env python3
"""Validate singleton ownership in the default xrobot configuration."""

from pathlib import Path
import sys

import yaml


CONFIG = Path(__file__).resolve().parents[1] / "User/xrobot.yaml"


def main():
    config_path = Path(sys.argv[1]) if len(sys.argv) == 2 else CONFIG
    config = yaml.safe_load(config_path.read_text(encoding="ascii"))
    errors = []
    if not isinstance(config, dict) or not isinstance(config.get("modules"), list):
        print("default configuration contract failed: modules must be a list", file=sys.stderr)
        return 1
    modules = config["modules"]
    if any(not isinstance(module, dict) for module in modules):
        print("default configuration contract failed: every module must be a mapping", file=sys.stderr)
        return 1
    ids = [module.get("id") for module in modules]
    if any(not isinstance(module_id, str) or not module_id for module_id in ids):
        errors.append("every module must have a non-empty string ID")
    elif len(ids) != len(set(ids)):
        errors.append("module IDs must be unique")
    leds = [module for module in modules if module.get("name") == "BlinkLED"]
    if len(leds) != 1:
        errors.append(f"expected exactly one BlinkLED, found {len(leds)}")
    elif leds[0].get("id") != "blink_led":
        errors.append("BlinkLED must use id blink_led")
    else:
        constructor_args = leds[0].get("constructor_args")
        if not isinstance(constructor_args, dict):
            errors.append("blink_led constructor_args must be a mapping")
        elif constructor_args.get("blink_cycle") != 250:
            errors.append("blink_led cycle must remain 250 ms")
    if errors:
        print("default configuration contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: default configuration")
    return 0


if __name__ == "__main__":
    sys.exit(main())
