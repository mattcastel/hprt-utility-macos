# HPRT Utility for macOS

<p align="center">
  <img src="Support/AppIcon.icns" width="128" height="128" alt="HPRT Utility Icon" />
</p>

<p align="center">
  <strong>A modern, open-source companion and print driver toolkit for HPRT MT800 / MT800Q / MT866 mobile thermal printers on macOS.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-blue?style=flat-square&logo=apple" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Architecture-Universal%20(arm64%20%7C%20x86__64)-success?style=flat-square" alt="Universal" />
  <img src="https://img.shields.io/badge/Swift-5.0%20%2F%20SwiftUI-orange?style=flat-square&logo=swift" alt="Swift 5" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License" />
</p>

---

## Overview

HPRT manufactures popular ultra-portable A4 thermal printers (notably the **MT800**, **MT8003**, **MT800Q**, and **MT866** series). While the hardware is compact and reliable, the official macOS software provided by the manufacturer has remained frozen in time, suffering from several critical architectural limitations on modern macOS releases (macOS 11 Big Sur through macOS 15 Sequoia):

1. **Sealed System Volume Failures**: The official installer attempts to write to `/usr/libexec/cups/filter`, which macOS has permanently protected with the Sealed System Volume (SSV).
2. **Rosetta 2 Dependency**: The official CUPS raster filter (`raster-mt800lzo`) is a legacy `x86_64` binary that will fail if Rosetta 2 is not present on Apple Silicon.
3. **Broken PPD Syntax**: The vendor PPD files declare `*OpenUI *PrintDensity: Boolean`, causing CUPS to reject and silently ignore print density controls (rendering faint or overly dark output).
4. **Fragile Bluetooth Bridge**: The vendor utility (`Driver BT Tool.app`) routes print jobs through an unauthenticated local TCP socket (`127.0.0.1:9101`) over Bluetooth Low Energy instead of leveraging macOS's native RFCOMM/SPP CUPS backend.
5. **No Native Telemetry in CUPS**: CUPS queues are write-only, hiding hardware health, live battery level, and firmware information from standard printer preferences.

**HPRT Utility** fixes every layer of the macOS printing pipeline — from automated driver repair to native direct printing and live hardware telemetry.

---

## Key Features

### 🖨️ Automated Driver Repair & SIP-Friendly Installer
- Installs HPRT drivers into user-writable, non-sealed directories (`/Library/Printers/PPDs` and `/usr/local/libexec/cups/filter`).
- Automatically corrects syntax errors in the PPD (repairing `PrintDensity` enumeration and choice groups).
- Creates clean, functional CUPS queues over USB and Bluetooth.

### 🔋 Live Battery & Firmware Telemetry (HPRT V2 Protocol)
- Integrates the reverse-engineered **HPRT Session V2 Framing Protocol** to query internal controller metrics over bidirectional serial (`/dev/cu.MT800*`), BLE GATT, and local bridge ports:
  - **Battery Percentage (`bat_ratio`)**: Live 0–100% battery gauge with color status indicator.
  - **Battery Voltage (`power_voltage`)**: Real-time voltage in Volts and millivolts.
  - **Firmware Revision (`printer_version`, `printer_second_version`)**: Identifies primary firmware and bootloader revisions.
  - **Hardware Identification (`serial_no`, `printer_model`)**: Extracts model name and factory serial number.

### ⚡ Rosetta-Free Direct Print Engine
- Includes a native Swift rasteriser built with **CoreGraphics** and **PDFKit**.
- Directly renders PDF documents and images into 1-bit packed bitmap dot bands at 300 DPI (2320 dots / ~196 mm printable width).
- Supports both **adaptive thresholding** and **Floyd–Steinberg error diffusion dithering**.
- Emits standard `GS v 0` ESC/POS raster commands straight to the USB raw queue or Bluetooth serial port — **bypassing CUPS filters and Rosetta 2 completely**.

### 🔍 Deep Pipeline Diagnostics & CUPS Inspector
- **End-to-End Health Checks**: Verifies macOS version, Rosetta 2 installation, filter architectures, USB device tree, CUPS queue states, and Bluetooth connection status.
- **Raster Inspector**: Analyzes CUPS raster streams (`v1`, `v2 RLE`, and `v3`), visually previews rendered pages, and calculates dot ink density.
- **ESC/POS Console**: Interactive testing console with pre-compiled opcode libraries for head darkness, line feed, paper ejection, and hardware status inquiries.
- **Live CUPS Error Log Tail**: Integrated log viewer for `/var/log/cups/error_log` with search filtering and one-click CUPS debug logging toggle.

---

## Supported Printers

| Model | Resolution | Media Width | Interface |
| :--- | :--- | :--- | :--- |
| **HPRT MT800** | 300 DPI | A4 (210 mm) / Letter | USB-C & Bluetooth 4.0 / Classic SPP |
| **HPRT MT8003** | 300 DPI | A4 (210 mm) / Letter | USB-C & Bluetooth 4.2 |
| **HPRT MT800Q** | 300 DPI | A4 (210 mm) / Letter | USB-C & Bluetooth |
| **HPRT MT800Q3** | 300 DPI | A4 (210 mm) / Letter | USB-C & Bluetooth |
| **HPRT MT866** | 300 DPI | A4 (210 mm) / Letter | USB-C & Bluetooth |
| **HPRT MT8663** | 300 DPI | A4 (210 mm) / Letter | USB-C & Bluetooth |

---

## Technical Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                          HPRT Utility (SwiftUI)                        │
├───────────────────┬───────────────────┬────────────────────────────────┤
│    Diagnostics    │   Direct Print    │       Hardware Telemetry       │
│  • SystemProbe    │  • CoreGraphics   │  • HPRT V2 Protocol Framing    │
│  • DriverInspector│  • Floyd-Steinberg│  • Serial Probe (/dev/cu.*)    │
│  • CupsService    │  • ESC/POS GS v 0 │  • BLE Probe (GATT 0x180F)     │
└─────────┬─────────┴─────────┬─────────┴────────────────┬───────────────┘
          │                   │                          │
          ▼                   ▼                          ▼
   ┌─────────────┐     ┌─────────────┐            ┌─────────────┐
   │  CUPS Print │     │ Raw Stream  │            │ Serial/GATT │
   │   Daemon    │     │ lp -o raw   │            │ Read/Write  │
   └──────┬──────┘     └──────┬──────┘            └──────┬──────┘
          │                   │                          │
          └───────────────────┼──────────────────────────┘
                              ▼
                 ┌─────────────────────────┐
                 │  HPRT Mobile Printer    │
                 │   (USB / Bluetooth SPP) │
                 └─────────────────────────┘
```

- **Languages**: Swift 5.0, SwiftUI
- **Frameworks**: AppKit, CoreBluetooth, IOKit, CoreGraphics, PDFKit, Combine
- **Zero External Dependencies**: Self-contained Xcode project using only Apple system frameworks.

---

## Building from Source

### Prerequisites
- macOS 14.0 (Sonoma) or newer.
- Xcode 15.0 or newer.

### Build via Command Line
```bash
# Clone the repository
git clone https://github.com/mattcastel/hprt-utility-macos.git
cd hprt-utility-macos

# Build Release binary using Xcode
xcodebuild -project HPRTUtility.xcodeproj \
           -scheme "HPRT Utility" \
           -configuration Release \
           build
```

The resulting `HPRT Utility.app` bundle will be created in your Xcode DerivedData build directory.

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
