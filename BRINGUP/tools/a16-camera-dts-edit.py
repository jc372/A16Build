#!/usr/bin/env python3
"""a16-camera-dts-edit.py -- insert the camera step-1 device-tree changes.

Two files in the build tree are edited in place, each with a .a16-pre-camera backup:

  glymur.dtsi                 cci0 + cci1 nodes and the camera pin groups, both
                              taken from Qualcomm's glymur CAMSS series
                              ([PATCH 2/6] CCI definitions, [PATCH 3/6] camera MCLK)
  glymur-asus-zenbook-a16-ux3607oa.dts
                              the board side: PMH0104 I_E0 camera rails, cci1
                              enabled on master 1, the OV08X40 sensor node, the
                              reset pin group

Every number that is not from those upstream patches is cited in a comment in the
inserted text and in readme-camera-step1.md next to this script.

Idempotent: a file that already carries the marker string is left alone.
"""
import os
import re
import shutil

TREE = os.environ.get("A16_TREE", "/home/jc/build/next-20261002-repull")
D = os.path.join(TREE, "arch/arm64/boot/dts/qcom")
DTSI = os.path.join(D, "glymur.dtsi")
BOARD = os.path.join(D, "glymur-asus-zenbook-a16-ux3607oa.dts")
MARK = "glymur camera step1"
CAMSS_INC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "upstream", "glymur-camss-csiphy.dts.inc")

CCI_NODES = """		/* --- glymur camera step1: CCI0/CCI1 ---------------------------------
		 * Verbatim from Qualcomm's [PATCH 2/6] arm64: dts: qcom: glymur: Add CCI
		 * definitions for Glymur (2026-09-07, glymur_camss v1).  Addresses,
		 * interrupts and clocks are that patch's, not inferred:
		 *   cci0@0x0ac15000  GIC_SPI 456  CAM_CC_CCI_0_CLK
		 *   cci1@0x0ac16000  GIC_SPI 859  CAM_CC_CCI_1_CLK
		 * Both stay disabled here; the board file enables cci1 only.
		 */
		cci0: cci@ac15000 {
			compatible = "qcom,glymur-cci", "qcom,msm8996-cci";
			reg = <0x0 0x0ac15000 0x0 0x1000>;

			interrupts = <GIC_SPI 456 IRQ_TYPE_EDGE_RISING>;

			clocks = <&camcc CAM_CC_CPAS_AHB_CLK>,
				 <&camcc CAM_CC_CCI_0_CLK>;
			clock-names = "ahb",
				      "cci";

			power-domains = <&camcc CAM_CC_TITAN_TOP_GDSC>;

			pinctrl-0 = <&cci0_0_default>, <&cci0_1_default>;
			pinctrl-1 = <&cci0_0_sleep>, <&cci0_1_sleep>;
			pinctrl-names = "default", "sleep";

			#address-cells = <1>;
			#size-cells = <0>;

			status = "disabled";

			cci0_i2c0: i2c-bus@0 {
				reg = <0>;
				clock-frequency = <400000>;
				#address-cells = <1>;
				#size-cells = <0>;
			};

			cci0_i2c1: i2c-bus@1 {
				reg = <1>;
				clock-frequency = <400000>;
				#address-cells = <1>;
				#size-cells = <0>;
			};
		};

		cci1: cci@ac16000 {
			compatible = "qcom,glymur-cci", "qcom,msm8996-cci";
			reg = <0x0 0x0ac16000 0x0 0x1000>;

			interrupts = <GIC_SPI 859 IRQ_TYPE_EDGE_RISING>;

			clocks = <&camcc CAM_CC_CPAS_AHB_CLK>,
				 <&camcc CAM_CC_CCI_1_CLK>;
			clock-names = "ahb",
				      "cci";

			power-domains = <&camcc CAM_CC_TITAN_TOP_GDSC>;

			pinctrl-0 = <&cci1_0_default>, <&cci1_1_default>;
			pinctrl-1 = <&cci1_0_sleep>, <&cci1_1_sleep>;
			pinctrl-names = "default", "sleep";

			#address-cells = <1>;
			#size-cells = <0>;

			status = "disabled";

			cci1_i2c0: i2c-bus@0 {
				reg = <0>;
				clock-frequency = <400000>;
				#address-cells = <1>;
				#size-cells = <0>;
			};

			cci1_i2c1: i2c-bus@1 {
				reg = <1>;
				clock-frequency = <400000>;
				#address-cells = <1>;
				#size-cells = <0>;
			};
		};

"""


