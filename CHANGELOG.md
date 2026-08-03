# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.24.7] - 2026-08-03

### Changed
- Kept selected-target validation separate from fresh discovery reachability: saved rows now show `WinRMReady` or offline after an explicit completed scan instead of suppressing their cached port evidence as `Saved / not checked`.
- Synced canonical `WinRMDiscovery` 1.4.0 and replaced pre-menu bulk history validation with a local-only saved/recent target catalog. Saved rows are `not checked` until selected; full LAN scan is always explicit and its TTL-bound results remain separate from successful-connection history.
- Empty history no longer triggers an automatic scan, and selecting **Scan network for more PCs** refreshes the snapshot while retaining saved targets even when the scan returns no rows.
- Synced canonical `WinRMDiscovery` 1.3.0 and forwarded its sanitized saved-target sub-stage diagnostics into the existing correlated DiskHealth performance log.
- Saved-target resolution now fast-paths corroborated last-IP/MAC evidence, uses 500 ms TCP 5985 probes, and hard-bounds the Windows system name resolver to 1000 ms instead of paying two sequential negative hostname lookups.
- Full LAN discovery no longer serializes reverse-DNS misses in the foreground; unresolved friendly names remain selectable by IP while the existing background resolver updates the network-scoped cache. Menu refresh, snapshot and hotkey policy did not change.

### Performance
- On the current two-entry history, the same parallel result set (one resolved, one unresolved) fell from `8.77 s` to `2.01 s` (`77.1%` reduction, `4.37x` faster). The online entry fell from `0.74 s` to `0.41 s`; the stale entry fell from `8.77 s` to `1.94 s`.
- Historical full-scan evidence attributed `19.5–19.8 s` of the `22–23 s` slow path to serialized reverse-DNS fallback. That loop is now outside the foreground path; three current live LAN samples completed in `3.47–4.50 s` (average `3.86 s`), with foreground reverse DNS at `0–0.1 ms` and the deliberate WS-Discovery window now the largest stage.

### Tests
- Added integration guards for no initial scan/bulk resolution, canonical selected-target validation, catalog sub-stage forwarding and `WinRMDiscovery` 1.4.0 exports.
- Added canonical history-resolution schema, failure/timeout, default-return compatibility and target/secret-absence guards, plus DiskHealth integration guards for canonical sub-stage forwarding and WinRMDiscovery 1.3.0.

## [1.24.6] - 2026-07-31

### Changed
- ATA SSD collection now requests only the standardized Solid State Device Statistics page (`smartctl -l ssd`) in addition to the existing SMART report. Valid page-7 `Percentage Used Endurance` is preferred over model-specific wear mappings, expanding remaining-life coverage without a full `smartctl -x` query.
- Remaining-life resolution now automatically uses valid ATA page 7, matched smartmontools database evidence, verified controller mappings, or an internal non-USB Windows Storage `Wear` fallback. The report exposes the binary result `SUPPORTED`/`UNSUPPORTED`; missing evidence no longer appears as `GOOD (N/A)` and never becomes zero.
- Vendor/controller profiles continue to own proprietary attribute names, counter units, and warning semantics. Unknown units remain visible raw and are reported as unsupported instead of being guessed.

### Fixed
- A live `ADATA SSD DM900 256GB-DL4 / R0427ANR`, absent from smartmontools 7.5 `drivedb.h`, now resolves `53% used` to `Life 47%` instead of `GOOD (N/A)`. Smartctl and openSeaChest independently returned the same standardized ATA value.
- Extended Silicon Motion family detection for the SM2258 layout using its full attribute signature rather than an exact model name. `F1/F2/F5` now produce Host Reads, Host Writes, NAND Writes, and lifetime WAF; the live DM900 report matched CrystalDiskInfo and Hard Disk Sentinel at roughly `31,443 / 43,149 / 213,487 GiB` and `4.95x`.
- Rejected the DM900's nominally valid ATA page-1 host-sector totals as a transfer-total source after they contradicted the controller counters and both reference tools by orders of magnitude.
- Corrected SanDisk/WD `F1/F2` lifetime totals from an invalid direct-GiB interpretation to `Total LBAs x reported logical block size`. A live SanDisk X600 at `192.168.1.243` now reports about `14.84 TiB` Host Writes and `26.29 TiB` Host Reads instead of impossible multi-petabyte values; conversion remains unsupported if sector size is unavailable.
- Reconciled the X600's valid ATA page-7 `96%` remaining life with its normalized `0xEE=94%` vendor metric by reporting the conservative `Life 94%` while preserving both readings in the source text. CrystalDiskInfo and Hard Disk Sentinel also report 94%; their shared SanDisk interpretation is corroborating vendor logic, not an independent standard counter.
- Rejected standalone Windows Storage `Wear=0` as ambiguous because the X600 driver returned zero despite independently proven 4–6% wear; it can no longer create an invented 100% fallback result.

