#!/usr/bin/env python3
"""Генерирует mainline-драйвер панели LeEco Le 2 (BOE NT35596S).

Исходные данные: декомпилированный downstream DTS /home/sanch/s2-new2.dts.
Результат: panel-leeco-s2-boe-nt35596s.c в дереве linux-msm8956.
"""

import re
import sys

DTS = "/home/sanch/s2-new2.dts"
OUT = ("/home/sanch/linux-msm8956/drivers/gpu/drm/panel/"
       "msm8956-generated/panel-leeco-s2-boe-nt35596s.c")
NODE_NAME = "qcom,mdss_dsi_boe_nt35596s_fhd_5p5boe_vdo"
COMPATIBLE = "leeco,s2-boe-nt35596s"
PREFIX = "leeco_s2_nt35596s"
DRIVER_NAME = "panel-leeco-s2-boe-nt35596s"


def extract_node(text):
    start = text.find(NODE_NAME + " {")
    if start < 0:
        sys.exit("не найден узел " + NODE_NAME)
    brace = text.find("{", start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    sys.exit("не найден конец узла " + NODE_NAME)


def array_prop(node, name):
    m = re.search(re.escape(name) + r"\s*=\s*\[(.*?)\];", node, re.S)
    if not m:
        sys.exit("не найдено свойство " + name)
    return m.group(1)


def int_prop(node, name):
    m = re.search(re.escape(name) + r"\s*=\s*<([^>]*)>;", node)
    if not m:
        sys.exit("не найдено свойство " + name)
    return int(m.group(1).split()[0], 0)


def parse_packets(arr):
    data = [int(x, 16) for x in arr.split()]
    packets = []
    i = 0
    while i < len(data):
        if i + 7 > len(data):
            sys.exit(f"обрыв пакета на смещении {i}")
        dtype = data[i]
        wait = data[i + 4]
        length = (data[i + 5] << 8) | data[i + 6]
        payload = data[i + 7:i + 7 + length]
        if len(payload) != length:
            sys.exit(f"неполный пакет на смещении {i}: "
                     f"нужно {length}, есть {len(payload)}")
        packets.append((dtype, wait, payload))
        i += 7 + length
    return packets


def gen_cmds(packets):
    out = []
    for dtype, wait, payload in packets:
        if dtype == 0x05:
            cmd = payload[0]
            names = {
                0x10: "enter_sleep_mode",
                0x11: "exit_sleep_mode",
                0x28: "set_display_off",
                0x29: "set_display_on",
            }
            if cmd in names:
                out.append(f"\tmipi_dsi_dcs_{names[cmd]}_multi(&dsi_ctx);")
            else:
                out.append(f"\tmipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x{cmd:02x});")
        elif dtype == 0x15:
            args = ", ".join(f"0x{x:02x}" for x in payload)
            out.append(f"\tmipi_dsi_dcs_write_seq_multi(&dsi_ctx, {args});")
        else:
            args = ", ".join(f"0x{x:02x}" for x in payload)
            out.append(f"\tmipi_dsi_generic_write_seq_multi(&dsi_ctx, {args});")
        if wait:
            out.append(f"\tmipi_dsi_msleep(&dsi_ctx, {wait});")
    return "\n".join(out)


def gen_reset(values):
    out = []
    for i in range(0, len(values) - 1, 2):
        level = 1 - values[i]
        delay = values[i + 1]
        out.append(f"\tgpiod_set_value_cansleep(ctx->reset_gpio, {level});")
        if delay >= 20:
            out.append(f"\tmsleep({delay});")
        else:
            out.append(f"\tusleep_range({delay * 1000}, {delay * 1000 + 1000});")
    out.append("\tmsleep(20);")
    return "\n".join(out)


def main():
    text = open(DTS, encoding="utf-8").read()
    node = extract_node(text)

    on_arr = array_prop(node, "qcom,mdss-dsi-on-command")
    off_arr = array_prop(node, "qcom,mdss-dsi-off-command")
    on = parse_packets(on_arr)
    off = parse_packets(off_arr)
    reset = [int(x, 0) for x in re.search(
        r"qcom,mdss-dsi-reset-sequence\s*=\s*<([^>]*)>;", node).group(1).split()]

    w = int_prop(node, "qcom,mdss-dsi-panel-width")
    h = int_prop(node, "qcom,mdss-dsi-panel-height")
    hfp = int_prop(node, "qcom,mdss-dsi-h-front-porch")
    hbp = int_prop(node, "qcom,mdss-dsi-h-back-porch")
    hsw = int_prop(node, "qcom,mdss-dsi-h-pulse-width")
    vfp = int_prop(node, "qcom,mdss-dsi-v-front-porch")
    vbp = int_prop(node, "qcom,mdss-dsi-v-back-porch")
    vsw = int_prop(node, "qcom,mdss-dsi-v-pulse-width")
    fps = int_prop(node, "qcom,mdss-dsi-panel-framerate")
    wmm = int_prop(node, "qcom,mdss-pan-physical-width-dimension")
    hmm = int_prop(node, "qcom,mdss-pan-physical-height-dimension")

    on_cmds = gen_cmds(on)
    off_cmds = gen_cmds(off)
    reset_cmds = gen_reset(reset)

    c = f'''// SPDX-License-Identifier: GPL-2.0-only
/*
 * LeEco Le 2 (s2) BOE NT35596S panel driver.
 *
 * Generated from the downstream LeEco s2 device tree
 * (qcom,mdss_dsi_boe_nt35596s_fhd_5p5boe_vdo).
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/regulator/consumer.h>

#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>
#include <drm/drm_probe_helper.h>

struct {PREFIX} {{
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct regulator_bulk_data *supplies;
	struct gpio_desc *reset_gpio;
}};

static const struct regulator_bulk_data {PREFIX}_supplies[] = {{
	{{ .supply = "vdd" }},
	{{ .supply = "vddio" }},
	{{ .supply = "lab" }},
	{{ .supply = "ibb" }},
}};

static inline struct {PREFIX} *to_{PREFIX}(struct drm_panel *panel)
{{
	return container_of(panel, struct {PREFIX}, panel);
}}

static void {PREFIX}_reset(struct {PREFIX} *ctx)
{{
{reset_cmds}
}}

static int {PREFIX}_on(struct {PREFIX} *ctx)
{{
	struct mipi_dsi_multi_context dsi_ctx = {{ .dsi = ctx->dsi }};

{on_cmds}

	mipi_dsi_msleep(&dsi_ctx, 5);

	return dsi_ctx.accum_err;
}}

static int {PREFIX}_off(struct {PREFIX} *ctx)
{{
	struct mipi_dsi_multi_context dsi_ctx = {{ .dsi = ctx->dsi }};

{off_cmds}

	return dsi_ctx.accum_err;
}}

static int {PREFIX}_prepare(struct drm_panel *panel)
{{
	struct {PREFIX} *ctx = to_{PREFIX}(panel);
	struct device *dev = &ctx->dsi->dev;
	int ret;

	ret = regulator_bulk_enable(ARRAY_SIZE({PREFIX}_supplies), ctx->supplies);
	if (ret < 0) {{
		dev_err(dev, "Failed to enable regulators: %d\\n", ret);
		return ret;
	}}

	{PREFIX}_reset(ctx);

	ret = {PREFIX}_on(ctx);
	if (ret < 0) {{
		dev_err(dev, "Failed to initialize panel: %d\\n", ret);
		gpiod_set_value_cansleep(ctx->reset_gpio, 1);
		regulator_bulk_disable(ARRAY_SIZE({PREFIX}_supplies), ctx->supplies);
		return ret;
	}}

	return 0;
}}

static int {PREFIX}_unprepare(struct drm_panel *panel)
{{
	struct {PREFIX} *ctx = to_{PREFIX}(panel);
	struct device *dev = &ctx->dsi->dev;
	int ret;

	ret = {PREFIX}_off(ctx);
	if (ret < 0)
		dev_err(dev, "Failed to un-initialize panel: %d\\n", ret);

	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	regulator_bulk_disable(ARRAY_SIZE({PREFIX}_supplies), ctx->supplies);

	return 0;
}}

static const struct drm_display_mode {PREFIX}_mode = {{
	.clock = ({w} + {hfp} + {hsw} + {hbp}) * ({h} + {vfp} + {vsw} + {vbp}) * {fps} / 1000,
	.hdisplay = {w},
	.hsync_start = {w} + {hfp},
	.hsync_end = {w} + {hfp} + {hsw},
	.htotal = {w} + {hfp} + {hsw} + {hbp},
	.vdisplay = {h},
	.vsync_start = {h} + {vfp},
	.vsync_end = {h} + {vfp} + {vsw},
	.vtotal = {h} + {vfp} + {vsw} + {vbp},
	.width_mm = {wmm},
	.height_mm = {hmm},
	.type = DRM_MODE_TYPE_DRIVER,
}};

static int {PREFIX}_get_modes(struct drm_panel *panel,
			      struct drm_connector *connector)
{{
	return drm_connector_helper_get_modes_fixed(connector, &{PREFIX}_mode);
}}

static const struct drm_panel_funcs {PREFIX}_panel_funcs = {{
	.prepare = {PREFIX}_prepare,
	.unprepare = {PREFIX}_unprepare,
	.get_modes = {PREFIX}_get_modes,
}};

static int {PREFIX}_probe(struct mipi_dsi_device *dsi)
{{
	struct device *dev = &dsi->dev;
	struct {PREFIX} *ctx;
	int ret;

	ctx = devm_drm_panel_alloc(dev, struct {PREFIX}, panel,
				   &{PREFIX}_panel_funcs,
				   DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ret = devm_regulator_bulk_get_const(dev,
					    ARRAY_SIZE({PREFIX}_supplies),
					    {PREFIX}_supplies,
					    &ctx->supplies);
	if (ret < 0)
		return ret;

	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio),
				     "Failed to get reset-gpios\\n");

	ctx->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_VIDEO_BURST |
			  MIPI_DSI_CLOCK_NON_CONTINUOUS | MIPI_DSI_MODE_LPM;

	ctx->panel.prepare_prev_first = true;

	ret = drm_panel_of_backlight(&ctx->panel);
	if (ret)
		return dev_err_probe(dev, ret, "Failed to get backlight\\n");

	drm_panel_add(&ctx->panel);

	ret = mipi_dsi_attach(dsi);
	if (ret < 0) {{
		drm_panel_remove(&ctx->panel);
		return dev_err_probe(dev, ret, "Failed to attach to DSI host\\n");
	}}

	return 0;
}}

static void {PREFIX}_remove(struct mipi_dsi_device *dsi)
{{
	struct {PREFIX} *ctx = mipi_dsi_get_drvdata(dsi);
	int ret;

	ret = mipi_dsi_detach(dsi);
	if (ret < 0)
		dev_err(&dsi->dev, "Failed to detach from DSI host: %d\\n", ret);

	drm_panel_remove(&ctx->panel);
}}

static const struct of_device_id {PREFIX}_of_match[] = {{
	{{ .compatible = "{COMPATIBLE}" }},
	{{ /* sentinel */ }}
}};
MODULE_DEVICE_TABLE(of, {PREFIX}_of_match);

static struct mipi_dsi_driver {PREFIX}_driver = {{
	.probe = {PREFIX}_probe,
	.remove = {PREFIX}_remove,
	.driver = {{
		.name = "{DRIVER_NAME}",
		.of_match_table = {PREFIX}_of_match,
	}},
}};
module_mipi_dsi_driver({PREFIX}_driver);

MODULE_AUTHOR("LeEco Le 2 mainline port");
MODULE_DESCRIPTION("DRM driver for LeEco Le 2 BOE NT35596S 1080p video mode DSI panel");
MODULE_LICENSE("GPL");
'''
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(c)

    print(f"on packets: {len(on)}, off packets: {len(off)}")
    print(f"on bytes: {len(on_arr.split())}")
    print(f"off bytes: {len(off_arr.split())}")
    print(f"mode: {w}x{h}, hfp={hfp} hsw={hsw} hbp={hbp}, "
          f"vfp={vfp} vsw={vsw} vbp={vbp}, {fps} Hz")
    print(f"reset: {reset}")
    print(f"written: {OUT}")


if __name__ == "__main__":
    main()
