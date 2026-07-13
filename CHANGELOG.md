# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.14.0] - 2026-07-13

### Changed
- **Workspace Cleanup & Reorganization**:
  - Consolidated all telemetry logs, CrystalDiskInfo text reports, and screenshots from the root directory into a new structured folder named **`diagnostic_reports`**.
  - Moved subfolders `63`, `kartalis i5 4300m`, `local`, `newssd`, and files `CrystalDiskInfo_20260713101407.txt` / `CrystalDiskInfo_20260713101417.png` inside the new diagnostic directory.
  - Updated the **README.md** Project Structure documentation to reflect the consolidated structure.

## [1.13.2] - 2026-07-13

### Changed
- Improved **SanDisk/WD SSD Diagnostic Output**:
  - Added an embedded educational logic explanation directly in the console report under the `🔵 Ειδική Παρατήρηση SanDisk/WD SSD:` section.
  - Users can now see exactly how the script reasons about factory vs grown bad blocks during live execution.

## [1.13.1] - 2026-07-13

### Changed
- Updated **README.md Documentation**:
  - Added a dedicated subsection under "Technical Notes" explaining SanDisk & WD S.M.A.R.T. telemetry details.
  - Documented the distinction between **Factory Bad Blocks** (initial manufacturing defects) and **Grown Bad Blocks** (operational flash wear).
  - Clarified how variables `0xA9`, `0xAA`, `0x05`, `0xAB`, `0xAC`, and `0xE8` are evaluated by the tool to determine SSD stability.

## [1.13.0] - 2026-07-13

### Added
- Integrated **SanDisk/WD SSD Custom Telemetry Recommendations**:
  - Implemented real-time analysis of bad blocks and reserves for Western Digital/SanDisk SSD models.
  - Automatically identifies and prints custom warnings distinguishing **Factory Bad Blocks** (100% healthy initial state) from **Grown Bad Blocks** (hardware degradation indicators) by evaluating metrics like `Reserve Block Count` (AA) and `Reallocated Sectors` (05).
  - Displays remaining spare reserved capacity (E8) in percentage.

## [1.12.0] - 2026-07-13

### Added
- Integrated **Looping Interactive TUI Navigation Flow**:
  - After displaying the diagnostics for the selected drive or drives, the script no longer exits back to the shell immediately.
  - Instead, it prompts the user to press any key, clears the host, and returns directly to the drive selection picker menu.
  - Integrated **Escape Key (ESC) Exit Support**: Added a prominent Red colored instruction `💡 [ESC] Έξοδος από το πρόγραμμα (Exit)` at the bottom of the picker menu. Pressing `ESC` at the menu gracefully clears the console and returns to the shell.

## [1.11.0] - 2026-07-13

### Added
- Integrated **SanDisk & Western Digital (WD) SSD S.M.A.R.T. Mappings**:
  - Implemented specific vendor mappings for SanDisk and WD Green drives (identifying models like *SanDisk*, *WD*, *Western*, *WDC*).
  - Translated all vendor-specific S.M.A.R.T. telemetry attributes: `0xA5` (TLC Block Write/Erase Count), `0xA6` (Minimum Erase Count), `0xA7` (Maximum Erase Count), `0xA8` (SATA PHY Error Count), `0xA9` (Total Bad Blocks), `0xAA` (Reserve Block Count), `0xAB` (Program Fail Count), `0xAC` (Erase Fail Count), `0xAD` (Average Erase Count), `0xAE` (Unexpected Power Loss Count), `0xE6` (Media Wearout Indicator), `0xEA` (Total NAND GB Written), and `0xF4` (Total NAND GB Written - Host).
- Added support for translating attribute `0xEA` to **"Total GB Written to NAND"** on Samsung SSDs.
- Unified Intenso SSDs to use the existing Silicon Motion/Patriot mapping.
- Cleared generic defaults for `0xE8` (Available Reserved Space) and `0xE9` (Normalized Media Wear-out) across all SSD brands.

## [1.10.1] - 2026-07-13

### Fixed
- Fixed a CIM type conversion exception on systems with multiple physical drives:
  - Resolved `Get-StorageReliabilityCounter: Cannot process argument transformation on parameter 'PhysicalDisk'` error by replacing the direct array binding with a `foreach` loop iteration over the `$physicalDisks` collection inside the script block.

## [1.10.0] - 2026-07-13

### Added
- Integrated **Interactive WinRM Credential Fallback**:
  - If a WinRM connection fails due to authentication or authorization errors (`Access is denied`), the script detects if the console is interactive.
  - Automatically prompts the user in the console to enter a valid `Username` and a secure `Password` (hidden inputs using `-AsSecureString`).
  - Retries connection with the new credentials dynamically, avoiding immediate exit failures on host credential mismatches.