### Performance
- Five-run live timings on the DM900 averaged `134.0 ms` for `smartctl -a -l ssd` versus `217.4 ms` for `-a` with a cold first sample; warm samples showed only a small page-7 cost. The broader `-x` path was not adopted.

### Tests
- Added regression coverage for valid/invalid page-7 telemetry, matched/unmatched database evidence, Windows wear fallback, binary unsupported behavior, endurance beyond 100%, SM2258 family detection, exact lifetime-total/WAF conversion, SanDisk LBA conversion with mandatory logical block size, and native arguments for direct ATA, NVMe, and bridge paths.

## [1.24.5] - 2026-07-30

### Changed
- Replaced the legacy per-line `-Benchmark` text output with one correlated JSONL run and a duration-sorted summary under Git-ignored `diagnostic_reports\performance`. Normal interactive Network runs enable the same diagnostics automatically and render the current stage plus elapsed time through single-frame TUI updates.
- Added timings for saved history, every canonical LAN source, target-menu construction/first frame, exact-target preparation, DPAPI, TCP/PSSession attempts, remote prerequisites, CIM/WMI/Storage/PnP, every smartctl query/retry, health evaluation and report rendering.
- Resolved network-scoped saved targets concurrently through the exported canonical `Resolve-WinRMHistoryTargetAddress`; no resolver logic, evidence rule or timeout changed.

### Performance
- On the measured 7-entry history (2 reachable, 5 stale), the Network-to-target-list path fell from `44.61 s` to `11.55 s` (`74.1%` reduction, `3.86x` faster) while preserving the same resolved/unresolved result set.
- A read-only full scan of `192.168.1.65` completed in `9.88 s` with zero failed/timeout stages; the largest collection costs were `Get-PhysicalDisk` (`2.56 s`) and `Win32_DiskDrive` (`1.12 s`).

### Tests
- Added structured-schema, monotonic-duration, timeout/failure, sorted-summary and secret-absence regression coverage.

## [1.24.4] - 2026-07-30

### Fixed
- Added an exact `KingstonUV400` telemetry profile from Kingston's published SUV400S37 SMART contract. `0xE7 Current` is now the trusted remaining-life value (`80%` on the live 120 GB sample) instead of the unrelated raw value (`20`).
- Removed the false `CAUTION` caused by globally interpreting `0xB7 raw=106` as runtime bad blocks. Undocumented/vendor-specific IDs remain visible but are warning indicators only for profiles with supporting evidence.
- Profile-scoped the table coloring and raw-warning checks so Samsung `0xB7`, Silicon Motion `0xB2`, and vendor program/erase counters do not leak into unrelated SSD layouts.

### Tests
- Added the live `KINGSTON SUV400S37120G / 0C3J96R9` regression fixture from `192.168.1.65`, covering normalized `0xE7`, opaque `0xB7`, and preserved profile-specific warning behavior.

## [1.24.3] - 2026-07-30

### Changed
- Αντικαταστάθηκε το ad-hoc DiskHealth `TrustedHosts`/elevation block με το pinned shared `WinRMWorkshop` module. Η επιλογή συγκεκριμένου PC στο UI προσθέτει μόνο το exact hostname/IP, διατηρεί τα υπόλοιπα exact entries και απαιτεί πραγματικό readback verification χωρίς δεύτερο prompt.
- Καταγράφηκε στο README το deliberate workshop security profile: WinRM HTTP/5985 + NTLM, optional blank-password local accounts και persistent target-side enablement για γρήγορο private-LAN service workflow.

### Fixed
- Αφαιρέθηκαν το προσωρινό `set-trustedhosts-*.ps1`, η αμφίσημη PowerShell `gsudo` wrapper επίκληση και τα success messages που μπορούσαν να εμφανιστούν χωρίς επαληθευμένη αλλαγή.

