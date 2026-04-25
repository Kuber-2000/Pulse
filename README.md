# Pulse

A tiny **macOS menu-bar** tool that shows live network transfer speed, CPU load, CPU temperature, and fan speed — at a glance, without leaving your menu bar.

```
↓ 12.3  ↑ 0.4        CPU 42%  Fan 35%
└── Network ──┘      └─── System ────┘
```

Two compact menu bar items:

- **Network** — peak interface's download / upload speed in MB/s
- **System** — CPU load percentage and primary fan speed (% of max RPM)

Click either for a detailed dropdown. Hover the System item for live RPM / temp readout.

---

## Features

- **Real network throughput** — sampled from `getifaddrs` byte counters every second, across **Wi‑Fi, AirDrop (AWDL), Ethernet, and USB tether** interfaces
- **Per-interface breakdown** in the network dropdown, sorted by activity
- **Smart labels** — uses `networksetup -listallhardwareports` so your iPhone shows up as "iPhone USB", not `en7`
- **CPU load** — total active % across all logical cores (`host_statistics`)
- **CPU temperature** — hot-spot of the CPU die sensors (works on Apple Silicon **and** Intel)
- **Fan speed** — RPM and % saturation between `F0Mn` and `F0Mx` SMC keys
- **Auto-launch at login** via a LaunchAgent (no Login Items dance)
- **No telemetry, no ads, no signing fees, no install bloat** — single self-contained `.app`, ~150 KB binary
- ~**500 lines of Swift**, zero dependencies

---

## Requirements

- macOS 11+ (tested on Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`) — needed for `swiftc`

---

## Build & install

```sh
git clone https://github.com/Kuber-2000/Pulse.git
cd Pulse
./build.sh
open Pulse.app
```

That's it. A `Pulse.app` bundle is produced next to the source.

To install permanently:

```sh
mv Pulse.app /Applications/
```

---

## Auto-launch at login

Edit the included template and load it:

```sh
# 1. Copy the template, edit the path inside if your Pulse.app lives elsewhere
cp launchagent.plist ~/Library/LaunchAgents/local.pulse.plist

# 2. Bootstrap it for the current user
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.pulse.plist
```

Pulse now launches every time you log in. Quit from the menu still works (it stays quit until next login — `KeepAlive` is `false`).

To turn it off:

```sh
launchctl bootout "gui/$(id -u)/local.pulse"
rm ~/Library/LaunchAgents/local.pulse.plist
```

---

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/local.pulse" 2>/dev/null
rm -f  ~/Library/LaunchAgents/local.pulse.plist
rm -rf /Applications/Pulse.app
# also wherever you cloned the source
```

---

## How it works

| What | API used |
|------|----------|
| Network bytes | `getifaddrs` → `if_data.ifi_ibytes` / `ifi_obytes`, 32-bit wrap-aware delta |
| CPU load | `host_statistics(HOST_CPU_LOAD_INFO)` — user / system / idle / nice ticks |
| CPU temperature | `IOHIDEventSystemClient` thermal sensors (private, dlsym) — same as Stats / iStat Menus |
| Fan RPM + min/max | SMC via `IOConnectCallStructMethod` — `FNum`, `F<i>Ac`, `F<i>Mn`, `F<i>Mx` |

Sampling cadence:
- Network bytes & CPU ticks: every 1 s
- CPU temperature: every 1 s
- Fan RPM: every 2 s (SMC reads are slow)

---

## Limitations

- **USB file transfers via Finder / Photos / iMazing won't show up.** They go through `usbmuxd` over a Unix socket — *not* a network interface. AirDrop and USB tether work fine because both are real interfaces.
- **CPU temperature uses a private API** (`IOHIDEventSystemClient*` symbols). It's the same approach every popular Mac stats app uses, but Apple makes no guarantee. If a future macOS removes those symbols, the temperature row falls back to "—" cleanly.
- **Fanless Macs** (MacBook Air, base Mac mini) report no fans — the row will say "Fanless / not exposed".
- **Sensor names vary by Mac model.** The temperature reader matches `tdie`, `pACC`, `eACC`, `CPU`, `TC0*`, `TCXC`. If your Mac uses something else, the reader falls back to averaging all available thermal sensors. Run `dump_thermal.swift` to inspect what your machine exposes.

---

## Project layout

```
Pulse/
├── main.swift          # AppKit menu-bar app, two NSStatusItems
├── Sensors.swift       # CPU ticks, IOHID thermal, SMC fan
├── Info.plist          # Bundle identity, LSUIElement = true
├── build.sh            # swiftc + bundle
├── launchagent.plist   # Login-launch template
├── dump_thermal.swift  # Standalone tool: list every IOHID temp sensor
├── README.md
└── LICENSE
```

---

## Donate

If Pulse saved you the cost of an iStat Menus license and you'd like to chip in, I'd be honored:

> **PhonePe / GPay (India): +91 8237916679**

A star on the repo also goes a long way. No pressure — the tool is free to use either way.

---

## License

[MIT](LICENSE) — do what you want, no warranty.
