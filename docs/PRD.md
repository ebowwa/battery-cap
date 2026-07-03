# BatteryCap — Product Requirements Document

| Field        | Value                                                          |
| ------------ | -------------------------------------------------------------- |
| **Status**   | Experimental — v0.1                                            |
| **Owner**    | @ebowwa                                                        |
| **License**  | MIT                                                            |
| **Repo**     | https://github.com/ebowwa/battery-cap                          |
| **Created**  | 2026-07-03                                                     |
| **Audience** | Future-self, contributors, anyone evaluating the approach      |

---

## 1. Executive Summary

BatteryCap is a minimal, open-source macOS menu bar application that caps
battery charge on Intel MacBooks (2012–2017 era, including USB-C models)
by writing the System Management Controller (SMC) key `BCLM`
(Battery Charge Level Max).

It exists because the alternatives each fail one of three tests:

| Alternative       | Open source | Intel menu-bar UX | Sub-80% cap | macOS 13/14 |
| ----------------- | ----------- | ----------------- | ----------- | ----------- |
| AlDente (Free)    | ❌           | ✅                 | ❌ (paid)   | ✅           |
| AlDente (Pro)     | ❌           | ✅                 | ✅           | ✅           |
| batt              | ✅ (GPL2)    | ✅                 | ✅           | ❌ (AS only) |
| bclm              | ✅ (MIT)     | ❌ (CLI only)      | ✅           | ⚠️ broken 15+ |
| macOS native      | N/A         | ✅ (settings)      | ❌ (80 min) | ✅ (26.4+)   |
| **BatteryCap**    | ✅ (MIT)     | ✅                 | ✅           | ✅           |

The MVP is approximately 700 lines of Swift, vendored from MIT-licensed
predecessors (beltex/SMCKit, zackelia/bclm). Single-binary deploy, no code
signing drama for v1, native macOS auth dialog via `osascript`.

---

## 2. Problem Statement

### The battery physics

A lithium-ion cell held at 100% charge (4.20 V/cell) for months on end
experiences accelerated **calendar aging** — capacity loss that occurs
independent of charge cycles. An Intel MacBook Pro (2013–2017 era, including
the A1706 Touch Bar USB-C generation) kept perpetually at 100% will exhibit
measurable capacity loss within 12 months and visible battery swelling
within 24–36 months. This is well-documented
in [Battery University BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries).

The same cell held at 60% (~3.85 V) experiences roughly **one-third** the
calendar aging stress, with zero functional cost if the device is rarely
asked to deliver battery power (always-on dev servers, kiosk Macs, CI
runners).

### Why existing tools don't fit

1. **AlDente** is closed-source and paywalled for the sub-80% feature
   that actually matters for calendar-aging mitigation.
2. **batt** is Apple-Silicon-only — the maintainer explicitly declined to
   support Intel.
3. **bclm** is a CLI tool with no menu bar UI, and is broken on macOS 15+
   due to kernel entitlement enforcement.
4. **macOS 26.4+** has native charge limiting but caps at 80% minimum
   (insufficient for storage-grade stress reduction) and doesn't run on
   the 2012–2017 Intel hardware anyway.

