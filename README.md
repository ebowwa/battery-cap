# BatteryCap

A minimal macOS menu bar app to cap battery charge on Intel MacBooks via the
SMC `BCLM` key. The DIY equivalent of AlDente — about 300 lines of Swift.

![status: experimental](https://img.shields.io/badge/status-experimental-orange)

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

Confirmed against: MacBook Pro Retina 13"/15" with `bq20z451` gauge chip
(2013–2015 models). The M1 dev machine this is built on cannot test the SMC
write itself — only the Intel target can validate that.

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
- Pick a cap (50 / 60 / 70 / 80 / off).
- Toggle persistence on boot.

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
