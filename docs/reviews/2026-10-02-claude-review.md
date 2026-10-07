# DiskHealth — Code Review (Claude Code, 2026-10-02)

Scope: `DiskHealth.ps1`, the three WinRM modules in `.assets\` (Discovery, Connection, Workshop),
the uncommitted changes, and the WinRM-relevant parts of `RDCcheck\Enable-RemotePs.ps1`.
Review only — **no code was changed**.

## Summary

The remote/network side is in good shape. The design choices that make discovery reliable now
are sound, and the connection code is careful (bounded retries, one session, cleanup in `finally`).
The main problems found are elsewhere:

1. One **wrong health verdict** path (NVMe without smartctl can show `GOOD (100%)` with no evidence).
2. Enable-RemotePs **does not remember what it changed**, so it cannot undo the security settings.
3. A few **network-flow usability issues** (error messages likely disappear; DHCP IP reuse can
   pick up another PC's saved login).
4. **No saved report** (txt/md) — confirmed, the result exists only on screen.

| Check | Result |
|---|---|
| Offline test suite (11 scripts) | **11/11 pass** |
| Live LAN / elevated test | **Not run** — target PC is being formatted (checklist at the end) |
| Uncommitted changes | Reviewed — look correct, one wording issue (see L3) |

---

## What works well (keep it)

**Discovery (`WinRMDiscovery.psm1`)** — uses many independent sources at once: ARP/neighbor
table, ping sweep, WS-Discovery, Explorer network list, TCP sweep of ports 3389/5985/445,
NetBIOS and DNS name lookup, plus saved history. Every step has a short timeout. This is why
it now finds PCs reliably; one source failing doesn't break the scan.

**Saved-PC lookup** (`Resolve-HistoryTargetAddress`, line 1422) — tries the last IP but **checks
the MAC address** before trusting it, then looks for the MAC elsewhere in the ARP table, then
the name. This correctly handles a PC that got a new IP from DHCP.

**Uncommitted discovery change** — adds MAC-conflict protection so a PC name isn't attached to
an IP that DHCP gave to a different machine. Correct idea, correct implementation. Worth committing.

**Connection (`WinRMConnection.psm1`)** — TCP 5985 check first (fast fail), max 3 attempts with
growing delay, retries only network-type errors (never wrong password), one session reused and
always closed. Errors are put into clear categories (AuthenticationRejected, Timeout, etc.).

**TrustedHosts (`WinRMWorkshop.psm1`)** — adds only the exact selected PC, verifies by reading
back, never adds `*`. Good security practice.

**Credentials** — saved with Windows DPAPI (only your Windows user on this PC can decrypt),
separated per network. Not stored in the repo.

---

## Findings

Severity: **High** = can give a wrong answer or leave a customer PC weakened.
**Medium** = confusing or wrong behavior in some situations. **Low** = cleanup.

### H1 — NVMe without smartctl can show "GOOD (100%)" with no real evidence
- **Where:** `DiskHealth.ps1:4104-4110`
- **What happens:** On an NVMe disk when smartctl is not installed, health is set to
  `100 - Wear`. If Windows gives no Wear value (or 0), the report shows **GOOD (100%)**.
- **Why it matters:** Your own rules (`PROJECT_RULES.md` lines 22-23) say missing evidence must
  not become GOOD, and Windows `Wear=0` alone must not become 100% life. This is the one path
  that breaks that rule. A freshly formatted PC won't have smartctl, so this is exactly the
  case you'll hit when testing.
- **Fix idea:** If Wear is missing or 0 → show `REVIEW` / `UNSUPPORTED` for remaining life and
  say "install smartctl for a real verdict".

### H2 — Enable-RemotePs cannot undo its security changes
- **Where:** `RDCcheck\Enable-RemotePs.ps1:1824-1878` (modern path), `:181-192` (Win7 path),
  `-FinishWorkshop` at `:1551-1559`
- **What happens:** The script sets `LocalAccountTokenFilterPolicy=1` and
  `LimitBlankPasswordUse=0` but **does not record what the values were before**. `-FinishWorkshop`
  only removes the temporary admin user; it doesn't touch these two settings. The script also
  switches the network to **Private**, enables WinRM and adds a firewall rule, and none of those
  are undone either.
- **Why it matters:** After the workshop, the customer PC keeps "blank passwords allowed over
  the network" and "remote admin token not filtered". On a home network that is a real weakening.
- **Fix idea (matches what you suggested, with one change):**
  - When Enable-RemotePs runs, **save a small "before" receipt** (old values or "did not exist")
    in `C:\ProgramData\RDCcheck\` — the script already does exactly this for Safe Mode
    (`New-DeviceCheckSafeModeWinRMReceipt`, line 734), so the pattern exists.
  - `-FinishWorkshop` (or a new `-RestoreDefaults`) restores from the receipt. If there's no
    receipt, fall back to Windows defaults: `LimitBlankPasswordUse=1`,
    `LocalAccountTokenFilterPolicy` **deleted**.
  - Why a receipt instead of "always reset to default": some PCs already had
    `LocalAccountTokenFilterPolicy=1` for another reason (backup software, domain tools).
    Blindly resetting could break that.
  - Optional: also restore the network category and disable WinRM/firewall rule if *we* turned
    them on.
- **Important:** run the restore **only after** you finish all remote checks. Once restored,
  DiskHealth will get "Access denied" for local non-built-in admins and for blank-password
  accounts (see M2).

### H3 — Network errors probably vanish from the screen
- **Where:** `DiskHealth.ps1:3768-3769` (prints error, returns) → `:1121-1122` (parent
  immediately redraws the PC list)
- **What happens:** When a remote connection or collection fails, the error is printed and the
  script returns to the PC list right away. The list redraw moves the cursor to the top and
  clears the screen, so the error is most likely gone before you can read it.
- **Status:** Likely, not yet confirmed — **check in the live test** (enter a wrong password once).
- **Fix idea:** Show errors in a small "Connection failed" screen with the reason and
  "Press Enter to go back", the same way "Saved target unavailable" already works (line 1000).

### M1 — Reused DHCP IP can use another PC's saved login (and delete it)
- **Where:** `DiskHealth.ps1:1013-1031` and `:2772-2788`, delete at `:3526-3529`
- **What happens:** When you pick a PC, the script looks up history by **name OR last IP**. If
  DHCP gave that IP to a different PC before, it takes the old PC's name too and may try
  **the old PC's saved credential**. If that fails with Access Denied, it **deletes the saved
  credential for both names**, so the old PC loses its valid saved login.
- **Why it matters:** In a shop where PCs come and go on DHCP this will happen sometimes. It's
  not dangerous, but it's confusing (wrong username suggested, saved logins disappearing).
- **Fix idea:** Use the same MAC check the discovery module now uses. Only match by IP if the MAC
  agrees (or is unknown on both sides).

### M2 — "Access denied" always treated as wrong password
- **Where:** `WinRMConnection.psm1:42-44`, handling at `DiskHealth.ps1:3524-3565`
- **What happens:** Windows says "Access is denied" in two different cases: wrong password,
  **or** correct password but the remote PC blocks local admins over the network
  (`LocalAccountTokenFilterPolicy` not set / Enable-RemotePs not run / already restored). Both
  are treated as wrong password: the saved credential is deleted and you're asked to type it
  again, which fails again.
- **Fix idea:** On Access Denied, add a one-line hint: "If the password is correct, run
  Enable-RemotePs on the target (remote admin policy)". This matters more once H2 is done.

### M3 — TrustedHosts list only grows
- **Where:** `WinRMWorkshop.psm1:170` (add). `Remove-WinRMWorkshopTrustedHost` exists (line 236)
  but DiskHealth never calls it.
- **Evidence:** On this PC TrustedHosts already has **21 entries** (`192.168.1.x`, `NEOS`, `PALIOS`…).
- **Why it matters:** Each customer IP stays trusted forever. Low risk on your own workshop LAN,
  but it keeps growing.
- **Fix idea:** A "Clean up TrustedHosts" option in the menu, or remove the entry when a session
  ends. That would need one UAC prompt, so it's a design decision for you.

### M4 — Installing smartctl remotely through winget will often fail
- **Where:** `DiskHealth.ps1:3625-3688`
- **What happens:** winget is a per-user Store app and usually isn't available or working inside
  a WinRM remote session. The code handles the failure cleanly ("INSTALL FAILED"), but on a fresh
  Windows install expect this path to fail most of the time.
- **Fix idea:** Ship a pinned portable `smartctl.exe` in `.assets` (your rules already allow this:
  "portable project tools in `.assets` with pinned source/version/hash") and copy it over the
  existing session (`Copy-Item -ToSession`) to a temporary folder, then delete it afterwards.
  Nothing is installed on the customer PC.

### M5 — Discovery only scans a /24 network
- **Where:** `WinRMDiscovery.psm1:419` (sweeps `.1`–`.254`), `:614` (network ID = first 3 octets)
- **What happens:** Fine for a typical `192.168.1.x` workshop. On a `/23` or larger network, PCs
  outside your own `/24` won't be found by the sweep. With VPN or multiple adapters, the
  "network identity" may change between runs, so saved PCs and logins seem to disappear.
- **Fix idea:** Only if you actually work on such networks. Otherwise leave it.

### L1 — History file errors are hidden
- `WinRMDiscovery.psm1:1244, 1255` — if `connection-history.json` is corrupted or can't be
  written, it's silently treated as empty and the next save overwrites it. Suggest a warning
  and keeping a `.bak` copy.

### L2 — Small leftovers
- `DiskHealth.ps1:2746-2752` — duplicated if/else that can never run (harmless).
- `DiskHealth.ps1:3572` and `:3732` — credential is saved twice per connection (harmless).
- `-Password` as a plain-text parameter (line 30) — it can end up in console history. For
  automation, prefer `-Credential`.
- `diagnostic_reports\performance` — 58 files so far, no automatic cleanup (0.6 MB, not urgent).

### L3 — Possible typo in the uncommitted 0xBC text
- `DiskHealth.ps1:4643`: `'Fail <= = 0: ...'`. If "Fail <=" is the column name from the
  SMART table, this is intentional but reads oddly. Something like `'Threshold (Fail <=) = 0'`
  would be clearer.

---

## Missing feature — saved report (txt / md)

Confirmed: the only files written are performance timing logs. The disk report itself is
on screen only.

The good news: the script **already captures the whole report** into a variable before showing
it (`$reportRecords`, `DiskHealth.ps1:4803-4811`). So saving it is a small addition, not a rewrite.

Suggested design (your decision):
- In the report screen, add **`S` = Save**. It writes a plain-text copy (colors removed) to
  `reports\<PCNAME>_<yyyy-MM-dd_HHmm>.txt`, and optionally a `.md` version.
- Header: date, PC name/IP, Local/Network, smartctl version, and per disk: model, serial,
  overall status, remaining life.
- For automation: a `-ReportPath` flag that saves without asking.
- Add `reports\` to `.gitignore` (customer serial numbers shouldn't go into git).

Questions for you before building it:
1. txt, md, or both?
2. Should the file go in the project folder, Desktop, or a folder you pick?
3. Should it auto-save every time, or only when you press S?

---

## Live-test checklist (when the formatted PC is ready)

| # | Do this | Tells us |
|---|---|---|
| 1 | On the target: run Enable-RemotePs as admin; save what it prints | Baseline |
| 2 | On your PC: `DiskHealth.ps1` → Network. Does the PC appear? Roughly how many seconds? | Discovery |
| 3 | Pick it and enter a **wrong password** once | H3: does the error stay on screen? |
| 4 | Then the correct login | Connection + credential save |
| 5 | smartctl missing → choose **Install** | M4: does winget work remotely? |
| 6 | If install fails → choose **Continue limited** (NVMe disk) | H1: does it say GOOD 100%? |
| 7 | Read the report; note what you'd want in a saved txt | Report feature |

Paste or show me the screen at each step. I can also read your Terminal pane directly.

---

## Migration from Codex — what exists (inventory only)

| Location | What it is |
|---|---|
| `~\.codex\skills\` | `winrm-connection`, `winrm-discovery`, `winrm-workshop`, `chorus` |
| `~\.agent-shared\` | Shared rules (`SHARED_RULES.md`, `PROJECT_RULES_SOP.md`), TUI blueprint, modules, skills, workflows. Canonical owner of the files copied into this project |
| `~\.codex\rules\`, `~\.codex\templates\` | Codex rules/templates |
| `~\.gemini\` | Antigravity rules (`GEMINI.md`, workflows) |
| Project `AGENTS.md` | Was loaded automatically in this Claude Code session |

How it maps to Claude Code:
- Global rules → `~\.claude\CLAUDE.md`; project rules → `CLAUDE.md` in the project (can simply
  point to `AGENTS.md`).
- Codex skills use the same `SKILL.md` format → `~\.claude\skills\<name>\SKILL.md`. Mostly a
  copy plus checking the description text.
- Permissions (which commands can run without asking) → `.claude\settings.json`.

Suggested next session: go through `.agent-shared` and `.codex\skills` together, decide what to
bring over, and set up `CLAUDE.md` + skills. That's a bigger job than this review, so it gets
its own session.