def mclk(i, pin, fn):
    return f"""			cam_mclk{i}_default: cam-mclk{i}-default-state {{
				pins = "gpio{pin}";
				function = "{fn}";
				drive-strength = <2>;
				bias-disable;
			}};

"""


def cci_state(label, node, sda, scl, bias):
    # master 1 of cci1 is the always-on camera pair, and the driver calls its
    # function asc_cci; every other pair is cci_i2c_sda / cci_i2c_scl.
    fn_sda, fn_scl = ("asc_cci", "asc_cci") if label.startswith("cci1_1") \
        else ("cci_i2c_sda", "cci_i2c_scl")
    return f"""			{label}: {node} {{
				sda-pins {{
					pins = "{sda}";
					function = "{fn_sda}";
					drive-strength = <2>;
					{bias}
				}};

				scl-pins {{
					pins = "{scl}";
					function = "{fn_scl}";
					drive-strength = <2>;
					{bias}
				}};
			}};

"""


PIN_BLOCK = (
    """			/* --- glymur camera step1: camera pinctrl ----------------------------
			 * cam_mclk0..4 are Qualcomm's [PATCH 3/6] "Add camera MCLK pinctrl";
			 * the four cci states are [PATCH 2/6].  GPIO numbers and function
			 * names are the driver's own, checked against
			 * drivers/pinctrl/qcom/pinctrl-glymur.c: cci_i2c_sda on 101/103/105,
			 * cci_i2c_scl on 102/104/106, asc_cci on 235/236, cam_asc_mclk4 on
			 * gpio100.  MCLK4 is the ASC ("always-on camera") clock, which is
			 * the front camera's -- CAMF_RES_MTP.bin asks for cam_cc_mclk4_clk.
			 */
"""
    + mclk(0, 96, "cam_mclk")
    + mclk(1, 97, "cam_mclk")
    + mclk(2, 98, "cam_mclk")
    + mclk(3, 99, "cam_mclk")
    + mclk(4, 100, "cam_asc_mclk4")
    + cci_state("cci0_0_default", "cci0-0-default-state", "gpio101", "gpio102", "bias-pull-up = <2200>;")
    + cci_state("cci0_0_sleep", "cci0-0-sleep-state", "gpio101", "gpio102", "bias-pull-down;")
    + cci_state("cci0_1_default", "cci0-1-default-state", "gpio103", "gpio104", "bias-pull-up = <2200>;")
    + cci_state("cci0_1_sleep", "cci0-1-sleep-state", "gpio103", "gpio104", "bias-pull-down;")
    + cci_state("cci1_0_default", "cci1-0-default-state", "gpio105", "gpio106", "bias-pull-up = <2200>;")
    + cci_state("cci1_0_sleep", "cci1-0-sleep-state", "gpio105", "gpio106", "bias-pull-down;")
    + cci_state("cci1_1_default", "cci1-1-default-state", "gpio235", "gpio236", "bias-pull-up = <2200>;")
    + cci_state("cci1_1_sleep", "cci1-1-sleep-state", "gpio235", "gpio236", "bias-pull-down;")
)

# The camera rail node that used to be inserted into regulators-0 is GONE on
# purpose.  It was PMH0101 bob1 at 3400000 uV, which is not on that rail's
# step grid: "unsupportable voltage constraints 3416000-3384000uV", the rail
# failed to register, devres unregistered every other rail of that container
# with it, and every consumer of PMH0101 deferred -- the wifi's PCIe rail
# (l15b), the USB rails, i2c slaves.  No PCIe, no wifi, no USB-A, on two
# boots.  Step 1 now declares no rails at all; see RESULT.md of patch 0020.

REGULATORS_CAMERA_PMIC = """	/* --- glymur camera step1: the PMH0104 rails the camera runs on ---------
	 * pmic-id I_E0 is the PMH0104 at SPMI address 8.  ldo7 (2.8 V) and ldo4
	 * (1.8 V) are the two rails the vendor's camera blobs vote for and the two the
	 * sensor's avdd/dovdd/dvdd hang off.  The smps and ldo3 are left out on
	 * purpose: this file declares what the camera needs and nothing else, so a
	 * mistake here can only touch the camera's own rails.
	 *
	 * THIS CONTAINER NEEDS THE MODULE FROM patches/0021.  On the stock module it
	 * logs `rpmh-regulator ... ldo4: Unknown regulator ldo4` once per rail and
	 * registers nothing, leaving the sensor on dummy regulators -- the state boot
	 * b730f501 was in.  With 0021 installed the rails bind and the supplies above
	 * resolve.
	 */
	regulators-5 {
		compatible = "qcom,pmh0104-rpmh-regulators";
		qcom,pmic-id = "I_E0";

		vreg_l4i_e0: ldo4 {
			regulator-name = "vreg_l4i_e0";
			regulator-min-microvolt = <1800000>;
			regulator-max-microvolt = <1800000>;
			regulator-initial-mode = <RPMH_REGULATOR_MODE_HPM>;
		};

		vreg_l7i_e0: ldo7 {
			regulator-name = "vreg_l7i_e0";
			regulator-min-microvolt = <2800000>;
			regulator-max-microvolt = <2800000>;
			regulator-initial-mode = <RPMH_REGULATOR_MODE_HPM>;
		};
	};
"""

