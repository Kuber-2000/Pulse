import Cocoa
import QuartzCore
import Darwin

// MARK: - Sampling network interface byte counters

struct IfaceBytes {
    let rx: UInt32
    let tx: UInt32
}

func readBytes() -> [String: IfaceBytes] {
    var result: [String: IfaceBytes] = [:]
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
    defer { freeifaddrs(ifaddr) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        let iface = p.pointee
        if let addr = iface.ifa_addr,
           addr.pointee.sa_family == UInt8(AF_LINK),
           let data = iface.ifa_data {
            let name = String(cString: iface.ifa_name)
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = IfaceBytes(rx: d.ifi_ibytes, tx: d.ifi_obytes)
        }
        ptr = iface.ifa_next
    }
    return result
}

// MARK: - Hardware port labels (Wi-Fi, iPhone USB, Ethernet, …)

func loadHardwarePortLabels() -> [String: String] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    task.arguments = ["-listallhardwareports"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return [:] }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    var labels: [String: String] = [:]
    var currentPort: String?
    let portPrefix = "Hardware Port: "
    let devPrefix = "Device: "
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.hasPrefix(portPrefix) {
            currentPort = String(line.dropFirst(portPrefix.count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix(devPrefix), let port = currentPort {
            let dev = String(line.dropFirst(devPrefix.count)).trimmingCharacters(in: .whitespaces)
            labels[dev] = port
        }
    }
    return labels
}

// MARK: - String helpers

func padRight(_ s: String, to width: Int) -> String {
    if s.count > width {
        return String(s.prefix(width - 1)) + "…"
    }
    return s + String(repeating: " ", count: width - s.count)
}

func padLeft(_ s: String, to width: Int) -> String {
    if s.count >= width { return s }
    return String(repeating: " ", count: width - s.count) + s
}

// MARK: - Threshold-based status emoji

func cpuLoadEmoji(_ percent: Double) -> String {
    if percent >= 80 { return "🔥" }
    if percent >= 50 { return "⚡" }
    return "⚙️"
}

func cpuTempEmoji(_ celsius: Double) -> String {
    if celsius >= 80 { return "🔥" }
    if celsius >= 60 { return "🥵" }
    return "🌡️"
}

func fanEmoji(_ percent: Double) -> String {
    if percent >= 75 { return "💨" }
    if percent >= 40 { return "🌪️" }
    return "🌀"
}

func networkEmoji(_ totalMBps: Double) -> String {
    if totalMBps >= 5 { return "🚀" }
    if totalMBps >= 0.5 { return "📶" }
    return "💤"
}

/// Cross-fades a status bar button's title into place instead of snapping,
/// so emoji/tier changes read as a smooth transition rather than a flicker.
func setTitleAnimated(_ button: NSStatusBarButton?, _ newTitle: String) {
    guard let button = button, button.title != newTitle else { return }
    let transition = CATransition()
    transition.type = .fade
    transition.duration = 0.35
    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    button.layer?.add(transition, forKey: "titleFade")
    button.title = newTitle
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    // Network status item
    var netItem: NSStatusItem!
    var netMenu: NSMenu!
    // System (CPU + fan) status item
    var sysItem: NSStatusItem!
    var sysMenu: NSMenu!

    var lastBytes: [String: IfaceBytes] = [:]
    var lastSample: Date = Date()
    var hwLabels: [String: String] = [:]
    var lastLabelRefresh: Date = .distantPast
    var sampleTimer: Timer?

    // System sensors
    var prevCPU: CPUTicks?
    var lastCPUPercent: Double = 0
    let thermal = ThermalReader()
    var lastTempC: Double?
    var lastTempRead: Date = .distantPast
    let smc = SMC()
    var lastFans: [SMC.FanInfo] = []
    var lastFanRead: Date = .distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        let bar = NSStatusBar.system

        netItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        netItem.button?.wantsLayer = true
        netItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        netItem.button?.title = "💤↓0.0 ↑0.0"
        netItem.button?.toolTip = "Transfer speed (MB/s).\nTracks Wi-Fi, AirDrop, Ethernet, USB tether.\nUSB Finder/Photos transfers go via usbmuxd and aren't shown."
        netMenu = NSMenu()
        netMenu.autoenablesItems = false
        netItem.menu = netMenu

        sysItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        sysItem.button?.wantsLayer = true
        sysItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sysItem.button?.title = "⚙️-- 🌡️-- 🌀--"
        sysMenu = NSMenu()
        sysMenu.autoenablesItems = false
        sysItem.menu = sysMenu

        lastBytes = readBytes()
        lastSample = Date()
        hwLabels = loadHardwarePortLabels()
        lastLabelRefresh = Date()
        prevCPU = readCPUTicks()

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    func displayName(for iface: String) -> String {
        if let label = hwLabels[iface] { return "\(label) (\(iface))" }
        switch iface {
        case "awdl0": return "AirDrop / AWDL (\(iface))"
        case "llw0":  return "Low-latency Wi-Fi (\(iface))"
        case "lo0":   return "Loopback (\(iface))"
        default:
            if iface.hasPrefix("utun")   { return "VPN (\(iface))" }
            if iface.hasPrefix("bridge") { return "Bridge (\(iface))" }
            if iface.hasPrefix("anpi") || iface.hasPrefix("ap") { return "Apple internal (\(iface))" }
            return iface
        }
    }

    func isInteresting(_ iface: String) -> Bool {
        if iface == "lo0" { return false }
        if iface.hasPrefix("utun") { return false }
        if iface.hasPrefix("gif") || iface.hasPrefix("stf") { return false }
        if iface.hasPrefix("anpi") || iface.hasPrefix("ap") { return false }
        if iface.hasPrefix("XHC") { return false }
        return iface.hasPrefix("en")
            || iface.hasPrefix("awdl")
            || iface.hasPrefix("llw")
            || iface.hasPrefix("bridge")
    }

    struct Row {
        let iface: String
        let label: String
        let rx: Double
        let tx: Double
        var total: Double { rx + tx }
    }

    func tick() {
        let now = Date()

        if now.timeIntervalSince(lastLabelRefresh) > 30.0 {
            hwLabels = loadHardwarePortLabels()
            lastLabelRefresh = now
        }

        let dt = now.timeIntervalSince(lastSample)
        guard dt > 0 else { return }
        let current = readBytes()

        var rows: [Row] = []
        for (iface, bytes) in current {
            guard isInteresting(iface) else { continue }
            guard let prev = lastBytes[iface] else { continue }
            // 32-bit wrap-aware delta, then convert to MB/s (decimal megabytes).
            let dRx = Double(bytes.rx &- prev.rx) / dt / 1_000_000.0
            let dTx = Double(bytes.tx &- prev.tx) / dt / 1_000_000.0
            rows.append(Row(iface: iface, label: displayName(for: iface), rx: dRx, tx: dTx))
        }
        rows.sort { $0.total > $1.total }

        // CPU load every tick (cheap)
        if let curr = readCPUTicks() {
            if let prev = prevCPU {
                lastCPUPercent = cpuLoadPercent(prev: prev, curr: curr)
            }
            prevCPU = curr
        }

        // CPU temp throttled (IOHID iteration is the slow part)
        if now.timeIntervalSince(lastTempRead) >= 3.0 {
            lastTempC = thermal?.readCPUTemperature()
            lastTempRead = now
        }

        // Fan info throttled (SMC reads are slow)
        if now.timeIntervalSince(lastFanRead) >= 4.0 {
            lastFans = smc?.readAllFans() ?? []
            lastFanRead = now
        }

        // ── Network status item ──
        let peak = rows.first
        let peakRx = peak?.rx ?? 0
        let peakTx = peak?.tx ?? 0
        let netTotal = peakRx + peakTx
        setTitleAnimated(netItem.button, String(format: "%@↓%.1f ↑%.1f", networkEmoji(netTotal), peakRx, peakTx))

        // ── System status item ──
        let cpuStr = String(format: "%@%.0f%%", cpuLoadEmoji(lastCPUPercent), lastCPUPercent)
        let tempStr: String
        if let t = lastTempC {
            tempStr = String(format: "%@%.0f°", cpuTempEmoji(t), t)
        } else {
            tempStr = "🌡️—"
        }
        let fanStr: String
        let fanTooltip: String
        if let primary = lastFans.first {
            fanStr = String(format: "%@%.0f%%", fanEmoji(primary.percent), primary.percent)
            fanTooltip = lastFans.enumerated().map { i, f in
                let label = lastFans.count == 1 ? "Fan" : "Fan \(i + 1)"
                return String(format: "%@: %.0f rpm  (%.0f%% of %.0f max)", label, f.rpm, f.percent, f.maxRPM)
            }.joined(separator: "\n")
        } else {
            fanStr = "🌀—"
            fanTooltip = "No fans detected (fanless Mac or SMC unavailable)."
        }
        setTitleAnimated(sysItem.button, "\(cpuStr) \(tempStr) \(fanStr)")

        var sysTooltip = String(format: "⚙️ CPU load: %.0f%%", lastCPUPercent)
        if let t = lastTempC {
            sysTooltip += String(format: "\n🌡️ CPU temp: %.0f °C", t)
        }
        sysTooltip += "\n" + fanTooltip
        sysItem.button?.toolTip = sysTooltip

        rebuildNetMenu(rows: rows)
        rebuildSysMenu()

        lastBytes = current
        lastSample = now
    }

    // Menu styling helpers

    private func addSectionHeader(to menu: NSMenu, title: String) {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addRow(to menu: NSMenu, label: String, value: String, labelWidth: Int = 22, valueWidth: Int = 14) {
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let labelStr = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        let valueStr = String(repeating: " ", count: max(0, valueWidth - value.count)) + value

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: labelStr, attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor
        ]))
        s.append(NSAttributedString(string: valueStr, attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor
        ]))

        let item = NSMenuItem()
        item.attributedTitle = s
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addNetworkRow(to menu: NSMenu, label: String, rx: Double, tx: Double) {
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let truncated = label.count > 22 ? String(label.prefix(21)) + "…" : label
        let labelStr = truncated.padding(toLength: 22, withPad: " ", startingAt: 0)

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: labelStr, attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor
        ]))
        s.append(NSAttributedString(string: "↓ ", attributes: [
            .font: mono, .foregroundColor: NSColor.tertiaryLabelColor
        ]))
        s.append(NSAttributedString(string: String(format: "%5.2f", rx), attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor
        ]))
        s.append(NSAttributedString(string: "   ↑ ", attributes: [
            .font: mono, .foregroundColor: NSColor.tertiaryLabelColor
        ]))
        s.append(NSAttributedString(string: String(format: "%5.2f", tx), attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor
        ]))

        let item = NSMenuItem()
        item.attributedTitle = s
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addPlaceholder(to menu: NSMenu, text: String) {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        item.isEnabled = false
        menu.addItem(item)
    }

    func rebuildNetMenu(rows: [Row]) {
        netMenu.removeAllItems()
        addSectionHeader(to: netMenu, title: "Transfer  ·  MB/s")
        if rows.isEmpty {
            addPlaceholder(to: netMenu, text: "No active interfaces")
        } else {
            for row in rows {
                addNetworkRow(to: netMenu, label: row.label, rx: row.rx, tx: row.tx)
            }
        }
        netMenu.addItem(.separator())
        netMenu.addItem(NSMenuItem(title: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func rebuildSysMenu() {
        sysMenu.removeAllItems()
        addSectionHeader(to: sysMenu, title: "⚙️ CPU")
        addRow(to: sysMenu, label: "Load", value: String(format: "%.0f %%", lastCPUPercent))
        if let t = lastTempC {
            addRow(to: sysMenu, label: "Temperature", value: String(format: "%.0f °C", t))
        } else {
            addRow(to: sysMenu, label: "Temperature", value: "—")
        }

        sysMenu.addItem(.separator())
        addSectionHeader(to: sysMenu, title: "🌀 Fans")
        if lastFans.isEmpty {
            addPlaceholder(to: sysMenu, text: "Fanless / not exposed")
        } else {
            for (i, fan) in lastFans.enumerated() {
                let label = lastFans.count == 1 ? "Fan" : "Fan \(i + 1)"
                let value = String(format: "%.0f %%   %.0f rpm", fan.percent, fan.rpm)
                addRow(to: sysMenu, label: label, value: value, labelWidth: 14, valueWidth: 22)
            }
        }

        sysMenu.addItem(.separator())
        sysMenu.addItem(NSMenuItem(title: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