### Tests
- Προστέθηκε integration guard για το vendored `WinRMWorkshop` module, το canonical API call και την απουσία consumer-owned `TrustedHosts` mutation.
- Το shared direct-`gsudo.exe` live smoke μετέτρεψε το πραγματικό local `TrustedHosts = *` σε `192.168.1.6` και επιβεβαίωσε το elevated readback. Δεν εκτελέστηκε remote DiskHealth collection ή target-side mutation σε αυτή την αλλαγή.

## [1.24.2] - 2026-07-29

### Changed
- Μεταφέρθηκαν τα generic column-shrink, vertical-cell-wrap, border/row και horizontal-pan mechanics στο pinned canonical `PS_UI_Blueprint.psm1`. Το DiskHealth κρατά μόνο το SMART schema, τις header abbreviations και το coloring ως thin downstream adapter.
- Κάτω από το ελάχιστο αναγνώσιμο table width, ο πίνακας δεν αλλάζει πλέον σε stacked cards. Παραμένει σταθερός σε logical width και μετακινείται με `←/→`, ενώ εμφανίζεται width-safe `table pan` indicator με current/maximum column offset.
- Το prose παραμένει ανεξάρτητο από το table viewport και συνεχίζει να τυλίγεται κατακόρυφα στο πραγματικό terminal width.

### Tests
- Προστέθηκαν pure assertions για horizontal slice/range, left/right report viewport και indicator visibility, μαζί με νέο `50`-column σημείο στο sequential virtual-terminal replay.
- Το shared blueprint καλύπτει πλέον preferred/minimum/impossible column budgets και fixed-width vertical row wrapping σε PowerShell 7 και Windows PowerShell 5.1.

## [1.24.1] - 2026-07-29

### Fixed
- Αντικαταστάθηκε το απότομο switch από το κανονικό SMART table σε stacked cards ακριβώς κάτω από τα 104 columns. Το report κρατά πλέον adaptive 6-column table σε medium widths, στενεύει προοδευτικά τις στήλες και τυλίγει `Attribute`/`Value` σε επιπλέον γραμμές μέσα στο ίδιο row.
- Το stacked fallback ενεργοποιείται μόνο όταν δεν χωρά πλέον ένα αναγνώσιμο table με τις έξι βασικές στήλες.

### Tests
- Προστέθηκαν assertions ότι στα `98` και `56` usable report columns (το `60`-column terminal contract point) το table/header παραμένει, ότι μεγάλο attribute name επεκτείνεται κατακόρυφα, και ότι μόνο το `48`-column fixture περνά σε stacked view.
- Το sequential `pyte` replay και το focused Windows PowerShell 5.1 TUI regression πέρασαν με zero wraps, scrolls και stale frames.

## [1.24.0] - 2026-07-28

### Changed
- Μεταφέρθηκαν τα main, disk, WinRM-target και smartctl-dependency menus στο pinned canonical `PS_UI_Blueprint.psm1`, με immediate-mode full redraw, synchronized single-write frames, live resize polling και ασφαλές viewport height budget.
- Το diagnostic output συλλαμβάνει πλέον τα πραγματικά PowerShell `HostInformationMessage` records, μαζί με `NoNewline` και severity colors, ώστε η υπάρχουσα SMART λογική να τροφοδοτεί το TUI χωρίς δεύτερη υλοποίηση ή αλλαγή διαγνωστικών κανόνων.
- Το diagnostic report έγινε scrollable με `Up/Down`, `PageUp/PageDown`, `Home/End` και επιστροφή με `ESC`/`Enter`. Σε στενό viewport οι fixed-width SMART tables αποδίδονται ως compact stacked rows.
- Το `-NoUI`/automation path αναπαράγει το captured report ως κανονικό plain console output και δεν περιμένει keyboard input.
- Το startup επαληθεύει το vendored TUI runtime με το committed `PS_UI_Blueprint.sha256`; drift ή missing asset σταματά με εμφανές error.

### Fixed
- Αφαιρέθηκε το static diagnostic screen (`Write-Host` + blocking `ReadKey`) που δεν μπορούσε να ξανασχεδιαστεί μετά από resize και δημιουργούσε broken borders, wraps και stale lines.
- Αφαιρέθηκε το cursor-position subtraction από όλα τα DiskHealth selectors. Το `ESC` παραμένει Back σε child screens και Exit μόνο στο main menu.

