#!/usr/bin/env python3
"""Generate each product and compile all module interfaces with the firmware toolchain."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="build/libxr2_gimbal")
    args = parser.parse_args()
    import os
    cli = ROOT / ".venv-xrobot2" / ("Scripts/xrobot.exe" if os.name == "nt" else "bin/xrobot")
    for config in ["User/xrobot.yaml", "User/RobotConfig/sentry_chassis.yaml", "User/RobotConfig/sentry_gimbal.yaml"]:
        subprocess.run([str(cli), "gen", "-c", config], cwd=ROOT, check=True)
    records = json.loads((ROOT / args.build_dir / "compile_commands.json").read_text())
    record = next(r for r in records if Path(r["file"]).name == "app_main.cpp")
    command = shlex.split(record["command"])
    kept = []
    skip = False
    for arg in command:
        if skip:
            skip = False
        elif arg in ("-o", "-MT", "-MF"):
            skip = True
        elif arg not in ("-MD", "-c", record["file"]):
            kept.append(arg)
    headers = sorted(p for p in (ROOT / "Modules").glob("*/*.hpp") if p.stem == p.parent.name)
    assert len(headers) == 30, "Expected all 30 PLDX module interfaces"
    for header in headers:
        text = header.read_text()
        assert not any(name in text for name in ("app_framework.hpp", "HardwareContainer", "ApplicationManager")), header
    with tempfile.TemporaryDirectory(prefix="pldx-libxr2-") as temporary:
        probe = Path(temporary) / "all_modules.cpp"
        probe.write_text("\n".join(f'#include "{header.name}"' for header in headers) + "\n")
        subprocess.run(kept + ["-Werror", "-fsyntax-only", str(probe)], cwd=record["directory"], check=True)
    print("PASS: three static configurations and all 30 module interfaces")


if __name__ == "__main__":
    main()
