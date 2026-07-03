# BatteryCap

A minimal macOS menu bar app to cap battery charge on Intel MacBooks via the
SMC `BCLM` key. The DIY equivalent of AlDente — about 300 lines of Swift.

![status: experimental](https://img.shields.io/badge/status-experimental-orange)

> 📄 **[Full PRD → docs/PRD.md](docs/PRD.md)** — product thinking, success
> metrics, risks, roadmap. The README covers *how to use it*; the PRD covers
> *why it exists and how we know it's working*.

## What it does

- Adds a menu bar item showing current charge %.
- One-click cap at 50 / 60 / 70 / 80 %.
- Optional persistence: re-applies the cap on every boot via LaunchDaemon.

## Why

For lithium-ion cells stored at float voltage for long periods (always-on
laptops), calendar aging dominates. Capping at 60% reduces stress
substantially vs 100% with no functional cost if the battery is rarely asked
to deliver power. See [Battery University BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries).

## Compatibility

| macOS version           | Status            | Notes                                              |
| ----------------------- | ----------------- | -------------------------------------------------- |
| 12 Monterey and older   | Should work       | Untested but the SMC path is well-trodden          |
| 13 Ventura, 14 Sonoma   | Target platforms  | BCLM writes should succeed; binary may need Gatekeeper bypass |
| 15 Sequoia and newer    | Broken            | Kernel entitlement enforcement blocks SMC writes   |
| Apple Silicon (any)     | Not supported     | Uses `CHWA`, only 80 / 100 — out of scope here      |

Confirmed against: **MacBook Pro A1706 (13" with Touch Bar, 2016–2017)**
with `bq20z451` gauge chip. Should also work on the broader 2012–2017
Intel MBP range (A1502/A1398 Retina, A1707/A1708 Touch Bar generation).
The M1 dev machine this is built on cannot test the SMC write itself —
only the Intel target can validate that.

> ⚠️ **A1706 has no MagSafe LED.** Don't rely on visual charging feedback.
> Confirm the cap is working via `pmset -g batt` (shows "AC Power; not
> charging" at the cap) or `system_profiler SPPowerDataType`. The MagSafe
> LED test only applies to A1502/A1398 (2013–2015) Retina models.

## Build

Requires Xcode 15+ / Swift 5.9+ and macOS 13+.

```sh
git clone https://github.com/ebowwa/battery-cap.git
cd battery-cap
swift build -c release
```

The binary lands at `.build/release/BatteryCap`. To cross-compile for Intel
from an M1 host:

```sh
swift build -c release --arch x86_64
```

## Install

```sh
# Build first (see above), then:
./Scripts/install.sh
```

The installer:
1. Packages the binary into `/Applications/BatteryCap.app`.
2. Optional (`--persist`): installs a LaunchDaemon at
   `/Library/LaunchDaemons/com.ebowwa.battery-cap.plist` that re-applies the
   cap on boot. Prompts for sudo.

## Run

Launch `BatteryCap.app`. A battery icon appears in the menu bar. Click it to:

- See current charge %.
- Pick a preset cap (50 / 60 / 70 / 80).
- Pick **Set custom cap…** for any value 50–100. Pre-fills with
  `current charge + 3` (clamped) — the fastest plateau test value, since
  Intel firmware overshoots the BCLM target by ~3% on purpose.
- Remove cap (sets to 100%).
- Toggle persistence on boot.
- See conflict status (top of menu). `⚠️ ` prefix on the menu bar icon
  means another tool or setting may be fighting BatteryCap.

## Troubleshooting

### "I set the cap but the battery still charges to 100%"

This is almost always caused by a conflicting tool or macOS setting that
also writes the BCLM key. BatteryCap checks for these on launch and shows
a `⚠️ ` warning in the menu bar if any are detected. Click the warning to
see what's conflicting and how to fix it.

The detector checks for:

| Conflict | What it is | How to resolve |
| --- | --- | --- |
| macOS Optimized Battery Charging | macOS's own learning-based charge delay | System Settings → Battery → Battery Health → (i) → Off |
| AlDente (Free/Pro) | Writes BCLM on its own polling cycle | Quit AlDente + remove `/Library/LaunchDaemons/com.apphouseknight.aldente.*` |
| batt (`charlie0129/batt`) | Apple-Silicon-only tool, but the daemon may be present | Quit batt.app + remove its LaunchDaemon |
| bclm persistence (`zackelia/bclm`) | LaunchDaemon re-writes BCLM on every boot | `sudo bclm unpersist` |
| macOS native charge limit (macOS 26.4+) | Built-in chlim charge cap | System Settings → Battery → Charge Limit → Off |

### "Conflict detector says 'OBC status unknown'"

On macOS 26+, Apple moved Optimized Battery Charging out of `pmset -g`
into private preferences that aren't userland-readable. BatteryCap refuses
to guess — it surfaces this as "manual verify" rather than risk a
false-negative (silently telling you it's off when it isn't).

To verify manually:
1. Open System Settings → Battery → Battery Health
2. Click the (i) next to Battery Health
3. Confirm Optimized Battery Charging is **Off**

### "Detector says clean but cap still doesn't hold"

Rare, but possible causes:

1. **Cap value was overwritten manually** since the last BatteryCap write.
   Re-apply via the menu.
2. **A different SMC writer exists** that we don't detect (e.g., a custom
   script, smcFanControl plugin). Check `sudo fs_usage -w | grep SMC` for
   SMC activity from processes other than `BatteryCap`.
3. **macOS 15+ entitlement block**. If the target is on macOS 15 Sequoia
   or newer, BCLM writes are silently rejected. Check `sw_vers`.
4. **Hardware variant** we haven't tested. Run
   `sudo /Applications/BatteryCap.app/Contents/MacOS/BatteryCap --read`
   to verify the cap value is actually set in SMC.

### Diagnostic mode

```sh
# Run conflict detection without launching the UI:
/Applications/BatteryCap.app/Contents/MacOS/BatteryCap --detect-conflicts

# Check current BCLM value:
sudo /Applications/BatteryCap.app/Contents/MacOS/BatteryCap --read
```

### Reporting a bug

Capture these and open an issue:

```sh
sw_vers
sysctl hw.model
system_profiler SPPowerDataType
log show --predicate 'process == "BatteryCap"' --last 10m
BatteryCap --detect-conflicts
```

The SMC write itself prompts for an admin password each time (via native
macOS `osascript` dialog). Persistence removes that friction after the first
boot.

## How it works

```
menu bar app (user)
   │
   ├── reads battery % via IOKit IOPowerSources (no privs needed)
   │
   └── on "apply cap":
         osascript -e 'do shell script "<self> --write 60" with administrator privileges'
            │
            └── re-execs self as root, writes SMC BCLM key, exits
```

The same binary serves as both the menu bar app and its own privileged
helper — dispatch is by argv. No `SMJobBless`, no code-signing dance for v1.
When this gets folded into a larger macOS app, refactor to a real privileged
helper via `SMJobBless`.

## Acknowledgments

- [beltex/SMCKit](https://github.com/beltex/SMCKit) — MIT licensed Swift SMC
  IOKit code, vendored in `Sources/BatteryCap/SMC.swift`.
- [zackelia/bclm](https://github.com/zackelia/bclm) — Reference for the
  BCLM/BFCL write logic and LaunchDaemon persistence pattern.
- [charlie0129/batt](https://github.com/charlie0129/batt) — Apple Silicon
  equivalent; their docs on the broader landscape were very useful.

## License

MIT. See [LICENSE](LICENSE).
