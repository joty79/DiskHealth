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
| 💾 | **[Get-DiskHealth.ps1](#get-diskhealthps1)** | Native PowerShell script for local, remote (WinRM), and offline (CDI txt report) S.M.A.R.T. diagnostics. |

---

## 💾 Get-DiskHealth.ps1

> Lightweight PowerShell diagnostic script to query physical disks and parse S.M.A.R.T. data natively.

### The Problem

- CrystalDiskInfo is a GUI-only application and cannot produce direct terminal output for automation.
- Running diagnostics on remote systems via WinRM usually requires installing heavy third-party CLI tools like `smartctl`.
- Traditional Windows WMI queries do not provide S.M.A.R.T. data for NVMe drives, which utilize different interface standards.
- Static health algorithms might hide physical drive degradation (e.g. reporting "Good 55%" while the SSD has active bad blocks and uncorrectable errors).

### The Solution

A native PowerShell script that connects locally or remotely via WinRM, queries `root\wmi` storage classes, and parses S.M.A.R.T. data natively.

For SATA/IDE drives, it queries S.M.A.R.T. byte arrays and maps vendor-specific IDs (Samsung vs Patriot/SMI vs Generic). For NVMe drives, it automatically checks if **smartctl** is installed (with JSON output support) to get full S.M.A.R.T. telemetry, falling back to CIM Storage Reliability Counters (`MSFT_StorageReliabilityCounter`) if smartctl is absent.

It queries native Windows PnP (`Get-PnpDeviceProperty`) telemetry to query **PCIe Link Speed & Width** (Transfer Mode) for NVMe drives (e.g. `PCIe 4 x4 | PCIe 4 x4`). It also parses and displays **Storage Standard** (e.g. `NVM Express 1.4` or `SATA ACS-2`) and **Rotation Rate** (e.g. `---- (SSD)` vs `7200 RPM` for HDDs).

It also parses exported CrystalDiskInfo txt reports, supporting both SATA and NVMe formats (automatically hiding useless columns, converting raw logs like Kelvin-to-Celsius/sectors-to-GB, and formatting all raw attributes in a readable decimal structure).

```
+--------------------+               WinRM Session               +----------------------+
| Local Workstation  | ========================================> |  Remote Target Host  |
| (Get-DiskHealth)   | <======================================== | (smartctl or WMI API)|
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
# Example 1 — Query remote system with default credentials (empty password)
pwsh -NoProfile -File "Get-DiskHealth.ps1" -ComputerName "192.168.1.118" -Username "user"

# Example 2 — Query local system
pwsh -NoProfile -File "Get-DiskHealth.ps1" -ComputerName "localhost"

# Example 3 — Offline analysis of an exported CrystalDiskInfo report file (SATA or NVMe)
pwsh -NoProfile -File "Get-DiskHealth.ps1" -FilePath "C:\Reports\CrystalDiskInfo.txt"
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ComputerName` | `string` | `192.168.1.118` | The hostname or IP address of the target machine. |
| `-Username` | `string` | `user` | The WinRM username to connect with. |
| `-Password` | `string` | `""` | The WinRM connection password. |
| `-FilePath` | `string` | `""` | Optional local path to an exported CrystalDiskInfo txt report. |

---

## 📦 Installation

### Quick Setup

No installation required! Just copy the script and run it using PowerShell 7.

```powershell
# Run the script directly
pwsh -NoProfile -File "Get-DiskHealth.ps1"
```

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
├── .agents/                             # Workspace Customizations
│   └── AGENTS.md                        # Workspace rule mandates (e.g. smartctl notification)
├── diagnostic_reports/                  # Consolidated telemetry data, CDI reports, and screenshots
│   ├── 63/                              # CDI reports for remote host 192.168.1.63
│   ├── kartalis i5 4300m/               # CDI reports for Patriot SSD target
│   ├── local/                           # CDI reports for local NVMe drive
│   ├── newssd/                          # CDI reports for new good SSD target
│   ├── CrystalDiskInfo_20260713101407.txt # Backup Samsung SSD CDI report
│   └── CrystalDiskInfo_20260713101417.png # Backup Samsung SSD CDI screenshot
├── Get-DiskHealth.ps1                   # Main native diagnostics script
├── README.md                            # You are here
└── CHANGELOG.md                         # Project changelog
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
- All raw attribute outputs are formatted as clean **Decimal** numbers instead of hex values for user readability.

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

For SSDs, the health % is derived from the **Wear Leveling Count (0xB1)** or **Media Wearout Indicator (0xE9)** for Samsung/Generic drives, the **Remain Life (0xA9)** raw value for Patriot/SMI controllers, or the **Percentage Used (0x05)** for NVMe drives.

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