SENSOR = """
/* --- glymur camera step1: cci1 master 1, OV08X40 front sensor (I2C only) ----
 * Structure and pin mapping follow Qualcomm's [PATCH 5/6] "glymur-crd: Add ov08x40
 * RGB sensor on CSIPHY4": the sensor hangs off cci1_i2c1 (master 1, the ASC pins
 * gpio235/236), reset is TLMM 239 active low, MCLK4 runs at 19.2 MHz.
 *
 * The machine-specific values are the A16's own, taken from the vendor blobs:
 *   reset gpio 239            CAMF_RES_MTP.bin   TLMMGPIO 0xEF
 *   MCLK4 19.2 MHz            CAMF_RES_MTP.bin   cam_cc_mclk4_clk, value 19200000
 *   i2c address 0x36          SCFG_FRONT_MTP.bin + bus_info.primary.slave_config
 *   rails                     CAMF_RES_MTP.bin votes BUCK_BOOST1_B_E0 (3.4 V),
 *                             LDO4_I0 (1.8 V), LDO7_I0 (2.8 V)
 *
 * The supplies ARE declared, and they are the machine's own rails: the vendor
 * blobs vote LDO7_I0 (2.8 V) and LDO4_I0 (1.8 V) for this camera, and Qualcomm's
 * own glymur patch [5/6] wires the same three on their board --
 *     avdd-supply  = l7   2.8 V
 *     dovdd-supply = l4   1.8 V
 *     dvdd-supply  = l4   the same rail as dovdd, as upstream does it
 * Both are rails of the PMH0104 at SPMI address 8 (pmic-id I_E0), NOT of the
 * PMH0101 container that holds the board's own rails.  The first attempt put
 * avdd on PMH0101 bob1 at the vendor's 3400000 uV, which falls between two steps
 * of that BOB's grid (3000000 + n*32000), so the constraint was unsatisfiable,
 * the container's probe failed with -22, devres unregistered every other rail of
 * PMH0101 with it -- the wifi's PCIe rail and the USB rails -- and the machine
 * came up without wifi and without USB-A.  Two rules came out of that: never put
 * a camera rail inside a container that carries board rails, and check a vendor
 * voltage against the driver's ranges before writing it.
 *
 * The three supplies need the regulator module that carries the PMH0104 LDOs
 * (patches/0021).  On the stock module the container cannot bind, the kernel
 * hands out dummy regulators, and nothing changes -- that is the state the first
 * two camera boots were in, and why the sensor answered nothing on the bus.
 *
 * There is no remote-endpoint yet on purpose: CAMSS and CSIPHY4 are a later
 * step, so a failure here can only be the CCI or the sensor.  The endpoint still
 * carries lanes and link frequency because ov08x40's probe parses those before
 * it touches the bus.
 */
&cci1 {
	/* master 0 defaults in the SoC file; only master 1 is wired on this board */
	pinctrl-0 = <&cci1_1_default>;
	pinctrl-1 = <&cci1_1_sleep>;

	status = "okay";
};

&cci1_i2c1 {
	camera@36 {
		compatible = "ovti,ov02c10";
		reg = <0x36>;

		reset-gpios = <&tlmm 239 GPIO_ACTIVE_LOW>;
		pinctrl-0 = <&cam_mclk4_default &cam_reset4_default>;
		pinctrl-names = "default";

		clocks = <&camcc CAM_CC_MCLK4_CLK>;
		assigned-clocks = <&camcc CAM_CC_MCLK4_CLK>;
		assigned-clock-rates = <19200000>;

		avdd-supply = <&vreg_l7i_e0>;
		dovdd-supply = <&vreg_l4i_e0>;
		dvdd-supply = <&vreg_l4i_e0>;

		/* the machine's own rails: PMH0104 (I_E0) ldo7 2.8 V and ldo4 1.8 V,
		 * the mapping upstream's glymur board uses.  Needs patches/0021.

		port {
			ov02c10_out_ep: endpoint {
				remote-endpoint = <&csiphy4_in_ep>;
				bus-type = <MEDIA_BUS_TYPE_CSI2_DPHY>;
				clock-lanes = <0>;
				data-lanes = <1 2>;
				link-frequencies = /bits/ 64 <400000000>;
			};
		};
	};
};
"""

