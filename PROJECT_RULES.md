# DiskHealth Project Rules

## Current Canonical Workflow

- `DiskHealth.ps1` is the canonical entrypoint. A no-argument launch must ask `💻 Local computer` or `🌐 Network computer (WinRM)` before performing any collection; the Local disk menu contains disks only. `ESC` navigates one level back in child menus and exits only from the main menu. `Get-DiskHealth.ps1` is compatibility-only.
- Preserve raw S.M.A.R.T./NVMe values. Never replace an overflow, parse failure, or implausible counter with zero.
- Separate remaining-life estimates from overall diagnostic status.
- Use `REVIEW` when telemetry is internally inconsistent and evidence is insufficient for either a healthy or failed conclusion.
- USB bridge protocols normally come from `smartctl --scan-open`; do not brute-force controller-specific `-d` values. A controller-specific override is allowed only for an exact, evidence-backed USB VID:PID allowlist entry and must still produce a valid ATA/NVMe health payload.
- Tool installation is opt-in. A diagnostic read must not silently download or install dependencies.
- Normal interactive users must be offered required dependency actions inside the script. CLI flags remain automation/agent overrides and must not be the only discoverable user path. `ESC` returns from dependency prompts without installing.
- Installer-based dependencies belong in their standard `Program Files` location. Never create a new ad-hoc tool directory directly under `C:\`; keep project-specific portable dependencies under versioned `.assets` metadata with non-redistributable binaries ignored.
- Keep stable smartmontools as the production default. Evaluate an exact, pinned 8.x preview side-by-side only for targeted comparison evidence; never silently replace the stable install or add a nightly build globally to `PATH`.
- Keep successful WinRM target metadata network-scoped in `WinRMDiscovery`; store credentials through the shared `WinRMConnection` DPAPI profile APIs with `NetworkId` as the scope. Never place passwords in shared history, repo content, or plaintext.
- Open authenticated sessions through the pinned `WinRMConnection` module. Treat TCP 5985 as preflight evidence only, show bounded attempt status, retry only transient failures, and never repeat a remote collection after its script block has started.
- Treat PowerShell pipeline output as scalar-prone. Wrap alias/candidate pipelines in an outer `@(...)` before later array concatenation.
- Do not query `Get-StorageReliabilityCounter` for USB storage. Use deterministic physical-drive mapping before slow smartctl identity probes, and retain `-Benchmark` phase evidence for performance regressions.

## Decision History

### 2026-07-28 — Interactive dependency choice, automation flags second

- **Problem:** When a remote PC lacked `smartctl`, the normal TUI only told the technician to restart DiskHealth with `-InstallSmartctl`.
- **Root cause:** An automation authorization switch was also treated as the only user-facing installation workflow.
- **Guardrail:** In normal interactive mode, show an in-script arrow menu with Install, Continue with limited diagnostics, and `ESC` Back. Keep `-InstallSmartctl` as a non-interactive approval override and ensure `-NoUI` never waits for keyboard input. Installation remains explicit opt-in and uses only the official winget package at machine scope.
- **Files affected:** `DiskHealth.ps1`, `tests\ToolingPolicy.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** PowerShell parser passed for both entrypoints; PSScriptAnalyzer reported no errors; all seven regression/integration files passed; executable menu fixtures returned `Install`, `Continue`, and `Back`; live `-NoUI` WinRM smoke on `192.168.1.218` confirmed missing smartctl, emitted the limited-diagnostics warning, performed no install, and completed read-only collection. Canonical discovery live found the target as `WinRMReady`; WinRMConnection/WinRMDiscovery 1.1.0 vendored hashes verified.

### 2026-07-28 — Shared network-scoped DPAPI profiles

