#!/usr/bin/env python3
"""Generate upstream XRobot compile probes for every module in the BSP lock."""

import argparse
from pathlib import Path

from xrobot.generate_main import generate_compile_check, load_modules
from xrobot.project import Project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    modules = load_modules(Project(root))
    args.output.mkdir(parents=True, exist_ok=True)
    for identity in sorted(modules):
        name = identity.rsplit("/", 1)[-1]
        template_args = {
            "Chassis": ["Omni"],
            "DualBoard": ["DualBoardRole::CHASSIS", "Omni"],
        }.get(name)
        generate_compile_check(
            identity, modules, args.output / f"{name}.cpp", template_args
        )
    print(f"Generated compile probes for {len(modules)} modules")


if __name__ == "__main__":
    main()
