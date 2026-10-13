#!/usr/bin/env python3
"""Regenerate only the Flash map using libxr 6.0.1, without rewriting app_main."""

from pathlib import Path

from libxr.generator_code_stm32 import flash_map_header
from libxr.stm32_flash_generator import flash_info_to_dict, layout_flash


def main():
    root = Path(__file__).resolve().parents[2]
    model = next(
        line.split("=", 1)[1]
        for line in (root / "DevC.ioc").read_text().splitlines()
        if line.startswith("Mcu.CPN=")
    )
    layout = flash_info_to_dict(layout_flash(model))
    (root / "User/flash_map.hpp").write_text(
        flash_map_header(layout, model), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