- **Problem:** DiskHealth duplicated SHA-256 target keys and DPAPI CLIXML serialization even after authenticated sessions had moved to the shared `WinRMConnection` runtime.
- **Root cause:** `WinRMConnection` 1.0.0 did not yet expose credential profile APIs, so DiskHealth originally owned a parallel implementation.
- **Guardrail:** Use only `Get-WinRMCredentialProfile`, `Save-WinRMCredentialProfile`, and `Remove-WinRMCredentialProfile`; pass `WinRMDiscovery.NetworkId` as `Scope`, preserve hostname/IP aliases, save only after session open, and remove only a cached profile rejected as `AuthenticationRejected`. Always close the session in `finally`.
- **Migration:** Imported the two legacy `SE` / `192.168.1.5` profiles for `datacomputer2|C4-27-28-4C-C0-88|192.168.1` without plaintext. Preserved the legacy files; verified two new network-scoped shared profiles.
- **Files affected:** `DiskHealth.ps1`, `.assets\WinRMConnection\*`, `tests\WinRMConnectionIntegration.Tests.ps1`, `tests\RemoteHistoryPerformance.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** Parser, seven DiskHealth regression/integration files, shared PS7/Windows PowerShell 5.1 connector suites, PSScriptAnalyzer error review, vendored hash verification, `git diff --check`, and credential migration round-trip.

### 2026-07-27 — Shared bounded WinRM connection

- **Problem:** A discovered PC with open TCP 5985 could still leave a diagnostic run waiting for minutes before a generic WinRM failure.
- **Root cause:** DiskHealth reused canonical discovery, but session opening and retry/error behavior remained consumer-specific.
- **Guardrail:** Use `.assets\WinRMConnection`; preserve DiskHealth-owned credentials and stale-credential removal, stop immediately on classified authentication failure, and retry only bounded transient session-opening failures.
- **Files affected:** `DiskHealth.ps1`, `.assets\WinRMConnection\*`, `tests\WinRMConnectionIntegration.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** Parser and integration tests passed; shared PS7/Windows PowerShell 5.1 offline suites passed; elevated localhost authenticated smoke connected on attempt 1. No customer target was available for live retest.

### 2026-07-23 — Same-network WinRM reuse and measured remote performance

- **Problem:** Every remote run required discovery and credential entry again, while the SE scan took about 46.7 seconds even though WinRM connection itself took under 0.4 seconds.
- **Root cause:** DiskHealth did not consume shared connection history or retain credentials. It also queried `Get-StorageReliabilityCounter` on a USB/UASP disk (~36 seconds) and ran an unnecessary USB/SCSI smartctl identity probe (~6 seconds). A one-item alias pipeline was additionally unwrapped to a scalar string, corrupting the saved credential lookup key when later aliases were appended.
- **Guardrail:** Query current-network history before a full scan; save only host/IP/MAC/username metadata there. Store credentials separately with Windows DPAPI, reuse them only for the same network identity, and remove them after authentication rejection. Preserve alias lists with outer `@(...)`. Skip reliability counters for USB, use exact physical-drive indexes before identity fallback, and expose opt-in phase logs with `-Benchmark`.
- **Files affected:** `DiskHealth.ps1`, `Get-DiskHealth.ps1`, `.assets\WinRMDiscovery\*`, `tests\RemoteHistoryPerformance.Tests.ps1`, `tests\WinRMDiscoveryIntegration.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** Parser and all six DiskHealth regression files passed. Canonical WinRMDiscovery offline/live tests and vendored hash verification passed. Live discovery found SE at `192.168.1.5`; explicit credentials populated history/DPAPI, a second run without username/password connected successfully, and the warm remote operation completed in about 4.3 seconds.

### 2026-07-23 — USB/UASP wrappers with rewritten NVMe identity

- **Problem:** An SK hynix HFS256GD9TNG connected through USB/UASP appeared to Windows as `SKHynix_ HFS256GD9TNG8075 SCSI Disk Device`; DiskHealth classified it as SATA/USB and found no S.M.A.R.T. data, while CrystalDiskInfo exposed the underlying NVMe identity and complete health log.
- **Root cause:** The scan-open fallback required exact model or serial equality. The bridge rewrote both wrapper fields, so the correct device candidate was rejected even though its Windows physical-drive index was deterministic.
- **Root cause (live follow-up):** PowerShell also unwrapped the one-item candidate result assigned from an `if` expression. The resulting scalar `PSCustomObject` had no `.Count`, so the valid `/dev/sdc → PhysicalDrive2` match was treated as empty.
- **Guardrail:** Map Windows `/dev/sd*` names to `PhysicalDriveN` and match the current `Win32_DiskDrive.Index` first; do not require a parsed or matching wrapper identity. Capture conditional candidate output with an outer `@(...)` so a one-item result remains an array. Prefer the protocol returned by `smartctl --scan-open`. If that protocol exposes only a SCSI wrapper, allow a controller-specific override solely from an exact, live-verified USB VID:PID allowlist (`152D:0581` → `sntjmicron`) and accept it only when it returns a valid ATA/NVMe health payload. After a valid JSON read, classify from the actual smartctl protocol and display the underlying model, serial, and firmware.
- **Files affected:** `DiskHealth.ps1`, `tests\SmartctlBridgeMapping.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** Parser, complete regression suite, official installed smartmontools Windows mapping documentation, elevated local NVMe collection, isolated WinRM probes, and full end-to-end DiskHealth collection of the exact SK hynix/JMicron enclosure on SE. The final report resolved `/dev/sdc (-d sntjmicron)`, NVMe 1.3, 99% remaining life, `Critical Warning = 0`, `Media Errors = 0`, and `Error Log Entries = 0`.

