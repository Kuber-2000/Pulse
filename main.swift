import Cocoa
import QuartzCore
import Darwin
import ServiceManagement

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

// Tiers align with fmtSpeed's units: 🐢 covers exactly the KB/s display range.
func networkEmoji(_ totalMBps: Double) -> String {
    if totalMBps >= 5      { return "🚀" }
    if totalMBps >= 0.9995 { return "📶" }
    if totalMBps >= 0.01   { return "🐢" }
    return "💤"
}

// MARK: - Value formatting

/// Formats a MB/s value for the menu bar: KB/s below 1 MB/s so light traffic
/// shows as "340K" instead of a dead-looking "0.0".
func fmtSpeed(_ mbps: Double) -> String {
    if mbps < 0.0005 { return "0" }
    if mbps < 0.9995 { return String(format: "%.0fK", mbps * 1000) }
    if mbps < 99.95  { return String(format: "%.1f", mbps) }
    return String(format: "%.0f", mbps)
}

/// Same, but with an explicit unit for dropdown rows.
func fmtSpeedUnit(_ mbps: Double) -> String {
    if mbps < 0.9995 { return String(format: "%.0f KB/s", mbps * 1000) }
    return String(format: "%.1f MB/s", mbps)
}

func fmtBytes(_ bytes: UInt64) -> String {
    let b = Double(bytes)
    if b >= 1e9 { return String(format: "%.2f GB", b / 1e9) }
    if b >= 1e6 { return String(format: "%.1f MB", b / 1e6) }
    return String(format: "%.0f KB", b / 1e3)
}

// MARK: - Sparkline

let sparkChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

