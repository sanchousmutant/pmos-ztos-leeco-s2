#!/bin/sh
# Build mainline 6.18.7 for LeEco Le 2 (s2) inside WSL.
# Usage: KERNEL_DIR=$HOME/linux-msm8956 ./kernel/build.sh
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KERNEL_DIR=${KERNEL_DIR:-$HOME/linux-msm8956}
export ARCH=arm64
export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
CROSS="$CROSS_COMPILE"
JOBS=${JOBS:-$(nproc)}

if [ ! -d "$KERNEL_DIR" ]; then
	echo "kernel tree not found: $KERNEL_DIR" >&2
	exit 1
fi

if ! grep -q 'msm8956-generated' "$KERNEL_DIR/drivers/gpu/drm/panel/Makefile"; then
	echo "applying $HERE/leeco-s2-6.18.7.patch"
	(cd "$KERNEL_DIR" && patch -p1 < "$HERE/leeco-s2-6.18.7.patch")
fi

cp "$HERE/config-6.18.7-leeco-s2" "$KERNEL_DIR/.config"
cp "$HERE/msm8976-leeco-s2.dts" "$KERNEL_DIR/arch/arm64/boot/dts/qcom/"
cp "$HERE/panel-leeco-s2-boe-nt35596s.c" \
	"$KERNEL_DIR/drivers/gpu/drm/panel/msm8956-generated/"

cd "$KERNEL_DIR"
make ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
make ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image.gz dtbs

echo "built:"
ls -l "$KERNEL_DIR/arch/arm64/boot/Image" \
	"$KERNEL_DIR/arch/arm64/boot/Image.gz" \
	"$KERNEL_DIR/arch/arm64/boot/dts/qcom/msm8976-leeco-s2.dtb"