### 2026-07-22 — Dependency placement and smartmontools installation

- **Problem:** The remote opt-in installer downloaded an obsolete smartmontools 7.4 archive and created `C:\smartmontools`, while frequent 8.x preview builds could tempt an unsafe global replacement of stable tooling.
- **Root cause:** Dependency acquisition, runtime placement, and preview evaluation had no explicit ownership policy.
- **Guardrail:** Installer-based tools use their standard `Program Files` location. Project-owned portable tools use `.assets` plus pinned source/version/hash metadata, with binaries ignored when redistribution is prohibited. `-InstallSmartctl` uses the exact official winget package at machine scope and has no C-root fallback. Stable smartmontools remains the default; previews are pinned, isolated comparison tools only.
- **Files affected:** `DiskHealth.ps1`, `tests\ToolingPolicy.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** PowerShell parser, tooling-policy regression, complete telemetry/integration suite, and `git diff --check`.

### 2026-07-22 — Target selection before collection

- **Problem:** A no-argument launch scanned local disks immediately even when the intended workflow was remote WinRM diagnostics.
- **Root cause:** Local collection doubled as the interactive home screen instead of following an explicit target-source decision.
- **Guardrail:** Keep `DiskHealth.ps1` as the canonical entrypoint and show `💻 Local computer` / `🌐 Network computer (WinRM)` before any scan. Keep LAN discovery out of the Local disk menu. `ESC` is Back in child menus and Exit only in the main menu; reuse the in-memory discovery result when returning from remote disks to the PC selector. Preserve `Get-DiskHealth.ps1` only as a thin parameter-forwarding compatibility launcher.
- **Files affected:** `DiskHealth.ps1`, `Get-DiskHealth.ps1`, `tests\*.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** Parser, telemetry fixtures, startup-menu integration checks, compatibility-launcher check, live Local → Back → main flow, and live Network → SE → remote disks → cached PC selector → main flow.

### 2026-07-22 — Local-first interactive launcher and decoded ATA temperatures

