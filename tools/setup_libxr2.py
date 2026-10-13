#!/usr/bin/env python3
"""Install the pinned runtime and check out the published PLDX static modules."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import venv

ROOT = Path(__file__).resolve().parent.parent
LIBXR_COMMIT = "5161373dbe6d9d9fb1904d90e0ebd4344a44047a"


def run(*args, cwd=None, check=True):
    return subprocess.run(args, cwd=cwd or ROOT, check=check, text=True, capture_output=True)


def checkout(folder, repo, commit):
    if not (folder / ".git").exists():
        if folder.exists() and any(folder.iterdir()):
            raise RuntimeError(f"Refusing to replace nonempty directory: {folder}")
        folder.mkdir(parents=True, exist_ok=True)
        run("git", "init", str(folder))
        run("git", "remote", "add", "origin", repo, cwd=folder)
        run("git", "fetch", "--depth", "1", "origin", commit, cwd=folder)
        run("git", "checkout", "--detach", "FETCH_HEAD", cwd=folder)
    actual = run("git", "rev-parse", "HEAD", cwd=folder).stdout.strip()
    if actual != commit:
        raise RuntimeError(f"{folder}: expected {commit}, found {actual}; existing checkout preserved")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-install", action="store_true", help="use the existing .venv-xrobot2")
    args = parser.parse_args()
    environment = ROOT / ".venv-xrobot2"
    python = environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if not args.skip_install:
        if not python.exists():
            venv.create(environment, with_pip=True)
        run(str(python), "-m", "pip", "install", "xrobot==1.0.1")
    if not python.exists():
        raise RuntimeError("Run without --skip-install to create .venv-xrobot2")
    # Use the tool's installed YAML dependency, keeping the bootstrap stdlib-only.
    lock = run(str(python), "-c", "import json,yaml; print(json.dumps(yaml.safe_load(open('xrobot.lock'))))")
    import json
    modules = json.loads(lock.stdout)["modules"]
    checkout(ROOT / ".tooling/LibXR-v2.0.1", "https://github.com/xrobot-org/LibXR.git", LIBXR_COMMIT)
    for identity, record in modules.items():
        owner, name = identity.split("/")
        folder = ROOT / "Modules" / name
        checkout(folder, record["repo"], record["commit"])
        alias = ROOT / "Modules" / owner / name
        alias.parent.mkdir(parents=True, exist_ok=True)
        if alias.exists():
            if alias.resolve() != folder.resolve():
                raise RuntimeError(f"Wrong package alias: {alias}")
        elif os.name == "nt":
            run("cmd", "/c", "mklink", "/J", str(alias), str(folder))
        else:
            alias.symlink_to("../" + name, target_is_directory=True)
    print("LibXR v2.0.1 and PLDX static modules ready. Add .venv-xrobot2/bin (Windows: Scripts) to PATH.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
