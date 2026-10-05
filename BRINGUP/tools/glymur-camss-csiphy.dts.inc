/* CAMSS + CSI2 PHY nodes for glymur, verbatim from Qualcomm's upstream series:
 *   [PATCH 1/6] arm64: dts: qcom: glymur: Add CAMSS and CSIPHY nodes
 *   (patchwork 14795778, glymur_camss v1, 2026-09-07)
 * The driver side needs nothing: this kernel's camss already matches
 * "qcom,glymur-camss" (camss.c, x1e80100_resources).  Inserted into
 * glymur.dtsi by a16-camera-dts-edit.py, before the mdss node.
 */
	csiphy_mxc_opp_table: opp-table-mxc {
		compatible = "operating-points-v2";

		opp-300000000 {
			opp-hz = /bits/ 64 <300000000>;
			required-opps = <&rpmhpd_opp_low_svs_d1>,
					<&rpmhpd_opp_low_svs_d1>;
		};

		opp-400000000 {
			opp-hz = /bits/ 64 <400000000>;
			required-opps = <&rpmhpd_opp_low_svs>,
					<&rpmhpd_opp_low_svs>;
		};

		opp-480000000 {
			opp-hz = /bits/ 64 <480000000>;
			required-opps = <&rpmhpd_opp_low_svs>,
					<&rpmhpd_opp_low_svs>;
		};
	};

	csiphy_mxa_opp_table: opp-table-mxa {
		compatible = "operating-points-v2";

		opp-300000000 {
			opp-hz = /bits/ 64 <300000000>;
			required-opps = <&rpmhpd_opp_low_svs_d1>,
					<&rpmhpd_opp_low_svs_d1>;
		};

		opp-400000000 {
			opp-hz = /bits/ 64 <400000000>;
			required-opps = <&rpmhpd_opp_low_svs>,
					<&rpmhpd_opp_low_svs_d1>;
		};

		opp-480000000 {
			opp-hz = /bits/ 64 <480000000>;
			required-opps = <&rpmhpd_opp_low_svs>,
					<&rpmhpd_opp_low_svs_d1>;
		};
	};

		camss: isp@acb6000 {
			compatible = "qcom,glymur-camss";

			reg = <0x0 0x0acb6000 0x0 0x1000>,
			      <0x0 0x0acb7000 0x0 0x2000>,
			      <0x0 0x0acb9000 0x0 0x2000>,
			      <0x0 0x0acbb000 0x0 0x2000>,
			      <0x0 0x0acc6000 0x0 0x1000>,
			      <0x0 0x0acca000 0x0 0x1000>,
			      <0x0 0x0acf6000 0x0 0x1000>,
			      <0x0 0x0acf7000 0x0 0x1000>,
			      <0x0 0x0acf8000 0x0 0x1000>,
			      <0x0 0x0ac62000 0x0 0xf000>,
			      <0x0 0x0ac71000 0x0 0xf000>,
			      <0x0 0x0acc7000 0x0 0x2000>,
			      <0x0 0x0accb000 0x0 0x2000>;
			reg-names = "csid_wrapper",
				    "csid0",
				    "csid1",
				    "csid2",
				    "csid_lite0",
				    "csid_lite1",
				    "csitpg0",
				    "csitpg1",
				    "csitpg2",
				    "vfe0",
				    "vfe1",
				    "vfe_lite0",
				    "vfe_lite1";

			clocks = <&camcc CAM_CC_CAMNOC_AXI_NRT_CLK>,
				 <&camcc CAM_CC_CAMNOC_AXI_RT_CLK>,
				 <&camcc CAM_CC_CORE_AHB_CLK>,
				 <&camcc CAM_CC_CPAS_AHB_CLK>,
				 <&camcc CAM_CC_CPAS_FAST_AHB_CLK>,
				 <&camcc CAM_CC_CPAS_IFE_0_CLK>,
				 <&camcc CAM_CC_CPAS_IFE_1_CLK>,
				 <&camcc CAM_CC_CPAS_IFE_LITE_CLK>,
				 <&camcc CAM_CC_CSID_CLK>,
				 <&camcc CAM_CC_CSID_CSIPHY_RX_CLK>,
				 <&gcc GCC_CAMERA_HF_AXI_CLK>,
				 <&gcc GCC_CAMERA_SF_AXI_CLK>,
				 <&camcc CAM_CC_IFE_0_CLK>,
				 <&camcc CAM_CC_IFE_0_FAST_AHB_CLK>,
				 <&camcc CAM_CC_IFE_1_CLK>,
				 <&camcc CAM_CC_IFE_1_FAST_AHB_CLK>,
				 <&camcc CAM_CC_IFE_LITE_CLK>,
				 <&camcc CAM_CC_IFE_LITE_AHB_CLK>,
				 <&camcc CAM_CC_IFE_LITE_CPHY_RX_CLK>,
				 <&camcc CAM_CC_IFE_LITE_CSID_CLK>;
			clock-names = "camnoc_nrt_axi",
				      "camnoc_rt_axi",
				      "core_ahb",
				      "cpas_ahb",
				      "cpas_fast_ahb",
				      "cpas_vfe0",
				      "cpas_vfe1",
				      "cpas_vfe_lite",
				      "csid",
				      "csid_csiphy_rx",
				      "gcc_axi_hf",
				      "gcc_axi_sf",
				      "vfe0",
				      "vfe0_fast_ahb",
				      "vfe1",
				      "vfe1_fast_ahb",
				      "vfe_lite",
				      "vfe_lite_ahb",
				      "vfe_lite_cphy_rx",
				      "vfe_lite_csid";

			interrupts = <GIC_SPI 601 IRQ_TYPE_EDGE_RISING>,
				     <GIC_SPI 603 IRQ_TYPE_EDGE_RISING>,
				     <GIC_SPI 431 IRQ_TYPE_EDGE_RISING>,
				     <GIC_SPI 457 IRQ_TYPE_EDGE_RISING>,
				     <GIC_SPI 436 IRQ_TYPE_EDGE_RISING>,
				     <GIC_SPI 270 IRQ_TYPE_EDGE_RISING>,
				     <GIC_SPI 271 IRQ_TYPE_EDGE_RISING>,
				     <GIC_SPI 458 IRQ_TYPE_EDGE_RISING>,
				     <GIC_SPI 860 IRQ_TYPE_EDGE_RISING>;
			interrupt-names = "csid0",
					  "csid1",
					  "csid2",
					  "csid_lite0",
					  "csid_lite1",
					  "vfe0",
					  "vfe1",
					  "vfe_lite0",
					  "vfe_lite1";

			interconnects = <&hsc_noc MASTER_APPSS_PROC QCOM_ICC_TAG_ACTIVE_ONLY
					 &config_noc SLAVE_CAMERA_CFG QCOM_ICC_TAG_ACTIVE_ONLY>,
					<&mmss_noc MASTER_CAMNOC_HF QCOM_ICC_TAG_ALWAYS
					 &mc_virt SLAVE_EBI1 QCOM_ICC_TAG_ALWAYS>,
					<&mmss_noc MASTER_CAMNOC_SF QCOM_ICC_TAG_ALWAYS
					 &mc_virt SLAVE_EBI1 QCOM_ICC_TAG_ALWAYS>,
					<&mmss_noc MASTER_CAMNOC_ICP QCOM_ICC_TAG_ALWAYS
					 &mc_virt SLAVE_EBI1 QCOM_ICC_TAG_ALWAYS>;
			interconnect-names = "ahb",
					     "hf_mnoc",
					     "sf_mnoc",
					     "sf_icp_mnoc";

			iommus = <&apps_smmu 0x800 0x20>;

			power-domains = <&camcc CAM_CC_IFE_0_GDSC>,
					<&camcc CAM_CC_IFE_1_GDSC>,
					<&camcc CAM_CC_TITAN_TOP_GDSC>;
			power-domain-names = "ife0",
					     "ife1",
					     "top";

			status = "disabled";

			ports {
				#address-cells = <1>;
				#size-cells = <0>;

				port@0 {
					reg = <0>;

					camss_csiphy0_inep: endpoint {
						remote-endpoint = <&csiphy0_out_ep>;
					};
				};

				port@1 {
					reg = <1>;

					camss_csiphy1_inep: endpoint {
						remote-endpoint = <&csiphy1_out_ep>;
					};
				};

				port@3 {
					reg = <3>;

					camss_csiphy4_inep: endpoint {
						remote-endpoint = <&csiphy4_out_ep>;
					};
				};
			};
		};

		csiphy0: phy@ace4000 {
			compatible = "qcom,glymur-csi2-phy", "qcom,x1e80100-csi2-phy";
			reg = <0x0 0x0ace4000 0x0 0x2000>;

			clocks = <&camcc CAM_CC_CSIPHY0_CLK>,
				 <&camcc CAM_CC_CSI0PHYTIMER_CLK>,
				 <&camcc CAM_CC_CORE_AHB_CLK>;
			clock-names = "core",
				      "timer",
				      "ahb";

			operating-points-v2 = <&csiphy_mxc_opp_table>;

			interrupts = <GIC_SPI 477 IRQ_TYPE_EDGE_RISING>;

			power-domains = <&camcc CAM_CC_TITAN_TOP_GDSC>,
					<&rpmhpd RPMHPD_MMCX>,
					<&rpmhpd RPMHPD_MXC>;
			power-domain-names = "top",
					     "mmcx",
					     "mx";

			status = "disabled";

			ports {
				#address-cells = <1>;
				#size-cells = <0>;

				port@0 {
					reg = <0>;

					csiphy0_in_ep: endpoint {
					};
				};

				port@1 {
					reg = <1>;

					csiphy0_out_ep: endpoint {
						remote-endpoint = <&camss_csiphy0_inep>;
					};
				};
			};
		};

		csiphy1: phy@ace6000 {
			compatible = "qcom,glymur-csi2-phy", "qcom,x1e80100-csi2-phy";
			reg = <0x0 0x0ace6000 0x0 0x2000>;

			clocks = <&camcc CAM_CC_CSIPHY1_CLK>,
				 <&camcc CAM_CC_CSI1PHYTIMER_CLK>,
				 <&camcc CAM_CC_CORE_AHB_CLK>;
			clock-names = "core",
				      "timer",
				      "ahb";

			operating-points-v2 = <&csiphy_mxc_opp_table>;

			interrupts = <GIC_SPI 478 IRQ_TYPE_EDGE_RISING>;

			power-domains = <&camcc CAM_CC_TITAN_TOP_GDSC>,
					<&rpmhpd RPMHPD_MMCX>,
					<&rpmhpd RPMHPD_MXC>;
			power-domain-names = "top",
					     "mmcx",
					     "mx";

			status = "disabled";

			ports {
				#address-cells = <1>;
				#size-cells = <0>;

				port@0 {
					reg = <0>;

					csiphy1_in_ep: endpoint {
					};
				};

				port@1 {
					reg = <1>;

					csiphy1_out_ep: endpoint {
						remote-endpoint = <&camss_csiphy1_inep>;
					};
				};
			};
		};

		csiphy4: phy@acec000 {
			compatible = "qcom,glymur-csi2-phy", "qcom,x1e80100-csi2-phy";
			reg = <0x0 0x0acec000 0x0 0x2000>;

			clocks = <&camcc CAM_CC_CSIPHY4_CLK>,
				 <&camcc CAM_CC_CSI4PHYTIMER_CLK>,
				 <&camcc CAM_CC_CORE_AHB_CLK>;
			clock-names = "core",
				      "timer",
				      "ahb";

			operating-points-v2 = <&csiphy_mxa_opp_table>;

			interrupts = <GIC_SPI 122 IRQ_TYPE_EDGE_RISING>;

			power-domains = <&camcc CAM_CC_TITAN_TOP_GDSC>,
					<&rpmhpd RPMHPD_MMCX>,
					<&rpmhpd RPMHPD_MX>;
			power-domain-names = "top",
					     "mmcx",
					     "mx";

			status = "disabled";

			ports {
				#address-cells = <1>;
				#size-cells = <0>;

				port@0 {
					reg = <0>;

					csiphy4_in_ep: endpoint {
					};
				};

				port@1 {
					reg = <1>;

					csiphy4_out_ep: endpoint {
						remote-endpoint = <&camss_csiphy4_inep>;
					};
				};
			};
		};