- **Problem:** Normal launch still targeted an old remote IP, `-Discover` was a separate numbered prompt instead of part of the disk UI, and WD packed temperature raw bytes displayed as `201864380451 C`.
- **Root cause:** CLI-oriented defaults were treated as the user workflow, and the SATA table appended `C` directly to the full vendor raw counter instead of using smartctl's decoded temperature evidence.
- **Guardrail:** This workflow was superseded by the explicit startup source selector in 1.18.0. LAN discovery remains arrow-selectable, credentials are prompted inline, and remote `ESC` returns safely. Keep raw ATA counters intact, but display temperature from `raw.string` or top-level smartctl temperature when available; never label an implausible packed value as Celsius.
- **Files affected:** `DiskHealth.ps1`, `tests\AtaTelemetry.Tests.ps1`, `tests\WinRMDiscoveryIntegration.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** Full live flow through `SE` with only INTENSO/WD drives, both-drive report, remote-to-local return, live WD temperature `35 C`, parser tests, ATA/NVMe fixtures, vendored discovery integration, and `git diff --check`.

### 2026-07-22 — Shared WinRM target discovery

- **Problem:** Every WinRM script risked copying or independently rebuilding DeviceCheck's mature `Ctrl+L` LAN discovery logic.
- **Root cause:** Discovery, history, UI, and connection behavior were coupled inside DeviceCheck rather than exposed through a reusable runtime contract.
- **Guardrail:** Consume the canonical `.agent-shared\modules\WinRMDiscovery` implementation through the pinned `.assets\WinRMDiscovery` copy. Keep DiskHealth's selector local, preserve direct `-ComputerName`, and never edit the vendored module directly.
- **Files affected:** `.assets\WinRMDiscovery\*`, `Get-DiskHealth.ps1`, `tests\WinRMDiscoveryIntegration.Tests.ps1`, `README.md`, `CHANGELOG.md`.
- **Validation:** Canonical offline/live module tests, vendored hash verification, DiskHealth parser/integration test, and interactive `-Discover` cancellation smoke.

### 2026-07-22 — SK hynix BC711 malformed upper counter bytes

- **Problem:** Hard Disk Sentinel reported `2193718111947980818`, CrystalDiskInfo reported `0`, and the script also reported `0` for NVMe Media and Data Integrity Errors.
- **Root cause:** Native-M.2 smartctl returned the stable full value `36804482607263454645452800`; its lower 64 bits were zero while upper bytes were non-zero. The script's `UInt64` cast overflowed and the catch block silently replaced the value with zero. The exact HDS decoding and firmware-internal cause remain unknown.
- **Guardrail:** Parse NVMe counters with `BigInteger`, preserve the full value, and classify this structural pattern as `REVIEW` only when critical warning and error-log entries are also zero.
- **Files affected:** `Get-DiskHealth.ps1`, `tests/NvmeTelemetry.Tests.ps1`, `README.md`, `CHANGELOG.md`.
- **Validation:** Parser check, regression fixtures, live WinRM run against native NVMe Disk 2 on SE, and repeated smartctl 7.5 evidence.

### 2026-07-22 — Remote PowerShell collection pipeline syntax

- **Problem:** An ad-hoc WinRM smoke command produced `An empty pipe element is not allowed` before executing.
- **Root cause:** A `foreach (...) { ... } | Sort-Object` pipeline was placed directly inside a remote script block without grouping.
- **Guardrail:** Assign `foreach` output to an array first (or wrap the whole expression in `@(...)`) before piping it in inline remote commands.
- **Files affected:** `PROJECT_RULES.md`.
- **Validation:** Corrected smoke mapped native NVMe Disk 2 uniquely to `/dev/sdc -d nvme`; duplicate ATA scan paths were detected rather than guessed.

### 2026-07-28 — Generic ATA B1 is not a health percentage

- **Problem:** After smartmontools installation, a live `SSD 120GB / U0510A0` target displayed `GOOD (100%)` from normalized `0xB1`, even though its raw `0xA9` remaining-life value was `91` and multiple Silicon Motion attributes had incorrect labels.
- **Root cause:** Brand and controller profile were conflated. Every unrecognized ATA SSD fell through to a generic `0xB1` health rule, while two distinct Patriot/SMI layouts shared one attribute map.
- **Guardrail:** Resolve ATA telemetry from the complete attribute layout, not brand text or one ID. Keep `SiliconMotionOEM` and `PatriotBurst` profiles separate; for the OEM layout use raw `0xA9` as remaining life and treat `0xB1` only as total wear count. Never turn an unknown generic `0xB1` into a health percentage; show `N/A` when no trusted mapping exists.
- **Files affected:** `DiskHealth.ps1`, `tests\AtaHealthProfile.Tests.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
- **Validation:** Official smartmontools master database review; raw smartctl 7.5 collection through the canonical WinRMConnection 1.1.0 module; full local regression suite; live end-to-end run against `192.168.1.218` asserted `GOOD (91%)`, `0xA9` source, corrected SMI labels, and absence of stale `GOOD (100%)`.
