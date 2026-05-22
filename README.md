# nanoNPU: Minimal Systolic Neural Inference Engine for Medical Edge AI

<p align="center">
  <img width="800" height="450" alt="nanoNPU Architecture Render" src="https://github.com/user-attachments/assets/6cb2734c-41af-4814-b1bb-77e2f2706287" />
</p>

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-SkyWater_130nm-orange.svg)]()
[![Flow](https://img.shields.io/badge/EDA_Orchestration-LibreLane-darkviolet.svg)]()
[![Status](https://img.shields.io/badge/Tapeout-Silicon_Proven-red.svg)]()

**nanoNPU** is a highly area-optimized, Neural Processing Unit tailored for low-power medical edge intelligence, specifically optimized for edge-deployed chest X-ray abnormalities detection. The project features an innovative fused-datapath streaming streaming architecture to minimize on-chip storage overhead and has been successfully pushed through an RTL-to-GDSII flow targeting the **SkyWater 130nm open-source PDK**.

> 🚀 **Status:** Successfully taped out! Physical silicon fabrication is expected in **November 2026**.
> 📊 **Try the Software Model:** [Google Colab Application Link](https://colab.research.google.com/drive/1guw0ahCD6iGF00_8kZn-vLknWel7jAV5?usp=sharing)

---

## 📁 Repository Directory Structure

```text
├── Backend/                 # Physical Design configurations & flow scripts
│   ├── openlane/            # Active OpenLane configurations (Winning Run Configs)
│   │   ├── RTL/             # Unified SystemVerilog datapath code
│   │   └── config.json      # Area-optimized physical design parameters
│   └── Old_openlane/        # Historical/exploration baseline runs
├── Final_Submission/        # Post-Route tapeout deliverables (GDSII, LEF, DEF, SPEF)
│   ├── final/               # Final signoff design artifacts
│   │   ├── gds/             # npu_project_macro.gds (Ready for manufacturing)
│   │   ├── lef/             # Extracted macro Abstract view
│   │   ├── mag/             # Magic Layout database format
│   │   └── spef/            # Parasitic extraction files for multi-corner STA
│   └── max_ss_100C_1v60/    # Worst-case corner timing & power signoff analysis
├── FPGA/                    # Hardware constraints for prototype mapping
├── Python Modeling/         # Bit-accurate software references & UART scripts
├── RTL/                     # Structural SystemVerilog source code organized by unit
└── Testbench/               # Functional verification suite
    └── Components Testing/  # Module-level unit tests (PE, Req, ReLU, buffers)
