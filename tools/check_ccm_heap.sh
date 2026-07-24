#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 ELF MAP" >&2
  exit 2
fi

elf=$1
map=$2
readelf_bin=${STARM_READELF:-}
if [[ -z "$readelf_bin" ]]; then
  readelf_bin=$(command -v starm-readelf || command -v readelf || true)
fi
if [[ -z "$readelf_bin" ]]; then
  echo "missing: starm-readelf/readelf" >&2
  exit 1
fi

sections=$($readelf_bin -SW "$elf" 2>/dev/null)
section_line=$(printf '%s\n' "$sections" | awk '$2 == ".ccmbss" { print; exit }')
if [[ -z "$section_line" ]]; then
  echo "missing: .ccmbss section" >&2
  exit 1
fi
section_index=$(printf '%s\n' "$section_line" | awk '{ gsub(/\[/, "", $1); gsub(/\]/, "", $1); print $1 }')
section_type=$(printf '%s\n' "$section_line" | awk '{ print $3 }')
section_addr=$(printf '%s\n' "$section_line" | awk '{ print $4 }')
section_size=$(printf '%s\n' "$section_line" | awk '{ print $6 }')
if [[ "$section_type" != "NOBITS" ]]; then
  echo "wrong: .ccmbss type $section_type" >&2
  exit 1
fi
section_addr_value=$((16#$section_addr))
section_size_value=$((16#$section_size))
if (( section_addr_value < 0x10000000 || section_addr_value >= 0x10010000 )); then
  echo "wrong: .ccmbss VMA $section_addr" >&2
  exit 1
fi
if (( section_addr_value + section_size_value > 0x10010000 )); then
  echo "wrong: .ccmbss exceeds CCM VMA" >&2
  exit 1
fi

symbol_line=$($readelf_bin -sW "$elf" 2>/dev/null | awk '$NF == "ucHeap" { print; exit }')
if [[ -z "$symbol_line" ]]; then
  echo "missing: ucHeap symbol" >&2
  exit 1
fi
symbol_size=$(printf '%s\n' "$symbol_line" | awk '{ print $3 }')
symbol_value=$(printf '%s\n' "$symbol_line" | awk '{ print $2 }')
symbol_section=$(printf '%s\n' "$symbol_line" | awk '{ print $7 }')
if (( symbol_size != 0x10000 )); then
  echo "wrong: ucHeap size $symbol_size" >&2
  exit 1
fi
if [[ "$symbol_section" != "$section_index" ]]; then
  echo "wrong: ucHeap section $symbol_section (expected $section_index)" >&2
  exit 1
fi
if (( 16#$symbol_value != section_addr_value )); then
  echo "wrong: ucHeap ELF address $symbol_value" >&2
  exit 1
fi

map_section_line=$(awk '$5 == ".ccmbss" { print; exit }' "$map")
if [[ -z "$map_section_line" ]]; then
  echo "missing: .ccmbss map section" >&2
  exit 1
fi
map_vma=$(printf '%s\n' "$map_section_line" | awk '{ print $1 }')
map_lma=$(printf '%s\n' "$map_section_line" | awk '{ print $2 }')
if [[ "$map_vma" != "$map_lma" ]]; then
  echo "wrong: .ccmbss FLASH LMA $map_lma" >&2
  exit 1
fi
if (( 16#$map_vma != section_addr_value )); then
  echo "wrong: map/ELF .ccmbss address mismatch" >&2
  exit 1
fi
map_heap_line=$(awk '$NF == "ucHeap" { print; exit }' "$map")
if [[ -z "$map_heap_line" ]]; then
  echo "missing: ucHeap map symbol" >&2
  exit 1
fi
map_heap_vma=$(printf '%s\n' "$map_heap_line" | awk '{ print $1 }')
map_heap_size=$(printf '%s\n' "$map_heap_line" | awk '{ print $3 }')
if [[ "$map_heap_vma" != "$symbol_value" || "$map_heap_size" != "10000" ]]; then
  echo "wrong: ucHeap map placement" >&2
  exit 1
fi

echo "PASS: .ccmbss NOBITS VMA=$section_addr ucHeap=$symbol_size"