/// Renders values as a block-character sparkline, scaled to `cap`
/// (or the series max when cap is nil).
func sparkline(_ values: [Double], cap: Double? = nil) -> String {
    guard !values.isEmpty else { return "" }
    let top = max(cap ?? values.max() ?? 1, 0.000001)
    return String(values.map { v -> Character in
        let idx = Int(min(max(v, 0), top) / top * 7.0)
        return sparkChars[min(idx, 7)]
    })
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

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    var currentInterval: TimeInterval = 0
    // Adaptive cadence: sample fast during heavy transfer, drop back when quiet to save battery.
    // Enter/exit thresholds differ (hysteresis) so the tier doesn't flap around one value.
    static let fastInterval: TimeInterval = 0.5
    static let idleInterval: TimeInterval = 2.0
    static let fastEnterMBps: Double = 5.0
    static let fastExitMBps: Double = 3.0

    // Dropdown state — menus are only rebuilt (and disk only sampled) while open.
    var netMenuOpen = false
    var sysMenuOpen = false
    var lastRows: [Row] = []

    // Sparkline history (last 60 samples)
    var netHistory: [Double] = []
    var cpuHistory: [Double] = []

    // Session data totals since launch
    var sessionRx: UInt64 = 0
    var sessionTx: UInt64 = 0

    // Disk I/O — sampled only while the System dropdown is open
    var lastDiskBytes: (read: UInt64, write: UInt64)?
    var lastDiskSample: Date = .distantPast
    var diskReadMBps: Double?
    var diskWriteMBps: Double?

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
        netMenu.delegate = self
        netItem.menu = netMenu

        sysItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        sysItem.button?.wantsLayer = true
        sysItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sysItem.button?.title = "⚙️-- 🌡️-- 🌀--"
        sysMenu = NSMenu()
        sysMenu.autoenablesItems = false
        sysMenu.delegate = self
        sysItem.menu = sysMenu

        lastBytes = readBytes()
        lastSample = Date()
        hwLabels = loadHardwarePortLabels()
        lastLabelRefresh = Date()
        prevCPU = readCPUTicks()

        setupScreenObservers()
        scheduleTimer(interval: Self.idleInterval)
    }

    /// Pause sampling while the screen is asleep or locked — the menu bar is
    /// invisible then, so ticking would only burn battery.
    func setupScreenObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pauseSampling()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resumeSampling()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.pauseSampling()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.resumeSampling()
        }
    }

    func pauseSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    func resumeSampling() {
        guard sampleTimer == nil else { return }
        // Re-baseline so the first tick after waking doesn't average over the whole sleep.
        lastBytes = readBytes()
        lastSample = Date()
        prevCPU = readCPUTicks()
        scheduleTimer(interval: Self.idleInterval)
    }

    func scheduleTimer(interval: TimeInterval) {
        sampleTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
        currentInterval = interval
    }

    // MARK: NSMenuDelegate — rebuild dropdowns only while someone is looking

    func menuWillOpen(_ menu: NSMenu) {
        if menu === netMenu {
            netMenuOpen = true
            rebuildNetMenu(rows: lastRows)
        } else if menu === sysMenu {
            sysMenuOpen = true
            // Disk rates need two samples; take the baseline now, the next tick fills it in.
            lastDiskBytes = readDiskBytes()
            lastDiskSample = Date()
            diskReadMBps = nil
            diskWriteMBps = nil
            rebuildSysMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === netMenu {
            netMenuOpen = false
        } else if menu === sysMenu {
            sysMenuOpen = false
            diskReadMBps = nil
            diskWriteMBps = nil
        }
    }

    // MARK: Launch at login (SMAppService, macOS 13+)

    var launchAtLoginEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Pulse: launch-at-login toggle failed: \(error)")
        }
        sender.state = launchAtLoginEnabled ? .on : .off
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
            let dRxBytes = UInt64(bytes.rx &- prev.rx)
            let dTxBytes = UInt64(bytes.tx &- prev.tx)
            // A counter reset (Wi-Fi toggle, VPN reconnect) underflows the wrap-aware
            // delta into a multi-GB/s phantom spike — drop that sample instead.
            let maxPlausible = UInt64(2_000_000_000.0 * dt)
            guard dRxBytes < maxPlausible, dTxBytes < maxPlausible else { continue }
            let dRx = Double(dRxBytes) / dt / 1_000_000.0
            let dTx = Double(dTxBytes) / dt / 1_000_000.0
            sessionRx &+= dRxBytes
            sessionTx &+= dTxBytes
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
        setTitleAnimated(netItem.button, String(format: "%@↓%@ ↑%@", networkEmoji(netTotal), fmtSpeed(peakRx), fmtSpeed(peakTx)))

        netHistory.append(netTotal)
        cpuHistory.append(lastCPUPercent)
        if netHistory.count > 60 { netHistory.removeFirst(netHistory.count - 60) }
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }

        // Disk I/O — only while the System dropdown is visible
        if sysMenuOpen, let curr = readDiskBytes() {
            if let prev = lastDiskBytes {
                let ddt = now.timeIntervalSince(lastDiskSample)
                if ddt > 0 {
                    diskReadMBps  = Double(curr.read &- prev.read) / ddt / 1_000_000.0
                    diskWriteMBps = Double(curr.write &- prev.write) / ddt / 1_000_000.0
                }
            }
            lastDiskBytes = curr
            lastDiskSample = now
        }

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

        lastRows = rows
        if netMenuOpen { rebuildNetMenu(rows: rows) }
        if sysMenuOpen { rebuildSysMenu() }

        lastBytes = current
        lastSample = now

        let threshold = currentInterval == Self.fastInterval ? Self.fastExitMBps : Self.fastEnterMBps
        let wanted = netTotal > threshold ? Self.fastInterval : Self.idleInterval
        if wanted != currentInterval {
            scheduleTimer(interval: wanted)
        }
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

    private func addSparklineRow(to menu: NSMenu, values: [Double], cap: Double? = nil, legend: String) {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: sparkline(values, cap: cap), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.controlAccentColor,
        ]))
        s.append(NSAttributedString(string: "  " + legend, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        let item = NSMenuItem()
        item.attributedTitle = s
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addFooter(to menu: NSMenu) {
        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
            login.target = self
            login.state = launchAtLoginEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(NSMenuItem(title: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        if netHistory.count >= 2 {
            netMenu.addItem(.separator())
            addSparklineRow(to: netMenu, values: netHistory,
                            legend: "peak " + fmtSpeedUnit(netHistory.max() ?? 0))
        }
        netMenu.addItem(.separator())
        addSectionHeader(to: netMenu, title: "Session")
        addRow(to: netMenu, label: "Downloaded", value: fmtBytes(sessionRx))
        addRow(to: netMenu, label: "Uploaded", value: fmtBytes(sessionTx))
        addFooter(to: netMenu)
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

        if cpuHistory.count >= 2 {
            addSparklineRow(to: sysMenu, values: cpuHistory, cap: 100, legend: "load")
        }

        sysMenu.addItem(.separator())
        addSectionHeader(to: sysMenu, title: "🧠 Memory")
        if let mem = readMemory() {
            let gib = 1073741824.0
            let used = String(format: "%.1f / %.0f GB  (%.0f %%)",
                              Double(mem.usedBytes) / gib, Double(mem.totalBytes) / gib, mem.usedPercent)
            addRow(to: sysMenu, label: "Used", value: used, labelWidth: 14, valueWidth: 22)
            addRow(to: sysMenu, label: "Compressed", value: fmtBytes(mem.compressedBytes), labelWidth: 14, valueWidth: 22)
        } else {
            addPlaceholder(to: sysMenu, text: "Unavailable")
        }

        sysMenu.addItem(.separator())
        addSectionHeader(to: sysMenu, title: "💽 Disk")
        if let r = diskReadMBps, let w = diskWriteMBps {
            addRow(to: sysMenu, label: "Read", value: fmtSpeedUnit(r), labelWidth: 14, valueWidth: 22)
            addRow(to: sysMenu, label: "Write", value: fmtSpeedUnit(w), labelWidth: 14, valueWidth: 22)
        } else {
            addPlaceholder(to: sysMenu, text: "Measuring…")
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

        addFooter(to: sysMenu)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