### Tests
- Προστέθηκε DiskHealth-specific `pyte 0.8.2` sequential replay στα `120 -> 101 -> 100 -> 99 -> 98 -> 80 -> 60 -> 120`, με raw CRLF validation και assertions για zero wraps, zero scrolls, duplicate banners και stale frames.
- Επιβεβαιώθηκε το report capture/`NoNewline` merge, το compact SMART table fallback, parser compatibility, PSScriptAnalyzer error severity, non-admin `-NoUI` fallback και elevated local NVMe end-to-end collection μέσω direct `gsudo.exe`.

## [1.23.10] - 2026-07-28

### Fixed
- Split Seagate unresolved evidence into a deliberate heading plus two compact counter rows, preventing `SMART Error Log=0` from becoming an orphaned continuation line at the standard report width.
- Converted the ATA `Score/Worst` explanation into merged, padded table rows with the same 99-column outer border as the SMART table. No unbordered legend remains between the header separator and data rows.
- Corrected the prose-width cap from 118 to 98 printable columns so explanatory text stays within the 99-column SMART table footprint.

### Tests
- Added exact 99-column merged-row width assertions, presentation guards for the grouped evidence layout, and virtual-terminal validation of the complete legend/header/data block at 100, 120, and 150 columns.

## [1.23.9] - 2026-07-28

### Fixed
- Made the HDD explanation, ATA score legend, and Seagate Read/ECC block width-aware. Long text now wraps at word boundaries with stable continuation indentation instead of overflowing or being auto-wrapped by Windows Terminal.
- Capped report text to the SMART table width while still respecting narrower live viewports, with a compact long-token fallback for unusually large telemetry values.

### Tests
- Added `60/90/118`-column wrapping fixtures and a compact long-token regression.
- Validated the complete Seagate context through temporary `pyte 0.8.2` virtual terminals at `90/110/130/150` columns, then validated the real `ST8000DM004-2U9188` live output at `120` columns with identical source/rendered row counts.

## [1.23.8] - 2026-07-28

### Changed
- Renamed ATA table columns from ambiguous `Current / Worst / Threshold / Raw Value` to `Score / Worst / Fail <= / Vendor Raw` and added an inline explanation that normalized scores are neither error counts nor percentages.
- Added a dedicated `Seagate Read / ECC Context` block. It identifies identical `01 Raw Read Error Rate` and `C3 Hardware ECC Recovered` raw telemetry without inventing a decode, explains the proprietary score/failure-floor semantics, and reports reallocated, reported-uncorrectable, pending, offline-uncorrectable, and SMART error-log evidence separately.

### Tests
- Added mirrored `01/C3`, zero-error-log, and pending-sector fixtures plus presentation guards for the new ATA headings and Seagate context block.
- Passed all eight local regression/integration suites, Windows PowerShell 5.1 compatibility, PSScriptAnalyzer with zero errors, and an elevated live WinRM render against `NEOS / 192.168.1.6` using the real `ST8000DM004-2U9188` telemetry.

## [1.23.7] - 2026-07-28

### Fixed
- Corrected the Seagate `01/07/C3` wording and coloring so `Current > Threshold` is no longer described or colored as “normal.” It now means only that the firmware failure condition has not been triggered.
- Above-threshold and thresholdless proprietary Seagate attributes are neutral gray; an actual threshold crossing remains red.

### Tests
- Updated the Seagate fixtures to distinguish `AboveThreshold`, `NoThreshold`, and `ThresholdCrossed` without manufacturing a green health verdict.

## [1.23.6] - 2026-07-28

### Fixed
- Seagate HDD attributes `0x01 Raw Read Error Rate`, `0x07 Seek Error Rate`, and `0xC3 Hardware ECC Recovered` no longer turn yellow merely because their proprietary raw telemetry is non-zero.
- These attributes are now colored from their normalized `Current` value against the firmware `Threshold`; a real threshold crossing remains red and the overall SMART result remains independently enforced.
- Healthy Seagate reports now explain that the `01/07/C3` raw fields are vendor telemetry, not standalone counts of failed reads or seeks.