## [1.9.1] - 2026-07-13

### Fixed
- Fixed a console duplicate menu drawing issue:
  - Redesigned `Show-DriveMenu` cursor positioning to use **Relative Y-Offset calculations** instead of absolute top-left caching.
  - This ensures that when the terminal window scrolls down, the menu redraws cleanly exactly in place over its own lines without printing duplicate drive lists underneath.

## [1.9.0] - 2026-07-13

### Added
- Integrated **Interactive TUI Drive Picker Menu**:
  - If a system has multiple physical drives detected (e.g. 2 or more), the script displays a premium, flicker-free interactive menu using keyboard arrow keys (Up/Down Arrows and Enter) to choose which drive to diagnose, or select "All Drives".
  - Designed with fail-safe features: automatically detects non-interactive or redirected console sessions (using `[Console]::IsInputRedirected`) and bypasses console positioning/TUI input prompts, executing diagnostics for all drives silently to avoid script hangs.

## [1.8.0] - 2026-07-13

### Added
- Integrated **Remote smartctl Auto-Deployment**:
  - If a remote connection is established but `smartctl` is missing on the remote host, the script automatically deploys it.
  - Deploys first by copying the local `smartctl.exe` (offline, high-speed transfer via WinRM PSSession).
  - Falls back to downloading and extracting the official smartmontools zip package from SourceForge if no local binary is found.
- Resolved the SATA interface speed key discrepancy by mapping both `interface_speed` and `sata_link_speed` from smartctl JSON schema.
- Verified and displayed negotiated vs supported link speed (e.g. `SATA/300 | SATA/600`) natively on remote queries.

## [1.7.0] - 2026-07-13

### Added
- Implemented **Automatic WinRM TrustedHosts Configuration**:
  - Script automatically checks if the target IP/Hostname is trusted before initiating a connection.
  - If missing, it triggers an elevation request (using `gsudo` helper or standard UAC fallback via scratch script to avoid terminal serialization errors).
  - Automatically appends the target host to WSMan TrustedHosts and resumes WinRM connection seamlessly without user manual configuration.

## [1.6.1] - 2026-07-13

### Fixed
- Expanded the list of SATA critical attributes to include:
  - `0x01` Raw Read Error Rate
  - `0xA1` Number of Valid Spare Blocks
  - `0xE8` Available Reserved Space
- Ensured these attributes are correctly evaluated and highlighted in **Green** text when healthy, aligning their visual behavior with the rest of the critical storage telemetry indicators.

## [1.6.0] - 2026-07-13

### Changed
- Improved visual representation of S.M.A.R.T. tables:
  - All **healthy critical attributes** (e.g. Reallocated Sectors = 0, Available Spare = 100%, Remain Life = 100%, Critical Warning = 0) are now highlighted in **Green** text.
  - Problematic states remain highlighted in **Yellow** (Caution) or **Red** (Critical Failure).
  - General/informative attributes (e.g. Temperature, Power cycles, Power hours) remain in **DarkGray** for high contrast.

## [1.5.1] - 2026-07-13

### Fixed
- Updated and expanded the custom S.M.A.R.T. mapping logic for **Patriot/Silicon Motion** SSD controllers to match all specific attributes found in newer Patriot Burst Elite SSD models:
  - `0xA2` Total Erase Count
  - `0xA3` Max PE Cycle
  - `0xA4` Average Erase Count
  - `0xA6` Total Bad Block Count
  - `0xA7` SSD Protect Mode
  - `0xA8` SATA Phy Error Count
  - `0xA9` Remain Life
  - `0xAB` Program Fail Count
  - `0xAC` Erase Fail Count
  - `0xAE` Unexpected Power Loss Count
  - `0xAF` ECC Fail Count
  - `0xC2` Enclosure Temperature
  - `0xC3` Cumulative Corrected ECC
  - `0xCE` Min. Erase Count
  - `0xCF` Max Erase Count
  - `0xF1` Write Life Time
  - `0xF2` Read Life Time
  - `0xF9` Total GB Written to NAND (TLC)
  - `0xFA` Total GB Written to NAND (SLC)
- Resolved the issue where several of these telemetry attributes were displaying as `Unknown Attribute` in the console report.

## [1.5.0] - 2026-07-13

### Added
- Integrated native Windows PnP (`Get-PnpDeviceProperty`) telemetry to query **PCIe Link Speed & Width** (Transfer Mode) for NVMe drives.
  - Automatically identifies current link parameters and maximum supported parameters (e.g. `PCIe 4 x4 | PCIe 4 x4`).