The user is on a **MacBook Pro A1706 (13" with Touch Bar, 2016 or 2017)**
— a USB-C-only Intel Mac with the TI `bq20z451` battery gauge chip —
showing 977 cycles (98% of rated life) and a current capacity of 3594 mAh.
Extending remaining life via a 60% cap is the immediate need. The same
hardware profile exists across the long tail of Intel Macs still in
service as home servers, CI runners, and family hand-me-downs.

---

## 3. Goals

### G1 — Effective cap on Intel hardware
Write `BCLM` such that the battery physically stops accepting charge
current at the configured percentage (within the ~3% firmware overshoot
documented for the TI `bq20z451` gauge chip).

### G2 — Native macOS menu bar UX
The user should never need to open Terminal for daily operation. Cap
changes happen via menu click + native auth dialog. Visual state
(current %, current cap, applying state) is visible at a glance.

### G3 — Persistence across reboots
A configured cap survives reboot, SMC reset, and OS updates via a
LaunchDaemon that re-applies on boot.

### G4 — Single-binary deploy
The same executable serves as both menu bar app and privileged helper.
No `SMJobBless`, no separate helper process to install. Install path is
one `swift build` + one shell script.

### G5 — Open and auditable
MIT licensed. Vendored SMC code preserves upstream attribution. No
telemetry, no analytics, no network calls. Total source under 1000 LOC
so a reviewer can read the entire codebase in 30 minutes.

---

## 4. Non-Goals

These are things we considered and **deliberately rejected** for v1.

### NG1 — Apple Silicon support
Apple Silicon uses `CHWA` (not `BCLM`), supports only 80 or 100, and has
a different security model. Existing tooling (`batt`) handles this case
well. BatteryCap stays Intel-only to keep the codebase focused.

### NG2 — macOS 15+ support
Kernel entitlement enforcement in macOS 15 blocks userspace SMC writes
without disabling SIP. We will not ask users to disable SIP. macOS 15+
users should use `batt`, the native macOS 26.4+ limiter, or a smart-plug
script (documented in README as the fallback path).

### NG3 — Beautiful design
This is a tool, not a product. Standard AppKit `NSStatusBar` +
`NSAlert`. No custom icons, no animations, no onboarding flow. The user
said "not too pretty but basic a tray thing that just works" — that is
the spec.

### NG4 — Replacing macOS native features
On macOS 26.4+ or Apple Silicon, the native battery health management is
better than anything we could ship. BatteryCap targets the gap Apple
left: sub-80% caps on Intel Macs that can't run modern macOS.

---

## 5. Target Users

### Primary: Always-on Intel MBP operators
Developers using a 2013–2017 MBP (Retina or Touch Bar generation) as a
home server, CI runner, media server, or kiosk. The battery is rarely
asked to deliver power; calendar aging dominates. Wants sub-80% cap to
maximize remaining cell life without thinking about it.

### Secondary: Battery-life-extension hobbyists
Users who acquired an older Intel MBP cheap and want to extend its
usable life. Willing to install a tool, configure once, and forget.
Cares about open source and auditability.

### Tertiary: SMC/IOKit learners
Developers studying how macOS hardware interfaces work. Will read the
source for the SMC pattern, may fork for related projects (fan control,
sensor reading, etc.).

---

## 6. Target Hardware

### Primary target
- **Model**: MacBook Pro 13" with Touch Bar, **A1706** (Late 2016 or Mid 2017)
- **Battery gauge**: TI `bq20z451` (confirmed across A1706/A1708/A1964 era)
- **Battery**: A1819, 49.2 Wh lithium-polymer, ~10h wireless web
- **CPU**: Intel i5 / i7 (6th–7th gen, dual-core)
- **Charging**: USB-C (Thunderbolt 3), no MagSafe, **no LED on the charging port**
- **macOS ceiling (official)**: 2016 model → Monterey (12); 2017 model → Ventura (13)
- **macOS in practice**: user is reinstalling macOS 13 Ventura or 14 Sonoma
  (Sonoma on A1706 requires OpenCore Legacy Patcher)

### Verified behavior on this generation
- ✅ `BCLM` key exists and accepts writes (multiple user reports on r/mac,
  Hacker News, MacRumors confirm successful charge limiting on 2016–2019
  Intel MBPs with Touch Bar)
- ❌ `BFCL` key likely doesn't exist or is meaningless — there is no MagSafe
  LED on USB-C Macs for it to control. The
  [MacRumors SMC thread](https://forums.macrumors.com/threads/2439923/)
  documents BFCL as absent on pre-Core iX Macs; for USB-C Core iX Macs the
  key is technically present but has no hardware effect.
- 🔌 Related SMC keys observed on this generation (not used by BatteryCap v1):
  `CH0B` (charge control: 00 = allow, 02 = inhibit), `BRSC` (charge level
  reading). Documented for future work in §15 OQ7.

### Visual feedback (or lack thereof)
Because A1706 has no charging LED, **the user cannot use visual inspection
to confirm the cap is working**. The fast proving test relies on:
- `pmset -g batt` showing "AC Power; not charging" once cap is reached
- Menu bar % not climbing past `cap + 3` (Intel firmware overshoot)
- `system_profiler SPPowerDataType` showing `Charging: No`

On MagSafe-era Macs (A1502/A1398 2013–2015), the LED color change is a
useful secondary signal — but that doesn't apply to A1706 and shouldn't
be relied on as a test criterion.

### Known-incompatible
- Any Apple Silicon Mac (different SMC key `CHWA`, different security model)
- Pre-2012 Intel Macs (different SMC firmware; may work but untested)
- macOS 15+ on any Intel Mac (kernel entitlement block, per bclm README)

### Likely-compatible but untested
- MacBook Pro Retina 13"/15" (A1502/A1398, 2013–2015) — MagSafe 2 era,
  BFCL controls the LED indicator. Code path identical.
- MacBook Pro 13"/15" with Touch Bar (A1707, 2016–2017) — same generation
  as A1706, just larger.
- MacBook Pro 13" Function Keys (A1708, 2016–2017) — same generation,
  no Touch Bar.
- MacBook 12" (A1964, 2017) — single USB-C port, same battery gauge chip.

### User's specific deployment target
- MacBook Pro A1706 (13" with Touch Bar, 2016 or 2017), Intel i5
- macOS 13 Ventura or 14 Sonoma (TBD post-reset, depends on year + OCLP)
- Battery: 977 cycles, 3594 mAh full charge capacity, condition "Normal"
- Use case: always-on AC, target cap 60%

---

## 7. Functional Requirements

### Status display
| ID  | Requirement                                                            |
| --- | --------------------------------------------------------------------- |
| FR1 | Display current battery charge percentage in menu bar                  |
| FR2 | Display current cap value (or "no cap") in menu bar                    |
| FR3 | Show "applying" state in menu bar while a write is in flight           |
| FR4 | Refresh battery reading every 60 seconds                               |
| FR5 | Refresh cap reading after every user-initiated write                   |

### Cap control
| ID  | Requirement                                                            |
| --- | --------------------------------------------------------------------- |
| FR6 | Allow user to set cap via preset (50 / 60 / 70 / 80)                   |
| FR7 | Allow user to set cap via custom dialog (any integer 50–100)           |
| FR8 | Custom dialog pre-fills with `current_charge + 3` when no cap is set   |
| FR9 | Custom dialog pre-fills with current cap when one is already set       |
| FR10 | Allow user to remove cap (sets BCLM = 100)                            |
| FR11 | Validate cap input is integer 50–100; reject others with clear error  |
| FR12 | Disable all cap controls while a write is in flight                    |

### Persistence
| ID  | Requirement                                                            |
| --- | --------------------------------------------------------------------- |
| FR13 | Allow user to enable boot persistence via menu toggle                  |
| FR14 | Allow user to disable boot persistence via menu toggle                 |
| FR15 | Persist chosen cap value to `/usr/local/etc/battery-cap.conf`          |
| FR16 | Install LaunchDaemon at `/Library/LaunchDaemons/com.ebowwa.battery-cap.plist` |
| FR17 | LaunchDaemon runs binary with `--boot-apply` flag on system boot       |
| FR18 | `--boot-apply` reads conf file and writes BCLM                         |

### Privilege handling
| ID  | Requirement                                                            |
| --- | --------------------------------------------------------------------- |
| FR19 | All SMC writes prompt for admin via native macOS auth dialog           |
| FR20 | SMC reads do not require privileges                                    |
| FR21 | Cancellation of auth dialog does not crash the app                     |
| FR22 | Auth failure shows error in alert, returns to normal state             |

### Error handling
| ID  | Requirement                                                            |
| --- | --------------------------------------------------------------------- |
| FR23 | AppleSMC driver missing → graceful error, no crash                     |
| FR24 | BCLM key not found → menu shows "cap ?", no crash                      |
| FR25 | BFCL write fails with keyNotFound → silently ignored (expected on USB-C Macs) |
| FR26 | LaunchDaemon install fails → user-visible error with diagnostic hint   |

### Conflict detection (R7 mitigation)
| ID  | Requirement                                                            |
| --- | --------------------------------------------------------------------- |
| FR27 | Run conflict detection on app launch (async, non-blocking)             |
| FR28 | Detect macOS Optimized Battery Charging via `pmset -g` (tri-state)     |
| FR29 | Detect AlDente via .app bundle paths AND LaunchDaemon paths            |
| FR30 | Detect batt via LaunchDaemon at `com.charlieitzbatt.daemon.plist`      |
| FR31 | Detect bclm persistence via LaunchDaemon at `com.zackelia.bclm.plist`  |
| FR32 | Detect macOS 26.4+ native charge limit via `pmset chlim`               |
| FR33 | Show `⚠️ ` prefix in menu bar title when any conflict is detected       |
| FR34 | Show clickable "⚠️ N conflict(s) detected" menu row when conflicts exist |
| FR35 | Show "✓ No conflicts detected" row when verified clean                 |
| FR36 | Show "Checking for conflicts…" row while scan is in flight             |
| FR37 | Provide "Re-scan for conflicts" manual trigger                         |
| FR38 | Detail dialog lists each conflict with title + remediation hint         |
| FR39 | When OBC status is unknown, surface as "manual verify" hint (not silent, not false) |

---

## 8. Non-Functional Requirements

### Performance
| ID   | Requirement                                                  |
| ---- | ----------------------------------------------------------- |
| NFR1 | Binary size < 1 MB (current: ~550 KB release)               |
| NFR2 | Idle RSS < 20 MB                                            |
| NFR3 | Cold launch to menu bar visible < 500 ms                    |
| NFR4 | SMC read latency < 50 ms                                    |
| NFR5 | Battery polling uses < 0.1% CPU averaged over an hour       |

### Compatibility
| ID   | Requirement                                                  |
| ---- | ----------------------------------------------------------- |
| NFR6 | macOS 13.0+ required (deployment target)                    |
| NFR7 | x86_64 architecture required (Intel target)                 |
| NFR8 | Universal binary build supported from M1 dev machine        |

### Security
| ID   | Requirement                                                  |
| ---- | ----------------------------------------------------------- |
| NFR9 | No network calls (verified: no `URLSession`, no sockets)    |
| NFR10 | No telemetry, analytics, or crash reporting                |
| NFR11 | No persistent disk writes outside `/usr/local/etc/` and `/Library/LaunchDaemons/` |
| NFR12 | SMC writes only happen via user-initiated action or boot-apply |

### Code quality
| ID   | Requirement                                                  |
| ---- | ----------------------------------------------------------- |
| NFR13 | Source under 1000 LOC (current: ~700)                      |
| NFR14 | Zero external package dependencies                          |
| NFR15 | No force-unwraps, no `try!`, no fatal errors in production paths |
| NFR16 | Conflict detection must never produce false positives (verified absence required before claiming "clean") |
| NFR17 | Conflict detection completes in < 500ms (currently ~150ms)  |
| NFR18 | Unknown detection state is reported as "manual verify", never as "off" |

---

## 9. User Stories

### US1 — The CI runner operator
> As a developer with a 2016–2017 MBP (Touch Bar, USB-C) running GitHub
> Actions runner 24/7, I want
> to cap charge at 60% so the battery doesn't swell over the next two years
> of always-on AC, without paying for AlDente Pro or trusting closed-source
> binaries with kernel access.

### US2 — The fast tester
> As a tester validating that the cap works, I want the dialog to pre-fill
> with `current + 3` so I can confirm the cap takes effect in 15 minutes
> instead of waiting 4 hours for a full discharge-charge cycle.

### US3 — The forgetful rebooter
> As a user who reboots monthly for OS updates, I want the cap to
> automatically re-apply on boot so I don't discover three months later
> that the battery has been at 100% the whole time because I forgot to
> re-set the cap after the reboot.

### US4 — The open-source auditor
> As a security-conscious user, I want to read the entire source in under
> 30 minutes so I can verify the app doesn't phone home, doesn't persist
> my password, and doesn't write to any unexpected locations.

### US5 — The SMC learner
> As a developer learning macOS internals, I want the SMC code clearly
> isolated in a single file with MIT attribution so I can copy the pattern
> for unrelated projects (fan control, sensor reading) without inheriting
> unwanted complexity.

### US6 — The family IT support
> As someone who ships old Intel Macs to family members, I want a free
> MIT-licensed tool I can pre-install before mailing the laptop so the
> recipient's battery survives being plugged in 24/7 for the next 5 years.

---

## 10. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Menu bar app (user, no privileges)                          │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ AppDelegate.swift                                       │  │
│  │  - NSStatusBar menu                                     │  │
│  │  - Battery polling (Timer @ 60s)                        │  │
│  │  - User actions dispatch to CapController                │  │
│  └────────────────────────────────────────────────────────┘  │
│           │                                                  │
│           │ user clicks "Set cap 60%"                        │
│           ▼                                                  │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ CapController.applyCap(value, completion)               │  │
│  │  - Spawns: /usr/bin/osascript -e                        │  │
│  │    'do shell script "<self> --write 60" with admin priv'│  │
│  │  - Native macOS auth dialog appears                     │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ exec as root
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Privileged helper (root, --write/--read/--boot-apply)       │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ main.swift argv dispatch                                │  │
│  │  → CapController.writeCap(value)                        │  │
│  │  → CapController.writeBFCL(value - 5)                   │  │
│  │  → ConfigStore.write(value) → /usr/local/etc/...         │  │
│  └────────────────────────────────────────────────────────┘  │
│           │                                                  │
│           ▼                                                  │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ SMC.swift (vendored from beltex/SMCKit, MIT)            │  │
│  │  - IOServiceMatching("AppleSMC")                        │  │
│  │  - IOConnectCallStructMethod (80-byte SMCParamStruct)   │  │
│  │  - readData/writeData for BCLM, BFCL                    │  │
│  └────────────────────────────────────────────────────────┘  │
│           │                                                  │
│           ▼                                                  │
│  AppleSMC.kext → SMC firmware → bq20z451 gauge chip         │
└─────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────┐
│  LaunchDaemon (root, runs once at boot)                      │
│  /Library/LaunchDaemons/com.ebowwa.battery-cap.plist         │
│           │                                                  │
│           │ RunAtLoad = true                                 │
│           ▼                                                  │
│  Exec: /Applications/BatteryCap.app/Contents/MacOS/BatteryCap│
│        --boot-apply                                          │
│           │                                                  │
│           ▼                                                  │
│  Reads /usr/local/etc/battery-cap.conf                       │
│  Writes BCLM via same SMC.swift path                          │
└─────────────────────────────────────────────────────────────┘
```

### Key design choices

**Single binary, two modes (argv dispatch).** SwiftPM doesn't ship a
clean way to install a separate privileged helper alongside an .app.
The same trick git, ffmpeg, and many unix tools use: argv[1] decides
whether we're the UI or the helper. Cost: a slightly awkward dispatch
block at the top of `main.swift`. Benefit: install is one `cp`, no
helper registration.

**osascript for sudo (not SMJobBless).** The "proper" macOS way to do
privileged operations from a menu bar app is `SMJobBless`, which
installs a separate signed helper tool. It requires code signing,
notarization, and ~200 lines of glue. For v1 we use `osascript -e 'do
shell script "..." with administrator privileges'` — the same path
installers use. One line of code, native macOS auth dialog, no signing.

**LaunchDaemon plist generated at runtime.** Rather than bundling a
template plist (which would need resource bundling in SwiftPM and path
substitution at install time), `PersistenceInstaller` generates the
XML inline using the live binary path. The reference template at
`Resources/com.ebowwa.battery-cap.plist` is for documentation only.

---

## 11. UX / Interaction Design

### Menu bar item
- Format: `🔋 X% · cap Y%` (or `→ Y%` while applying, `no cap` if 100, `cap ?` if unknown)
- Single line, variable length
- No icon (text-only for v1; could add SF Symbol in v1.1)

### Menu structure
```
BatteryCap (disabled header)
─────────────────────────
Current charge: X%       (info, disabled)
Charge cap: Y%           (info, disabled)
─────────────────────────
Set cap to:              (header, disabled)
  50%                    (checkable)
  60%                    (checkable)
  70%                    (checkable)
  80%                    (checkable)
  Set custom cap…        (opens dialog)
─────────────────────────
Remove cap (100%)
─────────────────────────
Persist cap on boot  ✓   (checkable)
─────────────────────────
Quit BatteryCap          (⌘Q)
```

### Custom cap dialog
- **Title**: "Set custom charge cap"
- **Pre-fill**: existing cap if set & < 100; else `current + 3` clamped to 50–100; else 60
- **Informative text**:
  - States current charge
  - Explains the ~3% Intel firmware overshoot
  - Suggests `current + 3` as the fast plateau test value
- **Buttons**: "Set cap" (default), "Cancel"
- **Validation**: integer 50–100; failures show warning alert with
  explanation of why values outside this range are rejected
- **Focus**: text field is `initialFirstResponder` — user can type
  immediately without Tab

### Auth flow
- Native macOS auth dialog (looks like Software Update admin prompt)
- User enters admin password
- Binary runs as root, exits, app polls result
- If user cancels: alert "User cancelled" with OK button
- If auth fails: alert with error message

---

## 12. Security Model

### Privilege boundaries
- **Menu bar app runs as user** (no special privileges for daily operation)
- **Privileged helper runs as root** (only when triggered by user action or boot daemon)
- **LaunchDaemon runs as root** (installed once via sudo, runs once per boot)

### Privilege escalation path
The ONLY way BatteryCap escalates to root is via:
```
/usr/bin/osascript -e 'do shell script "<self-path> --write N" with administrator privileges'
```
This invokes the native macOS admin prompt. BatteryCap never sees the
password — it's handled entirely by `SecurityAgent` at the OS level.

### What root can do (and what we actually do)
Root could read any file, kill any process, install malware. BatteryCap
as root does exactly three things:
1. Open the AppleSMC IOKit user client
2. Call `IOConnectCallStructMethod` to write the BCLM key
3. Write the integer cap value to `/usr/local/etc/battery-cap.conf`

Audit by reading `Sources/BatteryCap/CapController.swift` (writeCap,
writeBFCL) and `main.swift` (argv dispatch — every root path is
enumerated).

### What root does NOT do
- No network calls
- No writes outside `/usr/local/etc/battery-cap.conf` and the LaunchDaemon plist
- No exec of other binaries
- No loading of dynamic libraries
- No persistence beyond what's documented

### v1 vs v2
v1 uses `osascript` because it's simple and works without code signing.
The cost is that the binary must re-exec itself with the helper flag,
which is slightly ugly.

**v2 will use `SMJobBless`** to install a proper privileged helper tool.
This requires:
- Apple Developer ID code signing ($99/year)
- Notarization
- A helper tool embedded in the .app bundle
- ~200 lines of glue code (helper protocol, XPC connection, install flow)

The trigger for v2 is: when BatteryCap gets folded into a larger macOS
app that already has signing infrastructure, OR when Apple tightens
`osascript` restrictions to break the v1 path.

---

## 13. Success Metrics

### Validation criteria (must hold for v1.0 release)
| ID  | Metric                                                                | Target       |
| --- | -------------------------------------------------------------------- | ------------ |
| SM1 | Cap holds at configured value on Intel target                        | 7 days continuous |
| SM2 | Cap survives reboot without manual intervention                      | 3 reboots    |
| SM3 | Zero new battery cycles added during 7-day soak (when cap < charge)  | 0 cycles     |
| SM4 | Binary cold-launch time on Intel target                              | < 500 ms     |
| SM5 | Source code line count                                               | < 1000 LOC   |
| SM6 | Zero external package dependencies                                   | 0            |

### Long-term product health
| ID  | Metric                                                                | Target       |
| --- | -------------------------------------------------------------------- | ------------ |
| SM7 | Cycle count increase per year on user's deployment target             | < 10/year    |
| SM8 | Time between "cap leaked past configured value" reports              | > 90 days    |
| SM9 | Issue tracker response time (initial response)                       | < 7 days     |

### What we explicitly do NOT measure
- Active install count (no telemetry to measure it)
- User retention (same)
- Feature usage breakdown (same)
- Conversion to paid (no paid tier)

---

## 14. Risks & Mitigations

### R1 — macOS back-ports entitlement enforcement to 13/14
**Likelihood**: Low (Apple typically doesn't back-port kernel-level restrictions to previous major versions).
**Impact**: Critical — entire SMC write path breaks.
**Mitigation**: README documents the smart-plug + script fallback. No code-level mitigation possible.

### R2 — Apple Silicon binary accidentally shipped
**Likelihood**: Medium (easy mistake when developing on M1).
**Impact**: High — binary won't run on Intel target.
**Mitigation**: `Scripts/install.sh` runs `file` on the built binary and aborts if x86_64 is missing. Test plan Phase 1 includes this check.

### R3 — Gatekeeper blocks unsigned binary
**Likelihood**: High (default macOS behavior).
**Impact**: Medium — user friction on first launch.
**Mitigation**: `install.sh` runs `xattr -cr` to strip quarantine. README documents manual workaround. v1.1 will add self-signing workflow.

### R4 — SMC reset wipes cap silently
**Likelihood**: Medium (SMC resets are uncommon but happen during diagnostics).
**Impact**: Low — cap simply doesn't apply until next boot.
**Mitigation**: LaunchDaemon runs at every boot, so cap is restored within ~30 seconds of boot completing. Could add an hourly re-apply cron as defense-in-depth, but currently unnecessary.

### R5 — BFCL write semantics differ across models
**Likelihood**: Confirmed — the A1706 target is itself a USB-C-only Mac
with no MagSafe LED, which is exactly the case where `BFCL` is either
absent or has no hardware effect.
**Impact**: None. The code already handles this correctly:
`CapController.writeBFCL` is called via `try?`, which silently swallows
the `keyNotFound` error. On A1706 the BFCL write effectively no-ops,
which is the desired behavior — there's no LED to control anyway.
**Verification**: Confirmed via the
[MacRumors SMC thread](https://forums.macrumors.com/threads/2439923/)
which documents BFCL as absent on pre-Core iX Macs, and via community
knowledge that USB-C Macs (2016+) ship without a MagSafe LED for BFCL
to drive. The `bq20z451` battery gauge chip itself is present on A1706
(used for fuel gauging, not for LED control).
**Cross-model behavior** (for the broader compatibility table):
- 2012–2015 Retina (A1502/A1398, MagSafe 2): BFCL exists, controls LED
- 2016–2017 USB-C (A1706/A1707/A1708): BFCL likely absent or no-op
- 2015 MacBook (A1536, single USB-C): BFCL likely absent
- Pre-2012 (Core 2 Duo): BFCL absent, BCLM also absent

Our code path is identical for all of these — `try?` handles whatever
the SMC returns.

### R6 — Apple changes LaunchDaemon loading in future macOS
**Likelihood**: Low (LaunchDaemons are a stable, documented API).
**Impact**: Medium — persistence stops working but cap still applies during the current session.
**Mitigation**: Try both `launchctl bootstrap` (modern) and `launchctl load -w` (legacy) in the install script. Code already does this.

### R7 — User reports "battery at 100% even though cap is 60"
**Likelihood**: Medium (this is the most likely user complaint).
**Impact**: Low — almost always caused by user having set the cap in BatteryCap but also having macOS Optimized Battery Charging or AlDente fighting it.
**Mitigation**: **SHIPPED in v0.1** (was planned for v1.1, promoted because
silent failure is the dominant failure mode for SMC tools). The
`ConflictDetector` runs on launch + on manual re-scan, checks for five
conflict sources, surfaces results via a `⚠️ ` prefix on the menu bar
icon and a clickable "N conflict(s) detected" row at the top of the menu.
Each conflict carries a remediation hint (where to disable, what to
uninstall). Tri-state detection for OBC: confirmed-on / confirmed-off /
unknown — never false-positive or false-negative. See §7 FR27-FR34 and
`Sources/BatteryCap/ConflictDetector.swift`.

---

## 15. Open Questions

These are things we haven't decided about yet. None block v1.0.

- **OQ1**: Should we re-apply the cap periodically (hourly cron) as
  defense-in-depth against silent SMC resets? Currently relying on
  boot-only re-application.
- **OQ2**: ~~Should the menu bar item show MagSafe LED state for additional
  confidence?~~ **Moot for A1706** (no LED to read). Would only matter if
  extending support to A1502/A1398 (2013–2015 Retina). Defer unless those
  models become primary targets.
- **OQ3**: Should we add a "test mode" that auto-sets cap to `current + 3`
  for 30 minutes then reverts? Useful for one-shot validation, but
  complicates the state machine.
- **OQ4**: For v2: SMJobBless proper helper, or stick with osascript
  indefinitely? Depends on whether osascript path survives future macOS
  versions.
- **OQ5**: Should BatteryCap detect conflicting tools (AlDente, batt,
  bclm) at launch and warn the user? Probably yes for v1.1.
- **OQ6**: When this gets folded into a larger macOS app, does BatteryCap
  become a feature flag, a submodule, or a fully merged module? Affects
  how we structure the code now.

---

## 16. Roadmap

### v0.1 (current, shipped 2026-07-03)
- ✅ MVP: preset + custom cap, BCLM/BFCL write, LaunchDaemon persistence
- ✅ Smart pre-fill (`current + 3`) for fast testing
- ✅ Vendored SMCKit.swift (trimmed)
- ✅ **ConflictDetector** (promoted from v1.1): OBC, AlDente, batt, bclm,
  macOS native charge limit — tri-state for OBC, file-existence for others
- ✅ Tested on M1 dev (compiles, UI runs, detector verified); Intel target validation pending

### v1.0 (blocker: Intel target validation)
- [ ] Phase 4 (fast proving test) passes on Intel hardware
- [ ] Phase 6 (overnight soak) passes — cap holds for 7 days
- [ ] Phase 7 (persistence across reboot) passes
- [ ] First GitHub Release with built binary artifact

### v1.1 (polish)
- [ ] Self-signing workflow + notarization for cleaner install
- [ ] Conflict-aware install: warn user before installing if AlDente is detected
- [ ] Better error messages with specific remediation steps

### v1.2 (insight)
- [ ] Optional statistics panel: cycle count delta since install, days capped
- [ ] Optional charge-status indicator in menu (read from `pmset` since
  A1706 has no MagSafe LED to inspect)
- [ ] Logging to `~/Library/Logs/BatteryCap.log` for diagnostics

### v2.0 (integration)
- [ ] SMJobBless privileged helper for proper integration
- [ ] Code-signed, notarized .app bundle
- [ ] Sparkle auto-update framework
- [ ] OR: fold into larger macOS app as a submodule

---

## 17. Out of Scope

Things we haven't decided to do, but might in the future. Listed here to
prevent scope creep from pulling them into v1.

- **Charge scheduling** ("charge to 80% by 9am") — complex, requires
  ML or user-spec'd schedule, no clear value over a fixed cap.
- **Multi-battery / UPS support** — rare use case, complicates UI.
- **Statistics dashboard** — cycle count is already in `system_profiler`;
  duplicating it adds maintenance burden for marginal value.
- **Cloud sync of preferences** — preferences are a single integer; sync
  adds complexity with no clear benefit.
- **iOS/iPadOS** — different OS, no SMC access, not relevant.
- **Non-Mac platforms** — out of scope by definition.
- **Custom menu bar icons / theming** — v1 is "not too pretty but
  basic."
- **Onboarding flow / first-launch tutorial** — the menu is
  self-explanatory; onboarding adds friction for a 6-item menu.
- **Internationalization** — all UI strings are English. Translation
  welcome from contributors but not a v1 priority.
- **Charge curve customization** — defining a custom charge schedule
  with multiple thresholds is over-engineering for the actual use case.

---

## 18. Testing & Validation

Refer to the test plan in [README.md](../README.md#testing) and the
detailed phase-by-phase plan documented in the project workspace.

### Critical path
The single test that proves the app works is the **fast proving test**:
1. Note current charge (e.g., 51%)
2. Open BatteryCap, click "Set custom cap…"
3. Dialog pre-fills with 54 (= 51 + 3)
4. Click "Set cap", enter admin password
5. Within 15 min, `pmset -g batt` shows "AC Power; not charging"
   once the plateau is reached
6. Battery % does not climb past `cap + 3` (Intel firmware overshoot)
   for 15 minutes
7. `system_profiler SPPowerDataType | grep Charging` shows `Charging: No`

On MagSafe-era Macs (A1502/A1398, 2013–2015), the additional signal of
the MagSafe LED turning green at the cap is available — but A1706 has
no charging LED, so don't rely on visual inspection.

If this passes, the app works for its primary purpose. Everything else
is polish.

### Pre-release validation matrix
| Phase | Test                              | Pass Criteria                          |
| ----- | --------------------------------- | -------------------------------------- |
| 0     | Baseline capture                  | `system_profiler` snapshot saved       |
| 1     | Install on Intel target           | `file` shows x86_64, app launches      |
| 2     | SMC read sanity                   | `--read` returns 50–100                |
| 3     | SMC write via CLI                 | Read-back matches                      |
| 4     | Fast proving test                 | Plateau within 15 min, `pmset` shows "not charging" |
| 5     | UI + osascript flow               | Native auth dialog, menu updates       |
| 6     | Overnight soak                    | Cap holds 7 days, no new cycles        |
| 7     | Reboot persistence                | Cap auto-applies after reboot          |
| 8     | Uninstall                         | System returns to normal               |

---

## 19. Acknowledgments

BatteryCap stands on the shoulders of:

- **[beltex/SMCKit](https://github.com/beltex/SMCKit)** — Swift SMC IOKit
  library (MIT). The vendored `Sources/BatteryCap/SMC.swift` is trimmed
  from this project. The 80-byte `SMCParamStruct` and the
  `IOConnectCallStructMethod` pattern originated here.
- **[zackelia/bclm](https://github.com/zackelia/bclm)** — Reference for
  the BCLM/BFCL write logic and the LaunchDaemon persistence pattern.
  Their `Sources/bclm/main.swift` informed the helper-mode dispatch.
- **[charlie0129/batt](https://github.com/charlie0129/batt)** — Apple
  Silicon equivalent. Their docs on the broader charge-limiting landscape
  (firmware compatibility, calendar aging, USB-C charging behavior) were
  essential background reading.
- **[Battery University BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)**
  — The canonical reference for lithium-ion cell preservation.

---

## 20. Revision History

| Version | Date       | Author  | Changes                          |
| ------- | ---------- | ------- | -------------------------------- |
| 0.1     | 2026-07-03 | @ebowwa | Initial PRD. Covers v0.1 shipped.|
| 0.2     | 2026-07-03 | @ebowwa | Promoted R7 mitigation from v1.1 to v0.1 (ConflictDetector shipped). Added FR27-FR39, NFR16-NFR18. |

---

## Appendix A — Glossary

- **BCLM** — Battery Charge Level Max. The SMC key (4-character code)
  that controls the maximum charge the battery will accept. Takes a
  UInt8 value 0–100. Intel Macs only.
- **BFCL** — Battery Final Charge Level. Companion key to BCLM that
  historically controlled the MagSafe LED color on 2012–2015 Retina Macs.
  Absent or no-op on USB-C Macs (2016+, including A1706) — there's no LED
  for it to control. We silently ignore `keyNotFound` via `try?`.
- **CHWA** — Apple Silicon equivalent of BCLM. Only supports 80 or 100.
  Out of scope for BatteryCap.
- **SMC** — System Management Controller. The embedded controller on
  Intel Macs responsible for battery, fan, sensor, and LED management.
- **IOKit** — Apple's device-driver framework. The userland API used to
  talk to `AppleSMC.kext` without writing a kernel extension.
- **Calendar aging** — Capacity loss that occurs in lithium-ion cells
  over time, independent of charge cycles. Accelerated by high cell
  voltage (high state of charge) and high temperature.
- **Cycle count** — Number of full discharge-equivalents the battery has
  delivered. One cycle = 100% discharge, regardless of how many sessions
  it took. Apple rates MacBook batteries for ~1000 cycles before 80%
  capacity.
- **MagSafe 2** — The magnetic charging connector used on 2012–2015
  MacBook Pro Retina (A1502/A1398). Has an LED that is amber while charging
  and green when the cap is reached (or fully charged). **Not present on
  A1706** — that generation switched to USB-C charging with no LED.
- **USB-C (Thunderbolt 3)** — The charging/data connector used on
  2016+ MacBook Pro including A1706. Provides Power Delivery negotiation
  via a TI PD controller. No visual feedback on the charging port itself;
  charge status must be read via `pmset` or `system_profiler`.
- **LaunchDaemon** — A macOS system service that runs as root at boot.
  Defined by a plist in `/Library/LaunchDaemons/`. Used here for cap
  persistence across reboots.
- **osascript** — macOS CLI for invoking AppleScript. The
  `do shell script ... with administrator privileges` form triggers the
  native macOS admin auth dialog. This is BatteryCap's only privilege
  escalation path in v1.
- **SMJobBless** — The "proper" macOS API for installing a privileged
  helper tool. Requires code signing and notarization. Deferred to v2.

## Appendix B — Reference Numbers

### Cell voltage vs state of charge (Li-ion, nominal 3.7 V)

| State of Charge | Cell Voltage | Calendar Aging Stress | Best For              |
| --------------- | ------------ | --------------------- | --------------------- |
| 100%            | 4.20 V       | High                  | Avoid for always-on   |
| 80%             | 4.00 V       | Moderate              | Daily-driver cap      |
| 60–65%          | ~3.85 V      | Low                   | Always-on sweet spot  |
| 40–50%          | 3.80 V       | Minimal               | True storage          |
| <20%            | <3.60 V      | Low stress, deep-discharge risk | Avoid       |

### Recommended cap by use case

| Use Case                              | Recommended Cap | Rationale                          |
| ------------------------------------- | --------------- | ---------------------------------- |
| Daily-driver laptop                   | 80%             | Balances runtime vs aging          |
| Always-on server / CI runner          | 60%             | Below voltage cliff, above floor   |
| Long-term storage (months unplugged)  | 50%             | Storage-optimal, charge before use |
| Storage at 100%                       | ❌               | Never — accelerates swelling       |
| Below 50%                             | ❌               | Risk of deep-discharge damage      |

---

**End of PRD.**