### Tests
- Added the live `ST8000DM004-2U9188` normalized values (`01: 80/6`, `07: 72/45`, `C3: 80/0`) and a threshold-crossing regression fixture.
- Passed all eight local regression/integration suites, Windows PowerShell 5.1 compatibility, PSScriptAnalyzer with zero errors, and an elevated end-to-end WinRM run against `NEOS / 192.168.1.6`. Live smartctl independently confirmed `SMART PASSED`, zero logged errors, and zero `05/BB/C5/C6/C7` counters.

## [1.23.5] - 2026-07-28

### Fixed
- Healthy mechanical disks now display `GOOD (SMART)` with an HDD-specific explanation instead of `GOOD (N/A)` and an irrelevant NAND mapping message.
- Neutral drive letters and transfer modes no longer use warning yellow.
- Recognized WD HDD `Spin_Up_Time` values are shown in milliseconds and seconds, so raw `7433` becomes `7433 ms (7.43 s)`.
- ATA power-on hours now prefer smartctl's decoded value or raw string. Packed Seagate telemetry such as `10733608604013536 / 5088h+41m+39.113s` is correctly reported as `5088 hrs` in both the table and recommendation.

### Tests
- Extended ATA telemetry fixtures for WD spin-up time, plain hours, and packed Seagate hours.
- Passed the full local regression suite, PSScriptAnalyzer error review, and final remote-admin WinRM assertions against both 8 TB HDDs on `NEOS / 192.168.1.6`.

## [1.23.4] - 2026-07-28

### Fixed
- Corrected the smartmontools-backed WD/SanDisk SATA SSD mappings for P/E cycles, grown bad blocks, TLC/SLC NAND writes, host reads/writes, and temperature throttling.
- Recognized WD/SanDisk `0xE8 Available Reserved Space` is now displayed transparently as `Reserve n%`; it is not presented as Hard Disk Sentinel's proprietary overall-health percentage.
- A retired-block-only `CAUTION` no longer claims active media errors or mandates immediate replacement. It now requests backup, an extended SMART self-test, and a later baseline comparison, escalating only for increasing counters, active data errors, or a failed self-test.
- Narrowed WD/SanDisk SSD profile detection so generic `WDC` hard disks cannot inherit the SSD-specific attribute map.

### Tests
- Added the live `WDC WDS120G2G0A-00JH30 / UE220400` fixture and a WD HDD false-positive guard.
- Passed all eight local regression/integration files and a saved-credential end-to-end WinRM run against `192.168.1.221`; the live result was `CAUTION (Reserve 95%)` with six grown/reassigned blocks and zero program/erase/uncorrectable errors.

## [1.23.3] - 2026-07-28

### Fixed
- Made the remote smartmontools installer compatible with older Windows Package Manager releases such as `winget 1.3.2691`, which reject `--disable-interactivity`.
- The installer now inspects the remote `winget install --help` output and includes `--disable-interactivity` only when that exact CLI supports it; required package, source, scope, exact-match, and silent arguments remain unchanged.

### Tests
- Added executable old/new winget help fixtures and flat native-argument-array assertions. The full live reinstall could not be repeated because the affected target stopped accepting WinRM connections after three bounded attempts.

## [1.23.2] - 2026-07-28

### Fixed
- Added a distinct `Phison` ATA telemetry profile for smartctl-recognized drives exposing `0xE7 SSD_Life_Left`.
- A `Patriot Burst / SBFM61.3` no longer stops at `GOOD (N/A)`; its trusted raw `0xE7` value now produces `GOOD (99%)` while `0xF1` is labeled and displayed as lifetime writes in GiB.
- Preserved the packed `0xAA Bad_Blk_Ct_Lat/Erl` value without falsely treating the combined raw number as a grown-bad-block count.

### Tests
- Added the live Phison attribute fixture and passed the full local suite plus a saved-credential end-to-end WinRM run against `192.168.1.222`.

## [1.23.1] - 2026-07-28

### Fixed
- Split the previously conflated Patriot/SMI mapping into distinct `SiliconMotionOEM` and `PatriotBurst` telemetry profiles.
- Corrected the Silicon Motion OEM meanings for attributes `0xA3` through `0xA9`; `0xA9` is now the trusted remaining-lifetime source and `0xB1` is retained as `Total Wear Level Count`, not health percentage.
- Removed the unsafe generic fallback that treated any normalized `0xB1` as health. Unknown ATA layouts now show `N/A` instead of inventing a percentage.