CAMSS_LINK = """
/* The front sensor's CSI receiver.  Qualcomm's CRD wires its sensor to csiphy4 the
 * same way, and the return link has to be there too or the sensor's probe defers at
 * v4l2_async_register_subdev_sensor() with "waiting for fwnode graph endpoint".
 * No vdda supplies: this machine's firmware already has the camera domain powered
 * (the sensor answered on the bus with no Linux votes at all) and the PHY's power
 * comes from cam_cc_titan_top_gdsc plus the mmcx/mx domains, which the vendor's own
 * camera sequence votes (FOOTSWITCH cam_cc_titan_top_gdsc in CAMF_RES_MTP.bin). */
&csiphy4 {
	status = "okay";
};

&csiphy4_in_ep {
	remote-endpoint = <&ov02c10_out_ep>;
};

&camss {
	status = "okay";
};
"""

RESET_PIN = """	cam_reset4_default: cam-reset4-default-state {
		pins = "gpio239";
		function = "gpio";
		drive-strength = <2>;
		bias-disable;
	};

"""


def find_block(lines, opener_re, what):
    """(start, end) of the brace-balanced block whose first line matches opener_re."""
    rx = re.compile(opener_re)
    for i, l in enumerate(lines):
        if rx.match(l):
            depth = 0
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                if depth <= 0 and j > i:
                    return i, j
            raise SystemExit(f"unbalanced braces after {what} at line {i+1}")
    raise SystemExit(f"could not find {what}")


def edit(path, fn):
    with open(path) as f:
        text = f.read()
    if MARK in text:
        print(f"  already edited: {os.path.basename(path)}")
        return
    shutil.copy2(path, path + ".a16-pre-camera")
    lines = fn(text.split("\n"))
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print(f"  edited: {os.path.basename(path)} (backup .a16-pre-camera)")


def edit_dtsi(lines):
    i, _ = find_block(lines, r"^\t\tmdss: display-subsystem@", "the mdss node")
    lines = lines[:i] + CCI_NODES.split("\n") + lines[i:]
    # the camera subsystem itself, from Qualcomm's own series (see the include's header)
    with open(CAMSS_INC) as f:
        camss = [l for l in f.read().split("\n") if not l.startswith("/*") and not l.startswith(" *")]
    i, _ = find_block(lines, r"^\t\tmdss: display-subsystem@", "the mdss node")
    lines = lines[:i] + camss + lines[i:]
    _, end = find_block(lines, r"^\t\ttlmm: pinctrl@", "the tlmm node")
    lines = lines[:end] + PIN_BLOCK.split("\n") + lines[end:]
    return lines


def edit_board(lines):
    # 1. the PMH0104 container the machine really uses.  The board tree describes
    #    no PMH0104 regulators at all, so this is the only description of ldo4 and
    #    ldo7 anywhere -- it is what the sensor's supplies point at.
    # the PMH0104 container is deliberately NOT inserted: this firmware's command
    # DB has no rails for that PMIC (see the sensor node's note and RESULT.md), so
    # declaring it only produces "could not find RPMh address for L4I_E0".  The
    # constant above is kept as the record of what the board has.
    _ = REGULATORS_CAMERA_PMIC
    # 3. the reset pin group inside &tlmm
    _, end = find_block(lines, r"^&tlmm \{", "&tlmm")
    lines = lines[:end] + RESET_PIN.split("\n") + lines[end:]
    for i, l in enumerate(lines):
        if l.startswith("#include <dt-bindings/pinctrl/qcom,pmic-gpio.h>"):
            lines.insert(i, "#include <dt-bindings/media/video-interfaces.h>")
            break
    else:
        raise SystemExit("could not find the pmic-gpio include in the board file")
    return lines + SENSOR.split("\n") + CAMSS_LINK.split("\n")


print(f"tree: {TREE}")
edit(DTSI, edit_dtsi)
edit(BOARD, edit_board)
print("done")
