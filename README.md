<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-0078D6?style=for-the-badge&logo=windows&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Language-PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="Language">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
</p>

<h1 align="center">💾 Disk Health Diagnostics</h1>

<p align="center">
  <b>Native S.M.A.R.T. disk diagnostics tool via WinRM, WMI, or CDI Reports</b><br>
  <sub>Remote disk diagnostics made simple and lightweight without external dependencies</sub>
</p>

---

## ✨ What's Inside

| # | Tool | Description |
|:-:|------|-------------|
| 💾 | **[DiskHealth.ps1](#diskhealthps1)** | Native PowerShell script for local, remote (WinRM), and offline (CDI txt report) S.M.A.R.T. diagnostics. |

---

## 💾 DiskHealth.ps1

> Lightweight PowerShell diagnostic script to query physical disks and parse S.M.A.R.T. data natively.

### The Problem

- CrystalDiskInfo is a GUI-only application and cannot produce direct terminal output for automation.
- Running diagnostics on remote systems via WinRM usually requires installing heavy third-party CLI tools like `smartctl`.
- Traditional Windows WMI queries do not provide S.M.A.R.T. data for NVMe drives, which utilize different interface standards.
- Static health algorithms might hide physical drive degradation (e.g. reporting "Good 55%" while the SSD has active bad blocks and uncorrectable errors).

### The Solution

A native PowerShell script that connects locally or remotely via WinRM, queries `root\wmi` storage classes, and parses S.M.A.R.T. data natively.

For SATA/IDE drives, it queries S.M.A.R.T. byte arrays and resolves controller-specific layouts instead of trusting brand names alone. Samsung, Silicon Motion OEM, Patriot Burst, Phison, and SanDisk/WD profiles remain separate because the same attribute ID can mean different things on different controllers. For NVMe drives, it automatically checks if **smartctl** is installed (with JSON output support) to get full S.M.A.R.T. telemetry, falling back to CIM Storage Reliability Counters (`MSFT_StorageReliabilityCounter`) if smartctl is absent.

For NVMe drives connected through USB/UASP enclosures, DiskHealth maps `/dev/sd*` back to the corresponding Windows `PhysicalDrive` index, so an enclosure that rewrites the visible model or serial cannot prevent the underlying NVMe telemetry from being selected. It prefers bridge types returned by `smartctl --scan-open`; an exact USB VID:PID allowlist is used only for live-verified controllers that scan as generic SCSI wrappers, currently `152D:0581` with `sntjmicron`.

Remote use remembers successful PCs per network. Opening **Network computer (WinRM)** first probes only previously connected PCs associated with the current network identity; the selector offers a separate full LAN scan when needed. Target metadata lives in `%LOCALAPPDATA%\WinRMDiscovery`, while credentials use the shared Windows DPAPI profile store under `%LOCALAPPDATA%\WinRMConnection\credentials`. Each profile remains scoped to the matching DiskHealth `NetworkId` plus hostname/IP aliases.

Authenticated session opening uses the pinned shared `WinRMConnection` module. It performs a short TCP preflight, reports each of up to three bounded attempts, retries only transient transport failures, and stops immediately for authentication, TrustedHosts, name-resolution, or configuration failures.

Slow storage APIs are called only when they can add evidence. In particular, `Get-StorageReliabilityCounter` is never queried for USB disks and smartctl identity probes are a fallback only when the deterministic Windows disk-index mapping is unavailable.

It queries native Windows PnP (`Get-PnpDeviceProperty`) telemetry to query **PCIe Link Speed & Width** (Transfer Mode) for NVMe drives (e.g. `PCIe 4 x4 | PCIe 4 x4`). It also parses and displays **Storage Standard** (e.g. `NVM Express 1.4` or `SATA ACS-2`) and **Rotation Rate** (e.g. `---- (SSD)` vs `7200 RPM` for HDDs).

It also parses exported CrystalDiskInfo txt reports, supporting both SATA and NVMe formats (automatically hiding useless columns, converting raw logs like Kelvin-to-Celsius/sectors-to-GB, and formatting all raw attributes in a readable decimal structure).

```
+--------------------+               WinRM Session               +----------------------+
| Local Workstation  | ========================================> |  Remote Target Host  |
| (DiskHealth)       | <======================================== | (smartctl or WMI API)|
+--------------------+        Retrieves Raw SMART Bytes          +----------------------+
          ||
          \/
+--------------------+
| Local Parsed UI    | -> Identifies Interface Type (SATA vs NVMe)
| & Terminal Output  | -> Direct smartctl JSON parser & WMI fallback
+--------------------+ -> Native PCIe Gen & Lanes telemetry (PnP queries)
                       -> Highlights active failures in Yellow/Red & exposes WAF
```

### Usage

*From terminal:*

```powershell
# Example 1 — Normal interactive launch: choose Local or Network first
pwsh -NoProfile -File "DiskHealth.ps1"

# Example 2 — Query remote system directly from CLI
pwsh -NoProfile -File "DiskHealth.ps1" -ComputerName "192.168.1.118" -Username "user"

# Example 3 — Query local system explicitly
pwsh -NoProfile -File "DiskHealth.ps1" -ComputerName "localhost"

# Example 4 — Offline analysis of an exported CrystalDiskInfo report file (SATA or NVMe)
pwsh -NoProfile -File "DiskHealth.ps1" -FilePath "C:\Reports\CrystalDiskInfo.txt"

# Example 5 — Automation override: install smartctl without an interactive question if missing
pwsh -NoProfile -File "DiskHealth.ps1" -ComputerName "192.168.1.118" -Username "user" -InstallSmartctl

# Example 6 — CLI shortcut directly into LAN discovery
pwsh -NoProfile -File "DiskHealth.ps1" -Discover -Username "user"

# Example 7 — Record per-phase timings for discovery, WinRM, and disk probes
pwsh -NoProfile -File "DiskHealth.ps1" -ComputerName "192.168.1.118" -Benchmark
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ComputerName` | `string` | `localhost` | The hostname or IP address of the target machine. The value is used directly only when the parameter is explicitly supplied. |
| `-Username` | `string` | `user` | The WinRM username to connect with. |
| `-Password` | `string` | `""` | The WinRM connection password. |
| `-FilePath` | `string` | `""` | Optional local path to an exported CrystalDiskInfo txt report. |
| `-InstallSmartctl` | `switch` | `false` | Automation override that approves the official `winget` machine-scope installation without showing the interactive question. |
| `-Discover` | `switch` | `false` | Uses the shared PC-only LAN discovery engine and opens a target selector before WinRM collection. |
| `-DiscoveryStateRoot` | `string` | `""` | Optional absolute path for network-scoped discovery history/cache. |
| `-Benchmark` | `switch` | `false` | Writes phase timings to `%LOCALAPPDATA%\DiskHealth\logs\probe_benchmark_*.log`. |

Normal no-argument launch performs **no disk scan first**. It opens an arrow-selectable source menu with `💻 Local computer` and `🌐 Network computer (WinRM)`. The Local disk menu contains disks only. The Network path lists reachable saved PCs from the current network first and includes **Scan network for more PCs** when a full discovery is wanted.

After a successful authenticated session opens, DiskHealth remembers the username in shared connection history and stores the credential locally with Windows DPAPI. On the same network it tries that credential first; only an `AuthenticationRejected` result removes a cached profile and triggers one replacement prompt. TCP, timeout, and transport failures preserve it. The credential can be decrypted only by the same Windows user in the same Windows installation, so copying the profile—or formatting Windows—does not make it portable.

If `smartctl` is missing on an interactive remote target, DiskHealth asks inside the program whether to install the official `smartmontools.smartmontools` winget package or continue with limited WMI/CIM diagnostics. `ESC` returns to the previous menu. `-InstallSmartctl` is retained for automation, while `-NoUI` never waits for keyboard input and continues with an explicit limited-diagnostics warning unless the install flag was supplied.

`ESC` means **Back** in every child menu: local disks return to the main menu, remote disks return immediately to the cached PC selector, and the PC selector returns to the main menu. Only `ESC` on the main menu exits the program. Direct CLI parameters bypass the startup menu and remain available for automation.

`Get-DiskHealth.ps1` remains available as a compatibility launcher and forwards explicitly supplied parameters to `DiskHealth.ps1`.

---

## 📦 Installation

### Quick Setup

No installation required! Just copy the script and run it using PowerShell 7.

```powershell
# Run the script directly
pwsh -NoProfile -File "DiskHealth.ps1"
```

`smartctl` is strongly recommended for complete NVMe and ATA telemetry. Install it normally with the official smartmontools installer or `winget install --id smartmontools.smartmontools --exact`. DiskHealth never creates a private fallback under `C:\`; a normal interactive remote run asks before installing, while `-InstallSmartctl` provides the equivalent non-interactive approval. Installation failures remain visible.

### Requirements

| Requirement | Details |
|-------------|---------|
| **PowerShell** | PowerShell 7+ (Recommended) or Windows PowerShell 5.1 |
| **WinRM** | Enabled on target machine (for remote diagnostics) |
| **smartctl** | Optional (Highly Recommended for NVMe drives, automatically queried if installed) |
| **Privileges** | Administrator rights on target system (required to query storage namespaces and run smartctl) |

---

## 📁 Project Structure

```
DiskHealth/
├── .gitattributes                       # Repository line-ending policy
├── .assets/
│   ├── WinRMConnection/                 # Pinned shared authenticated WinRM connector
│   └── WinRMDiscovery/                  # Pinned shared LAN PC discovery module
├── .agents/                             # Workspace Customizations
│   └── AGENTS.md                        # Workspace rule mandates (e.g. smartctl notification)
├── diagnostic_reports/                  # Consolidated telemetry data, CDI reports, and screenshots
│   ├── 63/                              # CDI reports for remote host 192.168.1.63
│   ├── kartalis i5 4300m/               # CDI reports for Patriot SSD target
│   ├── local/                           # CDI reports for local NVMe drive
│   ├── newssd/                          # CDI reports for new good SSD target
│   ├── CrystalDiskInfo_20260713101407.txt # Backup Samsung SSD CDI report
│   └── CrystalDiskInfo_20260713101417.png # Backup Samsung SSD CDI screenshot
├── DiskHealth.ps1                       # Canonical interactive and CLI entrypoint
├── Get-DiskHealth.ps1                   # Backward-compatible launcher
├── tests/
│   ├── AtaTelemetry.Tests.ps1           # Packed ATA temperature regression fixtures
│   ├── NvmeTelemetry.Tests.ps1          # Regression fixtures for 128-bit NVMe counters
│   ├── SmartctlBridgeMapping.Tests.ps1   # Windows PhysicalDrive and USB/UASP bridge mapping
│   ├── RemoteHistoryPerformance.Tests.ps1 # DPAPI/network scope and slow-probe guards
│   ├── ToolingPolicy.Tests.ps1           # smartmontools acquisition/placement guardrails
│   ├── WinRMConnectionIntegration.Tests.ps1 # Authenticated connector integration guard
│   └── WinRMDiscoveryIntegration.Tests.ps1 # Discovery integration guard
├── README.md                            # You are here
├── CHANGELOG.md                         # Project changelog
└── PROJECT_RULES.md                     # Durable project decisions and validation history
```

---

## 🧠 Technical Notes

<details>
<summary><b>How are S.M.A.R.T. attributes parsed natively?</b></summary>

For SATA drives, the script retrieves the raw 512-byte array from `MSStorageDriver_FailurePredictData.VendorSpecific` class. It iterates in 12-byte chunks starting at offset 2, extracting the Attribute ID, Current normalized value, Worst normalized value, and the 6-byte raw value (extended to 8 bytes and converted to UInt64).

</details>

<details>
<summary><b>How does smartctl JSON Integration work?</b></summary>

If the drive is NVMe and **smartctl** is present, the script queries properties via JSON schema:
- `nvme_smart_health_information_log`: Contains warning indicators, composite temperatures, spare health, block reads/writes, unsafe shutdowns, and all thermal sensors configurations (IDs `0x01` through `0x1D`).
- NVMe counters are parsed as 128-bit-capable `BigInteger` values. Values that exceed `UInt64` are preserved rather than truncated or rewritten to zero.
- For USB/UASP bridges, the Windows disk index is the primary deterministic match (`/dev/sda` → `PhysicalDrive0`, `/dev/sdb` → `PhysicalDrive1`, and so on). Model and serial matching remain a fallback because some bridges expose wrapper identities that differ from the underlying drive. Controller-specific `-d` overrides are never brute-forced: they require an exact USB VID:PID allowlist entry backed by a successful live read.

</details>

<details>
<summary><b>What does REVIEW mean for an NVMe drive?</b></summary>

`REVIEW` means the collected fields are internally inconsistent and cannot safely support either a failure or healthy-drive conclusion. The known regression fixture has a zero lower 64-bit media-error count, non-zero upper bytes, `Critical Warning = 0`, and zero error-log entries; the script displays the full value and labels it as telemetry anomaly instead of hiding it.

`REVIEW (100%)` does **not** mean the whole drive is verified healthy: `100%` is the independent NAND remaining-life estimate derived from `Percentage Used`. Replacement decisions require corroborating evidence such as changing counters, self-test failure, read errors, OS storage events, or reproducible instability.

</details>

<details>
<summary><b>How does PCI Link Speed & Width (Transfer Mode) query work?</b></summary>

For NVMe drives, the script queries Windows PnP device properties natively:
- `DEVPKEY_PciDevice_CurrentLinkSpeed`: Maps to PCIe Generation (e.g. Gen 4.0).
- `DEVPKEY_PciDevice_CurrentLinkWidth`: Maps to PCIe Lanes width (e.g. x4).
- `DEVPKEY_PciDevice_MaxLinkSpeed` and `DEVPKEY_PciDevice_MaxLinkWidth`: Maps to maximum physical link capability of the host bus.

</details>

<details>
<summary><b>How does NVMe CDI Report parsing work?</b></summary>

Exported NVMe reports differ from SATA reports because they lack normalized health and threshold columns. The script uses a dynamic parser regex:
- **ATA SMART Regex**: `^([0-9A-F]{2})\s+([0-9_]+)\s+([0-9_]+)\s+([0-9_]+)\s+([0-9A-F]{12})\s+(.*)`
- **NVMe SMART Regex**: `^([0-9A-F]{2})\s+([0-9A-F]{12})\s+(.*)`

It converts raw hexadecimal values automatically:
- **Composite Temperatures**: Kelvin is scaled back to Celsius (`Kelvin - 273`).
- **Data Units Read/Written**: Raw sectors are scaled to Gigabytes (`Raw * 512000 / 1GB`).

</details>

<details>
<summary><b>How is the Health Status determined?</b></summary>

For Samsung SSDs, the health % can use the normalized **Wear Leveling Count (0xB1)**. Confirmed Silicon Motion OEM and Patriot Burst layouts use raw **Remaining Lifetime Percentage (0xA9)**. Smartctl-recognized Phison layouts use raw **SSD Life Left (0xE7)**, while NVMe uses **Percentage Used (0x05)**. A generic ATA `0xB1` is not trusted automatically: if the controller layout is unknown, DiskHealth reports `N/A` for the percentage while keeping the independent SMART overall status and failure indicators visible.

The distinction matters for OEM drives with generic names. A live `SSD 120GB / U0510A0` sample was absent from the smartctl drive database but exposed the complete Silicon Motion OEM signature: `0xA9 = 91` was remaining life, whereas `0xB1` was a separate total-wear counter whose normalized value happened to be `100`.

A separate live `Patriot Burst / SBFM61.3` sample is an officially recognized Phison-driven SSD. Its `0xE7 SSD_Life_Left = 99` is used as the trusted percentage and `0xF1 Lifetime_Writes_GiB` is reported without unit conversion. Its packed `0xAA Bad_Blk_Ct_Lat/Erl` raw field is preserved rather than misreported as a single bad-block count.

If critical degradation values (like reallocated sectors, pending sectors, or uncorrectable read/write events) are above zero, the health status is automatically set to `CAUTION` (or `BAD`), breaking the common firmware illusion of reporting a "Good" status based on remaining writes alone.

</details>

<details>
<summary><b>How do we detect new bad blocks in SanDisk / WD Green SSDs? (Factory vs Grown Bad Blocks)</b></summary>

For SanDisk and Western Digital (WD) SATA SSDs (e.g., WD Green series), S.M.A.R.T. telemetry maps attributes differently:
- **0xA9 (Total Bad Blocks)**: Represents the total bad block count. Almost all SSDs have some bad blocks from the factory (Factory Bad Blocks / Initial Bad Blocks) that were isolated during production testing. This number is safe as long as it remains static and grown bad blocks are zero.
- **0xAA (Reserve Block Count)**: Represents the number of retired blocks during the drive's operational lifetime. This is the primary indicator of **Grown Bad Blocks**. It should ideally be `0`.
- **0x05 (Reallocated Sectors Count)**: Represents reallocated sectors. Increases when data is moved from failing blocks to reserved areas. It should ideally be `0`.
- **0xAB (Program Fail Count)** and **0xAC (Erase Fail Count)**: Count failures when writing to or erasing NAND flash pages. A value above `0` indicates active blocks degrading during operation.
- **0xE8 (Available Reserved Space)**: Represents the remaining spare reserve blocks percentage (starting at `100%`). If this falls below `100%`, it indicates the drive is using its reserves to replace failing blocks.

The script automatically displays custom notes for SanDisk/WD SSDs. If `Total Bad Blocks (0xA9)` is above zero, but `Reserve Block Count (0xAA)` and `Reallocated Sectors Count (0x05)` are zero, the script identifies these as **100% factory-isolated bad blocks** and reports the drive as healthy. If any grown blocks or fail counts are detected, the telemetry values are highlighted in **Yellow (Caution)** or **Red (Critical)** to warn of active degradation.

</details>

---

<p align="center">
  <sub>S.M.A.R.T. Diagnostics · Native PowerShell · Lightweight Remote Monitoring</sub>
</p>