### Tests
- Added a regression fixture from the live `SSD 120GB / U0510A0` disk and retained a separate Patriot Burst Elite fixture.
- Passed the complete local suite and a live saved-credential WinRM run against `192.168.1.218`; the report changed from the incorrect `GOOD (100%)` to `GOOD (91%)` with `0xA9` as its source.

## [1.23.0] - 2026-07-28

### Added
- Added an in-script arrow-key prompt when a remote target is missing `smartctl`: install the official winget package, continue with limited WMI/CIM diagnostics, or press `ESC` to return.

### Changed
- Kept `-InstallSmartctl` as the non-interactive automation override instead of requiring normal users to know or re-run the script with a flag.
- Kept `-NoUI` strictly non-interactive: without the install flag it emits a visible limited-diagnostics warning and never waits for input.

### Tests
- Extended tooling-policy regression coverage for the interactive choice, `ESC` path, automation override, official package ID, machine scope, and Program Files verification.

## [1.22.0] - 2026-07-28

### Changed
- Upgraded the pinned `WinRMConnection` runtime to `1.1.0` and routed DiskHealth credential lookup, save, and removal through its canonical DPAPI profile APIs.
- Preserved DiskHealth network isolation by passing the current `WinRMDiscovery` `NetworkId` as the shared credential profile scope and retaining hostname/IP aliases.
- Saved credentials immediately after successful authenticated session opening and closed every opened session through `finally`.

### Fixed
- Removed the duplicated consumer-owned SHA-256/CLIXML credential implementation.
- Removed cached profiles only after classified `AuthenticationRejected`; TCP, timeout, transport, and unrelated explicit-credential failures no longer delete saved credentials.

### Migration
- Migrated the existing `SE` / `192.168.1.5` profiles for the `datacomputer2` job LAN into the shared store without exposing plaintext. The two legacy DiskHealth files were preserved for recovery.

### Tests
- Passed all seven DiskHealth regression/integration files, the shared WinRMConnection PS7/Windows PowerShell 5.1 suites, parser validation, PSScriptAnalyzer error review, and vendored-hash verification.

## [1.21.0] - 2026-07-27

### Changed
- Routed authenticated WinRM session opening through the pinned shared `WinRMConnection` module with TCP preflight, three bounded attempts, visible retry status, categorized failures, blank-password credential support, and transient-only retry.

### Tests
- Added a focused integration guard and passed the shared PS7/Windows PowerShell 5.1 offline suites plus an elevated authenticated localhost smoke.

## [1.20.0] - 2026-07-23

### Added
- Added a network-scoped database of previously connected WinRM PCs. The Network menu now probes saved targets on the current LAN first and offers a full network scan only as a separate action.
- Added consumer-owned Windows DPAPI credential storage under `%LOCALAPPDATA%\DiskHealth\credentials`; passwords are never stored in the shared discovery history or as plaintext.
- Added automatic reuse of the last successful credentials only when both the saved target and current network identity match.
- Added opt-in `-Benchmark` phase logs under `%LOCALAPPDATA%\DiskHealth\logs`.
- Added hidden `-NoUI` support for deterministic automation and end-to-end regression runs.

### Changed
- Made `Get-StorageReliabilityCounter` a native-NVMe fallback only and skipped it for USB storage, avoiding a measured 36-second UASP timeout.
- Reused one `smartctl --scan-open` result and used deterministic Windows physical-drive indexes before any identity probe, avoiding a measured 6-second USB/SCSI identity delay.
- Successful WinRM connections now refresh host/IP/MAC/username metadata through `WinRMDiscovery` 1.1.0 and save the credential separately with DPAPI.
- Authentication rejection deletes the stale saved credential before an interactive retry.

### Fixed
- Preserved target alias collections as arrays. PowerShell previously unwrapped a one-item pipeline result into a scalar string and concatenated later aliases into an invalid credential key.

### Tests
- Added DPAPI round-trip, network-isolation, stale-removal, benchmark-phase, and performance-guard regressions.
- Verified passwordless credential reuse against SE and reduced the measured remote operation from about 46.7 seconds to 4.3 seconds after warm-up.

## [1.19.0] - 2026-07-23

