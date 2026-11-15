#!/bin/bash
# Build DTB from source - requires dtc
# ./build_dtb.sh                  # собрать s2-v2.dtb
# ./build_dtb.sh /path/to/s2.dts  # собрать из указанного DTS

DTC="./dtc"
SRC_DTS="/tmp/s2_full.dts"
OUT_DTB="s2-v2.dtb"

if [ ! -z "$1" ]; then
    SRC_DTS="$1"
    OUT_DTB="${1%.dts}.dtb"
fi

# Check dtc
if ! command -v dtc &>/dev/null && [ ! -f "$DTC" ]; then
    echo "dtc not found. Install or compile:"
    echo "  sudo pacman -S dtc"
    echo "or download from https://mirrors.edge.kernel.org/pub/software/utils/dtc/"
    exit 1
fi

# Find dtc
if [ -f "$DTC" ]; then
    DTC_CMD="$DTC"
else
    DTC_CMD="dtc"
fi

echo "Using: $DTC_CMD"
echo "DTS: $SRC_DTS"
echo "Output: $OUT_DTB"

# Generate DTS from existing DTB if source not provided
if [ ! -f "$SRC_DTS" ]; then
    echo "DTS not found, decompiling s2.dtb..."
    $DTC_CMD -I dtb -O dts -o "$SRC_DTS" s2.dtb 2>/dev/null
fi

# Build DTB
$DTC_CMD -I dts -O dtb -o "$OUT_DTB" "$SRC_DTS" 2>&1 | grep -i "error\|warning.*Error" || true
echo "Done: $(ls -la "$OUT_DTB" | awk '{print $5}') bytes"
