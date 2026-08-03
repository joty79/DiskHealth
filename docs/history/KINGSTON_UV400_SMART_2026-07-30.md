# Kingston UV400 SMART Evidence — 2026-07-30

## Regression

A live `KINGSTON SUV400S37120G / 0C3J96R9` at `192.168.1.65` was reported by DiskHealth as `CAUTION (20%)` because two unrelated interpretations were combined:

- the generic Phison profile treated `0xE7 Raw=20` as remaining life, although this drive reports `0xE7 Current=80`;
- the global warning list treated `0xB7 Raw=106` as confirmed runtime bad blocks.

HDSentinel independently reported `80%` but labeled `0xB7` as SATA Downshift Count. That disagreement was treated as evidence that neither third-party label could be copied without vendor confirmation.

## Primary Evidence

- [Kingston SUV400S37 SMART Attribute Details](https://media.kingston.com/support/downloads/UV400-SMART-attribute.pdf) defines `0xE7 SSD Life Left` with a normalized remaining-life equation. It does not list `0xB7`.
- The [smartmontools drive database](https://www.smartmontools.org/static/doxygen/drivedb_8h_source.html) matches the exact model and firmware under `Kingston SSDNow UV400/500`. Its `0xB7 Runtime_Bad_Block` line is commented/default rather than an active Kingston-specific override.
- Live smartctl 7.5 JSON reported firmware SMART `PASSED`, `0xE7 Current=80 / Raw=20`, `0xB7 Current=83 / Raw=106 / Threshold=0`, `0xB4 Raw=616`, and zero for `05/AB/AC/BB/C4/C5/C7`.

## Decision

- Resolve exact SUV400S37 models to `KingstonUV400` before the generic Phison fallback.
- Use normalized `0xE7 Current` as the trusted remaining-life percentage and preserve its raw value separately.
- Keep `0xB7` visible as undocumented vendor telemetry, without a bad-block, downshift, or failure conclusion.
- Gate vendor-specific warning IDs and table colors by the resolved telemetry profile.

## Verification

- PowerShell AST parser: zero errors.
- `tests\AtaHealthProfile.Tests.ps1`: passed in PowerShell 7 and Windows PowerShell 5.1.
- Full offline suite: 10/10 passed, including the sequential VT resize replay.
- Live end-to-end DiskHealth run: `GOOD (80%)`, normalized `0xE7` source, no `Runtime Bad Blocks (106)` caution, and an explicit opaque `0xB7` note.