### Fixed
- Fixed S.M.A.R.T. collection for NVMe drives behind USB/UASP bridges whose Windows wrapper model and serial differ from the underlying NVMe identity.
- Mapped `smartctl --scan-open` `/dev/sd*` candidates deterministically to their Windows `PhysicalDrive` index instead of requiring wrapper identity equality.
- Fixed PowerShell single-item array unwrapping that caused one valid scan candidate to be treated as an empty match.
- Added an evidence-backed `152D:0581` → `sntjmicron` override for the JMicron USB-to-NVMe bridge, because smartctl 7.5 scans this controller only as a generic SCSI device with no health support.
- Promoted the actual protocol from smartctl JSON, so an NVMe exposed as a generic USB/SCSI disk is analyzed as NVMe and no longer falls through to the SATA-only path.
- Replaced wrapper model, serial, and firmware with the underlying smartctl identity after a successful read.
- Removed literal Markdown asterisks from model and serial console output.
- Added an explicit smartctl collection reason when no ATA/NVMe health payload can be retrieved.

### Tests
- Added the real SK hynix HFS256GD9TNG USB/UASP wrapper mismatch as a regression fixture.
- Verified the full parser and telemetry suite, an elevated local NVMe run, and an end-to-end WinRM read of the exact SK hynix/JMicron enclosure on SE.

## [1.18.0] - 2026-07-22

### Added
- Added an initial arrow-key source selector with `💻 Local computer` and `🌐 Network computer (WinRM)` before any disk or network collection begins.
- Added `Get-DiskHealth.ps1` as a thin backward-compatible launcher for the canonical script.

### Changed
- Renamed the canonical entrypoint to `DiskHealth.ps1`.
- Normal no-argument launch no longer wastes time scanning local disks when the intended target is remote.
- Removed LAN discovery from the Local disk menu; target type is chosen only from the main menu.
- Changed child-menu `ESC` behavior to navigate one level back. Only the main menu exits, and remote-disk Back reuses the existing discovery results instead of rescanning the LAN.
- Local headers now use `💻`; `🌐` is reserved for remote targets.
- Replaced the obsolete remote smartctl 7.4 ZIP/C-root fallback with an explicit official `winget` machine-scope installation into `C:\Program Files\smartmontools`.

### Tests
- Added a tooling-policy regression check that rejects SourceForge 7.4 downloads and new smartmontools install folders directly under `C:\`.

## [1.17.0] - 2026-07-22

### Added
- Added the normal interactive workflow `local disks → LAN discovery → arrow-selected PC → inline WinRM login → remote disks → return to local`.
- Added width-safe menu labels and keyboard shortcuts (`↑/↓`, `Enter`, `1-9`, `ESC`).
- Added ATA temperature regression fixtures based on the live WD Green packed raw value.

### Fixed
- Changed the no-argument target from the obsolete hardcoded `192.168.1.118` to `localhost`.
- Fixed ATA temperature display so packed raw counters such as `201864380451` use smartctl's decoded `35°C` value instead of being mislabeled as Celsius.

## [1.16.0] - 2026-07-22

### Added
- Added optional `-Discover` target selection backed by the shared `WinRMDiscovery` module proven in DeviceCheck.
- Added a pinned `.assets\WinRMDiscovery` runtime copy and an integration test that validates the module manifest, exported command, parser, and new parameters.

### Changed
- LAN discovery remains read-only and PC-only; the direct `-ComputerName` workflow and existing defaults are preserved.

## [1.15.0] - 2026-07-22

### Fixed
- Preserved NVMe 128-bit counters with `BigInteger` instead of overflowing to `UInt64` and silently replacing them with zero.
- Added `REVIEW` classification for structurally inconsistent telemetry: non-zero upper 64 bits, zero lower 64 bits, no critical warning, and no error-log entries.
- Replaced USB bridge protocol brute-forcing with device types returned by `smartctl --scan-open` and identity matching.
- Prevented NVMe `Critical Warning` (`BAD`) from being downgraded by a later media-error check.
- Corrected `Host Write Commands`, which was previously displayed with an `hrs` suffix.
- Removed absolute “fully stable/safe” conclusions that cannot be established from one S.M.A.R.T. snapshot.

### Changed
- Remote smartctl installation is now opt-in through `-InstallSmartctl`; missing tooling no longer triggers an automatic download by default.

## [1.14.1] - 2026-07-13

### Added
- **Git Integration & GitHub Publish**:
  - Initialized local Git repository, created initial commit tracking all project components.
  - Successfully published project to public remote repository at [github.com/joty79/DiskHealth](https://github.com/joty79/DiskHealth).

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
