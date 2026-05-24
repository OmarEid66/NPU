# nanoNPU: Minimal Systolic Neural Inference Engine for Medical Edge AI

<p align="center">
  <img width="800" height="450" alt="nanoNPU Architecture Render" src="https://github.com/user-attachments/assets/6cb2734c-41af-4814-b1bb-77e2f2706287" />
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License"/></a>
  <img src="https://img.shields.io/badge/Platform-SkyWater_130nm-orange.svg" alt="Platform"/>
  <img src="https://img.shields.io/badge/EDA_Orchestration-LibreLane-darkviolet.svg" alt="Flow"/>
  <img src="https://img.shields.io/badge/Tapeout-Silicon_Proven-red.svg" alt="Status"/>
  <img src="https://img.shields.io/badge/Technology-130nm_CMOS-green.svg" alt="Tech"/>
  <img src="https://img.shields.io/badge/Datatype-INT8_Quantized-yellow.svg" alt="Datatype"/>
</p>

> 🚀 **Status:** Successfully taped out as part of **Silicon Sprint 2026** at the **American University in Cairo (AUC)**. Physical silicon fabrication expected in **November 2026**.
>
> 📊 **Try the Software Model:** [Google Colab Demo](https://colab.research.google.com/drive/1guw0ahCD6iGF00_8kZn-vLknWel7jAV5?usp=sharing)

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [Architecture](#architecture)
  - [Top-Level Block Diagram](#top-level-block-diagram)
  - [Datapath Pipeline](#datapath-pipeline)
  - [Instruction Set Architecture (ISA)](#instruction-set-architecture-isa)
  - [Control Unit FSM](#control-unit-fsm)
  - [GPIO Pin Map (Project Macro)](#gpio-pin-map-project-macro)
- [Physical Design](#physical-design)
- [Application: Chest X-Ray Pneumonia Detection](#application-chest-x-ray-pneumonia-detection)
- [Repository Structure](#repository-structure)
- [Verification](#verification)
  - [Test Suite Overview](#test-suite-overview)
  - [Simulation Results](#simulation-results)
- [Getting Started](#getting-started)
  - [RTL Simulation](#rtl-simulation)
  - [Running the LibreLane Flow](#running-the-librelane-flow)
- [Design Metrics & Signoff](#design-metrics--signoff)
- [Future Work](#future-work)
- [Team](#team)
- [References](#references)

---

## Overview

**nanoNPU** is a highly area-optimized, silicon-proven Neural Processing Unit designed for low-power medical edge inference. It implements a fused-datapath streaming architecture built around an **8×8 systolic array** executing **INT8 quantized** matrix multiplications, enabling dense neural network inference in a tiny silicon footprint on the **SkyWater 130nm open-source PDK**.

Although the primary validation application is **chest X-ray pneumonia classification**, the ISA-driven architecture makes the nanoNPU fully **general-purpose** — any INT8-quantized convolutional or fully-connected neural network can be compiled to it by issuing the appropriate instruction sequence over UART/APB.

<p align="center">
  <img width="592" height="195" alt="Image" src="https://github.com/user-attachments/assets/6a86607e-c77b-45aa-8860-8a440e3a1883" />
</p>

---

## Key Features

| Feature | Detail |
|---|---|
| **Compute Core** | 8×8 Systolic Array (64 MAC units) |
| **Data Precision** | INT8 activations & weights, INT32 accumulators |
| **Memory** | 128×32 dual-port SRAM (data) + 32×32 instruction memory |
| **Host Interface** | UART → APB bus bridge |
| **Post-Processing** | Bias addition, requantization (INT32→INT8), ReLU, Average Pooling |
| **ISA** | Custom 32-bit fixed-width, 12 instructions (team-designed) |
| **Clock** | 20 MHz target (50 ns period) |
| **Technology** | SkyWater SKY130 130nm CMOS |
| **Die Area** | 880 µm × 1031.66 µm |
| **Core Utilization** | 20% |
| **Tapeout Program** | Silicon Sprint 2026, AUC |

---

## Architecture

### Top-Level Block Diagram

<img width="1214" height="526" alt="Image" src="https://github.com/user-attachments/assets/4493a72f-bcf2-4982-a628-729506c8af68" />

<img width="1886" height="891" alt="Image" src="https://github.com/user-attachments/assets/f8b87375-acea-4a00-a7e6-cb41552c289d" />

The nanoNPU is organized around a linear streaming datapath. The host communicates with the chip over a UART link that is bridged to an internal APB bus. An APB decoder fans out to the NPU core, instruction memory, and data SRAM:

```
Host PC
  │
  ▼  (115200 baud UART)
UART–APB Bridge
  │
  ▼
APB Splitter / NPU APB Decoder
  │
  ├──► Instruction Memory (IMEM)   32 × 32-bit
  ├──► Data SRAM (DMEM)           128 × 32-bit (dual-port)
  └──► NPU Core (npu_top)
         │
         └──► Control Unit (CU)
               │
               ├──► ACT Ping-Pong Buffer ──────────┐
               ├──► WGT Ping-Pong Buffer ──────────┤
               │                                    ▼
               │                          Systolic Array 8×8
               │                                    │
               │                            acc_buffer (INT32)
               │                                    │
               ├──► Bias Buffer ──────► Bias Adder ─┤
               │                                    │
               ├──► Scale Register ──► Req Unit ────┤   (INT32→INT8)
               │                                    │
               │                           ReLU Unit
               │                                    │
               └──► Store Engine ◄──────────────────┘
                         │
                         ▼
                      Data SRAM
```

### Datapath Pipeline

The nanoNPU uses a **fused streaming datapath** to keep on-chip buffer requirements minimal. Intermediate results never return to main SRAM between pipeline stages — they flow directly through dedicated small buffers:

```
SRAM ──[LOAD_ACT]──► ACT Ping-Pong Buffer ─┐
                                             ├──► Systolic Array (8×8 MACs)
SRAM ──[LOAD_WGT]──► WGT Ping-Pong Buffer ─┘
                                             │
                                             ▼
                                       acc_buffer  (INT32, 8 rows)
                                             │
SRAM ──[LOAD_BIAS]──► bias_buffer ──► Bias Adder
                                             │
                                       pbias_buffer (INT32+bias)
                                             │
SRAM ──[LOAD_SCL]──► scale_reg ───► Req Unit  (×M0 >> n, INT8)
                                             │
                                       preq_buffer (INT8)
                                             │
                                        [ReLU] max(0, x)
                                             │
                                       relu_buffer (INT8)
                                             │
                                    ─[STORE]──► SRAM
```

**Ping-Pong Buffers** enable the CU to load the next tile from SRAM while the systolic array consumes the current tile, hiding SRAM latency behind computation.

### Instruction Set Architecture (ISA)

> ✍️ The nanoNPU ISA — including all opcodes, instruction formats, and encoding — was **fully designed from scratch by the team**.

All NPU operations are encoded in a **32-bit fixed-width instruction** format. Two instruction layouts exist:

**LOAD / STORE format:**
```
 [31:26]   [26:22]   [21:16]   [15:8]         [7:0]
 OP CODE   buf_sel   EXT_ADDR  TILE_ADDR B     TILE_ADDR A
  6 bits   5 bits    6 bits     8 bits           8 bits
```

**CONV / BIAS / REQ / ReLU / POOL format:**
```
 [31:26]   [25:6]     [5]          [6:1]      [0]
 OP CODE   RESERVED   w_transpose  n_scale    BIAS_bypass
  6 bits   20 bits     1 bit        6 bits      1 bit
```

The full instruction set:

| Instruction | OP Code | Operation |
|---|---|---|
| `LOAD_ACT` | `000000` | SRAM[tile] → Activation Ping-Pong Buffer |
| `LOAD_WGT` | `000001` | SRAM[tile] → Weight Ping-Pong Buffer |
| `LOAD_BIAS` | `000010` | SRAM[tile] → Bias Buffer |
| `LOAD_SCL` | `000011` | SRAM[tile] → Scale Register (M0, n) |
| `CONV` | `000100` | Act × Wgt → AccBuffer (8×8 MAC) |
| `ADD_BIAS` | `000101` | AccBuffer + BiasBuffer → PBBuffer |
| `REQ` | `000110` | PBBuffer × M0 >> n → ReqBuffer (INT8) |
| `ReLU` | `000111` | ReqBuffer max(0,x) → ReLUBuffer |
| `POOL` | `001000` | ReLUBuffer 2×2 MaxPool → PoolBuffer |
| `STORE` | `001001` | LastActiveBuffer → SRAM[tile] |
| `LOAD_ACT_WGT` | `010000` | SRAM → Act Ping-Pong + Wgt Ping-Pong (simultaneous) |
| `NOP` | `111110` | No operation, one cycle |
| `HALT` | `111111` | Stop; assert `npu_done` |

### Control Unit FSM

The Control Unit (`CU.sv`) implements a **three-level FSM hierarchy** — a main pipeline FSM, a CONV sub-FSM, and two additional sub-FSMs for REQ and ReLU sequencing.

#### Main Pipeline FSM

```
                    ┌─────────────────────────────────────────────────────┐
                    │                   start = 0 (STALL)                 │
                    ▼                                                      │
  rst_n ──► IDLE ──[start]──► FETCH ──► STALL ──► DECODE ──► EXECUTE ──► NEXT
                                 ▲                               │
                                 │        unit_done = 1          │
                                 └───────────────────────────────┘
                                                  │
                                            [opcode=HALT]
                                                  ▼
                                               HALTED
                                          (npu_done = 1)
```

| State | Action |
|---|---|
| `IDLE` | Wait for `start` pulse from host |
| `FETCH` | Assert `inst_rd_en`, issue PC to IMEM |
| `STALL` | Latch instruction word into `instr_r` (1-cycle SRAM latency) |
| `DECODE` | Decode opcode/fields; generate `exec_pulse` on exit |
| `EXECUTE` | Drive the active functional unit; hold until `unit_done` |
| `NEXT` | Increment PC, swap ping-pong buffers if needed → back to FETCH |
| `HALTED` | Assert `npu_done`; stay until reset |

#### CONV Sub-FSM (Systolic Array Control)

```
  [opcode=CONV & EXECUTE]
         │
         ▼
     CP_IDLE ──► CP_START ──► CP_LOAD_W ──────────────────► CP_FEED_A ──────────────► CP_WAIT
                               │  count cols 0…N-1           │  count rows 0…N-1        │
                               │  sa_valid_in = 1            │  sa_valid_in = 1          │
                               │  (load weights)             │  (stream activations)     │
                               └──[cnt == N-1]───────────────┘                           │
                                                                               [sa_done]─┘
                                                                                    │
                                                                               CP_IDLE
```

#### REQ Sub-FSM (Requantization Sequencing)

```
  [opcode=REQ & EXECUTE]
         │
         ▼
  RQ_IDLE ──► RQ_PULSE ──────────────► RQ_WAIT ──[req_done]──► RQ_IDLE
               │  req_start pulses      │
               │  for SA_SIZE rows      │
               └──[cnt == SA_SIZE-1]────┘
```

#### ReLU Sub-FSM

```
  [opcode=RELU & EXECUTE]
         │
         ▼
  RP_IDLE ──► RP_PULSE ──────────────► RP_WAIT ──[relu_done]──► RP_IDLE
               │  relu_start pulses     │
               │  for SA_SIZE rows      │
               └──[cnt == SA_SIZE-1]────┘
```

---

## GPIO Pin Map (Project Macro)

The nanoNPU is wrapped inside `npu_project_macro.sv`, which fits the **OpenFrame multi-project chip** port convention. All host communication happens through **5 active GPIO pins** on the bottom pads. All other GPIOs are tied to safe high-Z inputs.

### Active Pin Assignment

| GPIO Pin | Direction | Signal | Description |
|---|---|---|---|
| `gpio_bot[0]` | **IN** | `uart_rx` | Host → NPU UART receive |
| `gpio_bot[1]` | **OUT** | `uart_tx` | NPU → Host UART transmit |
| `gpio_bot[2]` | **OUT** | `locked` | APB bus lock status |
| `gpio_bot[3]` | **OUT** | `npu_done` | NPU reached `HALT` instruction |
| `gpio_bot[4]` | **OUT** | `done_processing` | All instructions processed |
| `gpio_bot[14:5]` | — | *unused* | High-Z (safe input, no pull) |
| `gpio_rt[8:0]` | — | *unused* | High-Z (safe input, no pull) |
| `gpio_top[13:0]` | — | *unused* | High-Z (safe input, no pull) |

### Drive Mode Encoding (SKY130 OpenFrame)

| Pin | `oeb` | `dm[2:0]` | Mode |
|---|---|---|---|
| `BOT[0]` uart_rx | `1` | `3'b001` | Input, no pull |
| `BOT[1]` uart_tx | `0` | `3'b110` | Strong push-pull output |
| `BOT[2]` locked | `0` | `3'b110` | Strong push-pull output |
| `BOT[3]` npu_done | `0` | `3'b110` | Strong push-pull output |
| `BOT[4]` done_processing | `0` | `3'b110` | Strong push-pull output |
| All others | `1` | `3'b001` | High-Z input, no pull |

### Clock & Reset

| Signal | Source | Notes |
|---|---|---|
| `clk` | `proj_clk_out` from green macro | Gated system clock via ICG cell |
| `reset_n` | `proj_reset_n_out` from green macro | Held LOW when scan slot is disabled |
| `por_n` | Power-on reset | Unused by NPU directly |

### Pin Order Configuration (`pin_order.cfg`)

The `pin_order.cfg` file constrains LibreLane's I/O placer to distribute the GPIO bundles around the four die edges, matching the OpenFrame multi-project chip physical contract:

| Die Edge | GPIO Group | Count |
|---|---|---|
| **West** | `clk`, `reset_n`, `por_n` | 3 |
| **South** | `gpio_bot[14:0]` + drive modes | 15 signal + 45 DM |
| **East** | `gpio_rt[8:0]` + drive modes | 9 signal + 27 DM |
| **North** | `gpio_top[13:0]` + drive modes | 14 signal + 42 DM |

---

## Physical Design

The full RTL-to-GDSII flow was executed using **[LibreLane](https://librelane.readthedocs.io)** — the open-source RTL-to-GDSII orchestration framework — targeting the **SkyWater SKY130 HD standard cell library**. The flow was carried out as part of the **Silicon Sprint 2026** workshop at AUC.

<img width="800" height="229" alt="Image" src="https://github.com/user-attachments/assets/e828a02e-ff73-49d9-9c82-ce125cd31c21" />

### Flow Overview

The LibreLane Classic flow was divided into two phases:

| Phase | Steps | Purpose |
|---|---|---|
| **Signoff Prep** | Fill insertion → RCX → Post-PnR STA → IR Drop | Electrical & timing verification |
| **Physical Signoff** | GDSII → DRC → LVS → XOR | Geometric & connectivity verification |

### Layout
<img width="661" height="759" alt="Image" src="https://github.com/user-attachments/assets/fb587a36-07ea-4478-9039-d506feadaec0" />

### Placement Density
<img width="662" height="758" alt="Image" src="https://github.com/user-attachments/assets/3a58ab32-51ce-49c7-a4b0-6c9dc76578d7" />

### Routing Congestion
<img width="679" height="768" alt="Image" src="https://github.com/user-attachments/assets/2ece5a96-b18f-4e3c-8e56-48b8f4b248c2" />

### Flow Configuration Highlights (`config.json`)

| Parameter | Value | Notes |
|---|---|---|
| Clock Period | 50 ns | 20 MHz |
| Die Area | 880 × 1031.66 µm | Fixed by multi-project chip contract |
| Core Utilization | 20% | Area-optimized |
| Synthesis Strategy | `AREA 2` | Minimize cell count |
| Default Corner | `max_ss_100C_1v60` | SS, 100°C, 1.6 V |
| Max Metal Layer | `met4` | Routing constraint |
| Antenna Repair Iterations | 15 | Aggressive antenna mitigation |
| Post-GRT Design Repair | Enabled | Slew/cap fix after global routing |

### Parasitic Extraction & Multi-Corner STA

After detailed routing, **OpenRCX** extracted RC parasitics from the physical geometry into three SPEF files (max/nom/min corners). Post-PnR STA then analysed all **9 PVT corners**:

```
max_ss_100C_1v60    nom_ss_100C_1v60    min_ss_100C_1v60
max_tt_025C_1v80    nom_tt_025C_1v80    min_tt_025C_1v80
max_ff_n40C_1v95    nom_ff_n40C_1v95    min_ff_n40C_1v95
```

### ECO Buffer Insertion

The initial post-route STA revealed **Max Slew and Max Cap violations** in the `max_ss_100C_1v60` corner caused by overloaded driver outputs driving long nets. These were resolved using a **Side Load Isolation ECO** — `sky130_fd_sc_hd__buf_4` cells were inserted after overloaded drivers via the `INSERT_ECO_BUFFERS` flow in `config.json`, absorbing the excessive capacitive load without disturbing the rest of the routed design. The ECO run started from the post-detailed-routing checkpoint, re-routed only the affected nets, then re-ran the full signoff prep to verify the fix.

### Signoff Summary

Post-route signoff was performed at the worst-case slow corner (`max_ss_100C_1v60`). Full STA reports, DRC/LVS sign-off logs, and SPEF parasitic files are available in `Final/`.

<img width="890" height="1042" alt="Image" src="https://github.com/user-attachments/assets/79c7e749-01a3-480e-8a44-70f413f2517c" />

| Check | Result | Detail |
|---|---|---|
| Setup Timing | ✅ Clean | Zero violations |
| Hold Timing | ✅ Clean | Zero violations |
| IR Drop (VPWR) | ✅ 0.05% | Well within < 2% signoff budget |
| IR Drop (VGND) | ✅ 0.05% | Well within < 2% signoff budget |
| DRC | ✅ 0 violations | SkyWater 130nm rule deck — Magic & KLayout |
| LVS | ✅ Circuits match uniquely | Physical layout ≡ synthesis netlist |
| XOR GDS | ✅ 0 differences | Magic vs. KLayout GDS agree exactly |

---

## Application: Chest X-Ray Pneumonia Detection

The primary validation use case for nanoNPU is a **binary CNN classifier** distinguishing normal chest X-rays from pneumonia cases, derived from the publicly available Guangzhou Women and Children's Medical Center dataset.

### Dataset

| Property | Detail |
|---|---|
| **Source** | Guangzhou Women and Children's Medical Center |
| **Images** | 5,863 JPEG chest X-rays (anterior-posterior) |
| **Classes** | `NORMAL` / `PNEUMONIA` |
| **Splits** | Train / Validation / Test |
| **Patient Age** | 1–5 years |
| **License** | CC BY 4.0 |
| **Citation** | [Cell 2018 — Identifying Medical Diagnoses and Treatable Diseases by Image-Based Deep Learning](http://www.cell.com/cell/fulltext/S0092-8674(18)30154-5) |

### CNN Software Model

A bit-accurate Python model of the inference pipeline (including INT8 quantization) is provided under `Python Modeling/` and runnable directly in the browser:

👉 [**Open in Google Colab**](https://colab.research.google.com/drive/1guw0ahCD6iGF00_8kZn-vLknWel7jAV5?usp=sharing)

<img width="684" height="520" alt="Image" src="https://github.com/user-attachments/assets/cd987e77-f8b3-4c2e-87d9-dfd1635d449d" />

The notebook (`Chest_X_Ray_Images_CNN.ipynb`) covers:
- Data loading & preprocessing
- CNN architecture definition
- INT8 quantization-aware training
- Weight export in a format compatible with the NPU's SRAM layout

---

## Repository Structure

```text
├── Backend/                      # Physical design configurations & flow scripts
│   └── openlane/                 # Winning run configuration
│       ├── RTL/                  # Flattened SystemVerilog for synthesis
│       ├── config.json           # LibreLane parameters (clock, area, antenna rules)
│       ├── pnr.sdc               # Place-and-route timing constraints
│       ├── signoff.sdc           # Final signoff timing constraints
│       └── fixed_dont_change/    # Fixed DEF template (multi-project contract)
│
├── Final/                        # Post-route tapeout deliverables
│   ├── final/
│   │   ├── gds/                  # npu_project_macro.gds  ← manufacturing-ready
│   │   ├── lef/                  # Macro abstract view
│   │   ├── spef/                 # Multi-corner parasitics (max/min/nom)
│   │   ├── lib/                  # Timing libraries (9 PVT corners)
│   │   ├── sdf/                  # SDF for back-annotated simulation
│   │   └── render/               # GDS layout render PNG
│   └── max_ss_100C_1v60/         # Worst-case corner STA & power reports
│
├── FPGA/                         # XDC constraints for FPGA prototype
│
├── Python Modeling/
│   ├── npu_modeling.py           # Bit-accurate NPU software model
│   └── Uart APB/uart_apb.py     # UART–APB host-side script
│
├── RTL/                          # RTL source organized by functional unit
│   ├── npu_system_top.sv         # System top (UART + APB + NPU)
│   ├── npu_top.sv                # NPU core top
│   ├── Npu_apb_decoder.sv        # APB address decoder
│   ├── Systolic Array/           # PE.sv, SA_NxN.sv, SA_NxN_top.sv, …
│   ├── Control Unit/             # CU.SV, SA_CU.sv
│   ├── Clock_Gating_Cell/        # ICG cell for low-power clock gating
│   ├── Buffers/                  # Ping-pong, bias, acc, relu, preq buffers
│   ├── ReLU/                     # relu_unit.sv, ReLU.sv
│   ├── Bias_Adding_Unit/         # bias_adder.sv
│   ├── Store_Engine/             # store_engine.sv
│   ├── SRAM/                     # RAM models (64×32, 128×32, 256×32)
│   ├── Req/                      # Requantization unit
│   ├── MUX/                      # mux2x1.sv, mux4x1.sv
│   └── UART APB/                 # UART + APB master/splitter
│
└── Testbench/
    ├── tb_npu_system.sv          # Full-system testbench
    ├── tb_npu_system_4x4.sv      # 4×4 configuration testbench
    ├── tb_npu_top.sv             # NPU core testbench
    ├── do_npu.do                 # ModelSim/QuestaSim do-file
    └── Components Testing/       # Unit-level testbenches (PE, SA, ReLU, REQ, …)
```

---

## Verification

### Test Suite Overview

The full verification suite is located in `Testbench/` and was run using **QuestaSim / ModelSim**. It consists of a system-level randomized testbench (`tb_npu_system.sv`) that drives the complete hardware stack end-to-end — from UART bytes in, through the APB bus, all the way to SRAM readback — and compares every output byte against a built-in cycle-accurate golden model.

#### How It Works

The testbench (`tb_npu_system.sv`) instantiates the full `npu_system_top` DUT and drives it entirely through bit-banged UART transactions, exactly as a real host would:

1. **APB write tasks** — serialise address + data into UART frames using the `0xDEADA5` write magic header
2. **APB read tasks** — issue reads using the `0xDEAD5A` read magic header and capture the 4-byte response
3. **Memory loaders** — pack 8-bit tile data into 32-bit SRAM words and write them row by row
4. **Instruction programmer** — encodes and writes all ISA instructions (LOAD_ACT, LOAD_WGT, LOAD_BIAS, LOAD_SCL, CONV, ADD_BIAS, REQ, ReLU, NOP, STORE, HALT) into instruction memory via APB
5. **Golden model** — a SystemVerilog function computes the expected INT8 output for every output cell:
   - Matrix multiply (INT8 × INT8 → INT32 accumulate)
   - Bias addition (INT32 + INT32)
   - Requantization: `(acc × M0) >> n` with INT8 saturation clamp (−128 … +127)
   - Optional ReLU: `max(0, x)`
6. **Checker** — reads back every output row from SRAM and compares against the golden model, printing PASS/FAIL per row word

#### Test Cases

| TC | Name | Activations | Weights | Bias | ReLU | Shift |
|---|---|---|---|---|---|---|
| **TC1** | Full Pipeline — Mixed Random | Rand −20 … +20 | Rand −20 … +20 | Rand −500 … +500 | ✅ Yes | 2 |
| **TC2** | No ReLU — Mixed Random | Rand −50 … +50 | Rand −50 … +50 | Rand −1000 … +1000 | ❌ No | 4 |
| **TC3** | Positive Data Only | Rand 1 … +30 | Rand 1 … +30 | Rand 0 … +1000 | ❌ No | 3 |
| **TC4** | Negative Clamping — Extreme Bias | Rand −10 … +10 | Rand −10 … +10 | Rand −8000 … +8000 | ✅ Yes | 0 |

Each test case resets the chip, loads randomised data into SRAM via UART, programs the full instruction sequence, starts the NPU, polls for `npu_done`, then reads back all 16 output words (8 rows × 2 words) and checks them against the golden model. All data is re-randomised each run using `$urandom_range`, so every simulation run is a unique test vector.

### Simulation Results

<img width="637" height="320" alt="Image" src="https://github.com/user-attachments/assets/525bf63b-cdf4-4f4d-b8a9-81258e28663f" />

All 4 test cases passed in QuestaSim with **64/64 output word comparisons correct** across every run:

```
============================================================
  STARTING RANDOMIZED SYSTEM TESTS
============================================================

[TC1] Full Pipeline (Mixed Random Data + RELU)
[TC2] No ReLU Pipeline (Mixed Random Data)
[TC3] Positive Data Only (No ReLU)
[TC4] Negative Clamping Test (Mixed Data + RELU)

============================================================
  FINAL RESULTS: 64 PASSED, 0 FAILED
  *** SUCCESS: ALL RANDOMIZED TESTS PASSED ***
============================================================
```

---

## Getting Started

### Prerequisites

- **RTL Simulation:** ModelSim / QuestaSim / Icarus Verilog / Verilator
- **Physical Design:** [LibreLane](https://librelane.readthedocs.io) with SkyWater 130nm PDK (installed via Nix)
- **Python Modeling:** Python 3.9+, TensorFlow/PyTorch, NumPy, pyserial

### RTL Simulation

```bash
# Run the full randomized system testbench (TC1–TC4) in QuestaSim
vsim -voptargs=+acc work.tb_npu_system
run -all

# Or using the provided do-file
vsim -do do_npu.do

# Individual unit tests
vsim -sv work.PE_tb
vsim -sv work.SA_NxN_top_tb
vsim -sv work.ReLU_TB
```

See the [Verification](#verification) section for a full description of each test case.

### Running the LibreLane Flow

First, enter the Nix shell:

```bash
nix-shell --pure ~/librelane/shell.nix
```

**Full flow (synthesis through signoff):**

```bash
cd Backend/openlane
librelane config.json --run-tag npu_run
```

**Signoff prep only (fill → RCX → STA → IR drop):**

```bash
librelane config.json \
    --run-tag npu_run \
    --from OpenROAD.FillInsertion \
    --to OpenROAD.IRDropReport \
    --with-initial-state runs/npu_run/<step>-checker-wirelength/state_out.json
```

**ECO re-run (insert ECO buffers, re-route, re-signoff):**

```bash
librelane config.json \
    --run-tag npu_run_eco \
    --from Odb.InsertECOBuffers \
    --to OpenROAD.IRDropReport \
    --with-initial-state runs/npu_run/<step>-openroad-detailedrouting/state_out.json
```

**Physical signoff (GDSII → DRC → LVS):**

```bash
librelane config.json \
    --run-tag npu_run_eco \
    --from Magic.StreamOut \
    --with-initial-state runs/npu_run_eco/<step>-openroad-irdropreport/state_out.json
```

The `config.json` already contains all optimized parameters from the successful tapeout run, including `INSERT_ECO_BUFFERS` entries and antenna repair settings — it is a drop-in ready configuration.

### Host Communication (UART–APB)

```bash
# Load weights and run inference on connected hardware
python "Python Modeling/Uart APB/uart_apb.py" \
    --port /dev/ttyUSB0 \
    --baud 115200 \
    --model weights_int8.npy
```

---

## Design Metrics & Signoff

All signoff artifacts are under `Final/`. Key results at worst-case corner (`max_ss_100C_1v60`):

| Metric | Value |
|---|---|
| Technology | SkyWater SKY130 130nm |
| Die Area | 880 × 1031.66 µm |
| Clock Frequency | 20 MHz |
| Setup WNS (worst corner) | +0.0952 ns |
| Hold WNS (worst corner) | +9.0258 ns |
| IR Drop VPWR / VGND | 0.05% / 0.05% |
| DRC | ✅ 0 violations |
| LVS | ✅ Circuits match uniquely |
| XOR GDS | ✅ 0 differences |

Full reports: `Final/drc.magic.rpt`, `Final/lvs.netgen.rpt`, `Final/sta_summary.rpt`.

---

## Future Work

The nanoNPU is a working silicon-proven baseline. The following roadmap outlines planned and suggested improvements:

### 1. Complete Pooling Unit
The `POOL` opcode is defined in the ISA but the hardware pooling unit is not yet implemented in the datapath. Planned additions:
- **Max Pooling** — 2×2 sliding window, stride 2 (already partially handled in the ISA encoding)
- **Average Pooling** — 2×2 sum-and-shift, required for MobileNet-style global average pool layers before the final classifier

### 2. Extended Instruction Set
The 6-bit opcode field has room for 52 additional instructions. Suggested additions:

**Memory & Compute:**

| Proposed Instruction | OP Code | Operation |
|---|---|---|
| `LOAD_ACT_WGT_BIAS` | `010001` | Load activations, weights, and bias in one pass |
| `CONV_BIAS_REQ` | `010010` | Fused CONV + ADD_BIAS + REQ in a single instruction |
| `DEPTHWISE_CONV` | `010011` | Depthwise separable convolution (MobileNet layer) |
| `TRANSPOSE` | `010110` | In-place tile transpose for weight reuse |
| `ZERO_PAD` | `010111` | Zero-pad activation tile edges for convolution |
| `LOOP` | `011000` | Repeat next N instructions K times (software loop) |

**Activation Functions:**

| Proposed Instruction | OP Code | Operation |
|---|---|---|
| `LEAKY_RELU` | `010100` | `max(αx, x)` — α stored in scale reg |
| `CLIP` | `010101` | Clamp to `[min, max]` range (ReLU6 etc.) |
| `SIGMOID` | `011001` | `1 / (1 + e^−x)` — INT8 LUT approximation |
| `SOFTMAX` | `011010` | `e^xᵢ / Σe^xⱼ` over output tile — classification final layer |
| `SWISH` | `011011` | `x · sigmoid(x)` — used in EfficientNet / MobileNetV3 |
| `GELU` | `011100` | `x · Φ(x)` — used in BERT, GPT, ViT transformer blocks |
| `HARD_SWISH` | `011101` | `x · ReLU6(x+3) / 6` — hardware-friendly Swish approximation |
| `ELU` | `011110` | `x if x > 0 else α(e^x − 1)` — α stored in scale reg |

> 💡 Non-linear activations (Sigmoid, Softmax, Swish, GELU) are expensive to compute exactly in fixed-point hardware. The practical implementation strategy is a **256-entry INT8 lookup table (LUT)** stored in a dedicated SRAM tile — the input byte is used as the address and the output byte is the pre-computed activation value. This keeps the hardware simple (one SRAM read per element) while supporting any smooth activation function at the cost of a small SRAM tile.


### 3. Low-Power Design
A clock gating cell (`Clk_Gating_Cell`) is already present in the RTL ([`RTL/Clock_Gating_Cell`](https://github.com/Ammar-Wahidi/NPU/tree/main/RTL/Clock_Gating_Cell)) but not yet integrated into the datapath. Planned techniques:
- **Fine-grained clock gating** — gate each functional unit (SA, bias adder, req unit, ReLU) independently when idle using the existing ICG cell
- **Operand isolation** — insert isolation cells on datapath inputs when a unit is clock-gated to prevent spurious switching power
- **Multi-voltage islands** — run the SRAM and I/O ring at a lower supply voltage than the compute core
- **Power gating** — use header/footer cells to fully cut power to idle units between inference runs

### 4. Assembler & Compiler Toolchain
Currently, NPU programs are hand-assembled by encoding binary instruction words manually in the Python host script. A proper toolchain would include:
- **Assembler** — text `LOAD_ACT 0x00 0x10` → 32-bit binary, with label support and a symbol table
- **Linker** — resolve tile address references and SRAM memory map automatically
- **Compiler backend** — accept a quantized ONNX model and emit a `.npu` binary: tile the weight matrices, generate the LOAD/CONV/BIAS/REQ/RELU/STORE instruction sequence automatically, and pack weights into the SRAM binary image

### 5. Larger Systolic Array — 16×16
Scaling the systolic array from 8×8 to 16×16 increases peak compute from **128 INT8 MACs/cycle** to **512 INT8 MACs/cycle** (4×), enabling faster inference on larger CNN layers. Required changes:
- Widen ping-pong buffers from 8 rows to 16 rows
- Increase SRAM depth to accommodate 16-row tiles
- Widen the `n_scale` field in the CONV instruction format (currently 5 bits, supports up to shift-31)
- Re-run floorplanning and P&R — die area will grow significantly at 20% utilization on SKY130
- 
### 6. Floating-Point NPU Variant
The current nanoNPU is fully INT8 — all activations, weights, and accumulations are fixed-point integers, which requires the model to be quantized before deployment. A natural evolution is a **floating-point NPU** that can run any standard FP32 or FP16 inference model directly without any quantization step:

- **FP16 (IEEE 754 half-precision)** — the practical target for edge silicon; FP16 MACs are ~4× the area of INT8 MACs but eliminate all quantization error and model-preparation overhead. FP16 is the standard for embedded GPU inference (e.g. ARM Mali, Apple Neural Engine)
- **BF16 (Brain Float 16)** — same 8-bit exponent as FP32, 7-bit mantissa; better dynamic range than FP16 at identical hardware cost. Used in Google TPUs and most modern AI accelerators
- **FP32 (full precision)** — highest accuracy, largest area; suitable for training accelerators or high-accuracy medical inference where quantization error is unacceptable
- **Mixed-precision** — FP16 activations with FP32 accumulators (the standard in modern GPU tensor cores), giving full numerical stability without full FP32 memory bandwidth

Key hardware changes required:
- Replace the INT8 PE multiplier with an IEEE 754 FP16/BF16 multiply-add unit
- Replace the INT32 accumulator with an FP32 accumulator to avoid catastrophic cancellation
- Remove the requantization unit (REQ instruction becomes unnecessary)
- Widen the SRAM datapath from 8-bit to 16-bit per element (doubles memory bandwidth requirement)
- Add a FP-to-INT8 conversion unit at the output for systems that mix FP inference with INT8 I/O

> 💡 A pragmatic intermediate step is **posit arithmetic** (Type III unum) — an alternative floating-point format that delivers FP32-equivalent accuracy in 16 bits with simpler hardware than IEEE 754, and is gaining traction in neuromorphic and edge-AI ASIC research.

### 7. Additional Suggestions
- **Batch normalization folding** — fold BN parameters into the bias and scale registers at compile time, eliminating the need for a separate BN layer in hardware
- **Sparse weight skipping** — add a zero-detector in the systolic array PE to skip MAC operations when the weight is zero, reducing dynamic power on pruned models
- **On-chip DMA** — replace the UART-driven APB loader with a DMA engine that bursts weights from an external SPI flash, enabling standalone inference without a host PC
- **RISC-V integration** — replace the custom ISA CU with a small RISC-V core (e.g. PicoRV32) running firmware, using the systolic array as a memory-mapped accelerator
- **Multi-chip tiling** — add an inter-chip link to chain multiple nanoNPU dies together for larger model inference across chips

---

## Team

### RTL-to-GDSII

| Name | GitHub |
|---|---|
| Ammar Wahidi | [@Ammar-Wahidi](https://github.com/Ammar-Wahidi) |
| Omar Mohamed Eid | [@OmarEid66](https://github.com/OmarEid66) |
| Mohamed Ahmed | [@mhmd-ahmdezz](https://github.com/mhmd-ahmdezz) |

### Software Model (CNN Application, Training & Inference)

| Name | Role | GitHub |
|---|---|---|
| Amr Wahidi | CNN model, training & inference | [@amr10w](https://github.com/amr10w) |
| Ammar Wahidi | INT8 quantization | [@Ammar-Wahidi](https://github.com/Ammar-Wahidi) |

---

## References

### Inspired By

- **Intel FPGA-NPU** — High-performance NPU reference architecture on FPGA
  [https://github.com/intel/fpga-npu](https://github.com/intel/fpga-npu)

- **Superscalar Out-of-Order NPU on FPGA** — Yuqiang Ge, Kapinesh Govindaraju, Sona Susan Jacob (ECE5760, Cornell University, Spring 2024)
  [https://people.ece.cornell.edu/land/courses/ece5760/FinalProjects/s2024/yg585_kg534_sj778/](https://people.ece.cornell.edu/land/courses/ece5760/FinalProjects/s2024/yg585_kg534_sj778/yg585_kg534_sj778/yg585_kg534_sj778.html)

- **UART-APB** — Dr. Mohamed Shalan (American University in Cairo)
  [https://github.com/shalan](https://github.com/shalan)

### Dataset

- Kermany, D. et al. (2018). *Identifying Medical Diagnoses and Treatable Diseases by Image-Based Deep Learning.* Cell, 172(5), 1122–1131.
  [https://doi.org/10.1016/j.cell.2018.02.010](http://www.cell.com/cell/fulltext/S0092-8674(18)30154-5)
  Dataset: [https://data.mendeley.com/datasets/rscbjbr9sj/2](https://data.mendeley.com/datasets/rscbjbr9sj/2) — CC BY 4.0

- [Chest X-Ray Images (Pneumonia) — Kaggle](https://www.kaggle.com/datasets/paultimothymooney/chest-xray-pneumonia)

### Tools & PDK

- [SkyWater SKY130 PDK](https://github.com/google/skywater-pdk)
- [LibreLane](https://librelane.readthedocs.io) — RTL-to-GDSII orchestration framework
- [OpenROAD](https://github.com/The-OpenROAD-Project/OpenROAD) — Placement, CTS, routing, STA
- [Magic VLSI](http://opencircuitdesign.com/magic/) — GDSII stream-out, DRC, SPICE extraction
- [Netgen LVS](http://opencircuitdesign.com/netgen/) — Layout vs. Schematic verification
- [KLayout](https://www.klayout.de/) — GDSII stream-out, DRC, XOR verification
- [OpenRCX](https://github.com/The-OpenROAD-Project/OpenRCX) — Parasitic RC extraction

---

<p align="center">
  Made at the <strong>American University in Cairo</strong> · Silicon Sprint 2026
  <br/>
  Apache 2.0 License — see <a href="LICENSE">LICENSE</a>
</p>