- Added support for reading and display of **Storage Standard** (e.g. `NVM Express 1.4` or `SATA ACS-2`) and **Rotation Rate** (e.g. `---- (SSD)` vs `7200 RPM` for HDDs).
- Implemented automatic extraction of these attributes from CrystalDiskInfo txt reports during offline file import.

## [1.4.0] - 2026-07-13

### Added
- Expanded smartctl JSON mapping to include all missing NVMe S.M.A.R.T. attributes:
  - `0x10` Warning Composite Temperature Time
  - `0x11` Critical Composite Temperature Time
  - `0x12` Temperature Sensor 1 (native direct Celsius scaling)
  - `0x13` Temperature Sensor 2 (native direct Celsius scaling)
  - `0x1A` Thermal Management Temperature 1 Transition Count
  - `0x1B` Thermal Management Temperature 2 Transition Count
  - `0x1C` Total Time For Thermal Management Temperature 1
  - `0x1D` Total Time For Thermal Management Temperature 2

### Changed
- Changed all S.M.A.R.T. raw values display from Hexadecimal to **Decimal** format (e.g. `543` instead of `0x00000000021F` for Unsafe Shutdowns) on both SATA and NVMe tables for better readability.
- Re-labeled table column header from `Raw Value (Hex)` to `Raw Value`.

## [1.3.0] - 2026-07-13

### Added
- Added full support for parsing **NVMe S.M.A.R.T. attributes** from CrystalDiskInfo txt reports.
- Designed dynamic column hiding (`---`) in S.M.A.R.T. table for NVMe drives where Current, Worst, and Threshold values do not apply.
- Added automatic Kelvin-to-Celsius conversion (`K - 273`) for NVMe thermal sensors (`0x02`, `0x12`, `0x13`).
- Added automatic bytes-to-GB scaling for NVMe host read/write command logs (`0x06` & `0x07` Data Units).
- Added extraction of NVMe SSD status statistics: wear percentage (`0x05`), unsafe shutdowns (`0x0D`), host writes/reads, and temperature.
- Added automatic override of NVMe health status using `0x01` (Critical Warning) and `0x0E` (Media and Data Integrity Errors).
- Integrated smartctl JSON API utility fallback support.

## [1.2.0] - 2026-07-13

### Added
- Implemented native fallback diagnostic layer for **NVMe drives** that do not support traditional ATA S.M.A.R.T. WMI classes.
- Integrated querying of WMI/CIM Reliability Counters (`MSFT_StorageReliabilityCounter` / `Get-StorageReliabilityCounter`) to extract NVMe health parameters:
  - Estimated wear status (`Wear` indicator -> health %).
  - Real-time and maximum recorded temperatures.
  - Active read/write error logs.
  - Worst-case operation latency statistics (read/write in milliseconds).
- Designed custom NVMe status reporting console UI block, maintaining full Windows Terminal theme compatibility.

## [1.1.0] - 2026-07-13

### Added
- Added support for offline analysis of CrystalDiskInfo txt reports using the new `-FilePath` parameter.
- Implemented robust regex logic to handle underscores (`_`) in CDI values (normalized, worst, thresholds).
- Added dynamic, brand-specific S.M.A.R.T. attribute mapping (Samsung vs Patriot/Silicon Motion vs Generic).
- Implemented S.M.A.R.T. health algorithm differentiation: Samsung uses `B1` (Wear Leveling) Current, while Patriot/SMI uses `A9` (Remain Life) Raw value.
- Added automatic detection of critical media error indicators (`0x05`, `0xA0`, `0xB2`, `0xB7`, `0xBB`, `0xC4`, `0xC5`, `0xC6`) to override "Good" health status with `CAUTION` when physical degradation is present.
- Added calculation of Host Writes, NAND Writes, and Write Amplification Factor (WAF) for Patriot/SMI controllers.
- Integrated premium console color-coding: critical degrading attributes are highlighted in **Yellow** (Caution) or **Red** (Failure) directly inside the Windows Terminal table.

## [1.0.0] - 2026-07-13

### Added
- Created native disk health diagnostic script `Get-DiskHealth.ps1`.
- Added support for local and remote (via WinRM) WMI/CIM queries of storage components.
- Implemented native parsing of the 512-byte `VendorSpecific` S.M.A.R.T. array (Attributes ID, Current, Worst, Threshold, and Raw values).
- Added logic to automatically match and map Samsung SSD attributes (Wear Leveling, Reserved Blocks, POR Recovery, etc.).
- Designed a structured Windows Terminal user interface with clear headings, bold text, and emojis.
- Implemented automated disk health calculation (Good, Caution, Bad) based on Wear Leveling Indicators and critical error counters.
- Added comprehensive `README.md` documenting tool usage, prerequisites, and technical design.
