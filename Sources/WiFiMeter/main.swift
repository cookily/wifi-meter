// WiFiMeter — macOS 菜单栏 Wi-Fi 流量统计
// 口径：一次"连接会话" = 持续关联同一 SSID 的时段；断开或切换网络即分段。
// 每段记录起止时间与收发字节数；同一天同一 SSID 的各段合计为当日用量。

import AppKit
import CoreWLAN
import CoreLocation
import ServiceManagement
import Darwin

// MARK: - 格式化

private let hmFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
private let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let fullFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()
private let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

func fmtBytes(_ b: UInt64) -> String {
    let v = Double(b)
    if v >= 1024 * 1024 * 1024 { return String(format: "%.2f GB", v / (1024 * 1024 * 1024)) }
    if v >= 1024 * 1024 { return String(format: "%.1f MB", v / (1024 * 1024)) }
    if v >= 1024 { return String(format: "%.0f KB", v / 1024) }
    return "\(b) B"
}

func fmtDuration(_ sec: TimeInterval) -> String {
    let t = Int(sec), h = t / 3600, m = (t % 3600) / 60
    if h > 0 { return "\(h)小时\(m)分" }
    if m >= 1 { return "\(m)分钟" }
    return "不足1分钟"
}

func weekday(_ d: Date) -> String {
    weekdayNames[Calendar.current.component(.weekday, from: d) - 1]
}

// MARK: - 数据模型

struct Session: Codable {
    var ssid: String      // 网络名；未授权定位时为 "Wi-Fi(en0)" 这类接口名标签
    var iface: String     // 网卡名，如 en0
    var start: Date
    var end: Date?        // 进行中为 nil
    var rx: UInt64
    var tx: UInt64
    var open: Bool

    var bytes: UInt64 { rx &+ tx }
}

/// state.json：正在进行的会话 + 采样基线（用于应用重启后判断能否续接同一会话）
struct OpenState: Codable {
    var session: Session
    var lastRx: UInt64    // 最近一次看到的接口原始计数
    var lastTx: UInt64
    var lastSeen: Date
}

// MARK: - 存储

final class Store {
    let dir: URL
    var sessions: [Session] = []
    var open: OpenState?
    var dirty = false

    private var sessionsURL: URL { dir.appendingPathComponent("sessions.jsonl") }
    private var stateURL: URL { dir.appendingPathComponent("state.json") }

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WiFiMeter", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
        load()
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: stateURL),
           let st = try? dec.decode(OpenState.self, from: data) {
            open = st
        }
        guard let text = try? String(contentsOf: sessionsURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8), let s = try? dec.decode(Session.self, from: d) {
                sessions.append(s)
            }
        }
    }

    func begin(ssid: String, iface: String, at: Date) {
        let s = Session(ssid: ssid, iface: iface, start: at, end: nil, rx: 0, tx: 0, open: true)
        open = OpenState(session: s, lastRx: 0, lastTx: 0, lastSeen: at)
        dirty = true
    }

    func close(at end: Date) {
        guard let st = open else { return }
        var s = st.session
        s.end = end
        s.open = false
        append(s)
        open = nil
        dirty = true
        saveState()
    }

    /// 应用重启后若无法续接旧会话（换了网络/超过宽限期/计数器清零），按旧时间落盘
    func finalizeStored() {
        guard let st = open else { return }
        close(at: st.lastSeen)
    }

    private func append(_ s: Session) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let line = try? enc.encode(s), var out = String(data: line, encoding: .utf8) {
            out.append("\n")
            if let fh = FileHandle(forWritingAtPath: sessionsURL.path) {
                fh.seekToEndOfFile()
                fh.write(out.data(using: .utf8)!)
                try? fh.close()
            } else {
                try? out.data(using: .utf8)?.write(to: sessionsURL)
            }
        }
        sessions.append(s)
    }

    func flush() {
        guard dirty else { return }
        saveState()
        dirty = false
    }

    private func saveState() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let st = open, let data = try? enc.encode(st) {
            try? data.write(to: stateURL)
        } else {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    func resetAll() {
        open = nil
        sessions = []
        try? FileManager.default.removeItem(at: sessionsURL)
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: 聚合

    struct DayRow {
        let day: Date
        let perSSID: [(ssid: String, bytes: UInt64)]
        let total: UInt64
    }

    func dailyRows(days: Int) -> [DayRow] {
        let cal = Calendar.current
        var per: [Date: [String: UInt64]] = [:]
        var all = sessions
        if let o = open { all.append(o.session) }
        for s in all {
            let d = cal.startOfDay(for: s.start)
            per[d, default: [:]][s.ssid, default: 0] += s.bytes
        }
        let today = cal.startOfDay(for: Date())
        var rows: [DayRow] = []
        for i in 0..<days {
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            guard let dict = per[d] else {
                if i == 0 { rows.append(DayRow(day: d, perSSID: [], total: 0)) }
                continue
            }
            let list = dict.map { (ssid: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
            rows.append(DayRow(day: d, perSSID: list, total: list.reduce(0) { $0 + $1.bytes }))
        }
        return rows
    }

    func ssidTotals() -> [(ssid: String, bytes: UInt64)] {
        var dict: [String: UInt64] = [:]
        var all = sessions
        if let o = open { all.append(o.session) }
        for s in all { dict[s.ssid, default: 0] += s.bytes }
        return dict.map { (ssid: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    func recentSessions(_ n: Int) -> [Session] {
        var all = sessions
        if let o = open { all.append(o.session) }
        return Array(all.sorted { ($0.end ?? $0.start) > ($1.end ?? $1.start) }.prefix(n))
    }

    func todayBytes(ssid: String) -> UInt64 {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var all = sessions
        if let o = open { all.append(o.session) }
        return all.filter { cal.startOfDay(for: $0.start) == today && $0.ssid == ssid }
            .reduce(0) { $0 + $1.bytes }
    }
}

// MARK: - 采样

final class Monitor {
    private let store: Store
    private var counters: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var nilSince: [String: Date] = [:]   // 已授权但 SSID 瞬时读不到的时刻（漫游抖动）
    private var ipconfigCache: (iface: String, ssid: String?, at: Date) = ("", nil, .distantPast)
    private let locationManager = CLLocationManager()
    /// 已授权定位（授权后才可能读到真实 SSID）
    var locationAuthorized: Bool {
        CLLocationManager.authorizationStatus() == .authorized
    }

    var locationStatus: CLAuthorizationStatus { CLLocationManager.authorizationStatus() }

    func requestLocationAuth() {
        locationManager.requestWhenInUseAuthorization()
    }

    init(store: Store) { self.store = store }

    struct WiFiInfo { let iface: String; let ssid: String?; let associated: Bool }

    func primaryWiFi() -> WiFiInfo? {
        guard let list = CWWiFiClient.shared().interfaces(), let w = list.first else { return nil }
        let name = w.interfaceName ?? "en0"
        var ssid = w.ssid()
        if ssid == nil, let d = w.ssidData(), let s = String(data: d, encoding: .utf8) { ssid = s }
        var associated = w.interfaceMode() != .none
        if ssid == nil {
            // 免授权兜底（旧版 macOS 可用；新版会返回 "<redacted>"，需过滤）
            if let s = ssidViaIpconfig(name), !s.localizedCaseInsensitiveContains("redact") {
                ssid = s
                associated = true
            }
        }
        return WiFiInfo(iface: name, ssid: ssid, associated: associated)
    }

    private func ssidViaIpconfig(_ iface: String) -> String? {
        if ipconfigCache.iface == iface, Date().timeIntervalSince(ipconfigCache.at) < 30 {
            return ipconfigCache.ssid
        }
        var result: String? = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        p.arguments = ["getsummary", iface]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard l.lowercased().hasPrefix("ssid") else { continue }
                    let after = l.dropFirst(4).drop { $0 == " " || $0 == ":" || $0 == "=" }
                    var v = String(after).trimmingCharacters(in: .whitespaces)
                    v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !v.isEmpty { result = v; break }
                }
            }
        }
        ipconfigCache = (iface, result, Date())
        return result
    }

    /// 接口字节计数（AF_LINK 条目，开机以来的累计值；用差值即可，无需 64 位总量的 sysctl）
    func rawCounters(_ iface: String) -> (rx: UInt64, tx: UInt64)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p = ifap
        while let cur = p {
            let ifa = cur.pointee
            if let nameC = ifa.ifa_name, String(cString: nameC) == iface,
               let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let d = ifa.ifa_data {
                let sd = d.assumingMemoryBound(to: if_data.self).pointee
                rx &+= UInt64(sd.ifi_ibytes)
                tx &+= UInt64(sd.ifi_obytes)
            }
            p = ifa.ifa_next
        }
        return (rx, tx)
    }

    func poll() {
        let now = Date()
        guard let w = primaryWiFi(), w.associated else {
            if let st = store.open { store.close(at: st.lastSeen) }
            return
        }
        let iface = w.iface

        var label: String?
        if let s = w.ssid {
            label = s
            nilSince[iface] = nil
        } else if !locationAuthorized {
            // 未授权定位：读不到名字，但连接状态和流量计数都真实可用
            label = "Wi-Fi(\(iface))"
            nilSince[iface] = nil
        } else {
            // 已授权但瞬时读不到（漫游抖动）：30 秒内维持当前会话不断段
            let firstNil = nilSince[iface] ?? now
            if nilSince[iface] == nil { nilSince[iface] = now }
            if now.timeIntervalSince(firstNil) < 30 {
                if var st = store.open, st.session.iface == iface {
                    if let last = counters[iface] { st.lastRx = last.rx; st.lastTx = last.tx }
                    st.lastSeen = now
                    store.open = st
                    store.dirty = true
                    return
                }
            }
        }

        guard let ssid = label else {
            if let st = store.open, st.session.iface == iface { store.close(at: st.lastSeen) }
            return
        }

        let raw = rawCounters(iface) ?? (0, 0)
        var dRx: UInt64 = 0, dTx: UInt64 = 0
        if let last = counters[iface] {
            // 计数器变小 = 重启/驱动重置，不产生负增量
            if raw.rx >= last.rx { dRx = raw.rx - last.rx }
            if raw.tx >= last.tx { dTx = raw.tx - last.tx }
        }
        counters[iface] = raw

        if var st = store.open {
            if st.session.ssid == ssid && st.session.iface == iface {
                st.session.rx &+= dRx
                st.session.tx &+= dTx
                st.lastSeen = now
                st.lastRx = raw.rx
                st.lastTx = raw.tx
                store.open = st
                store.dirty = true
            } else {
                store.close(at: st.lastSeen)
                store.begin(ssid: ssid, iface: iface, at: now)
            }
        } else {
            store.begin(ssid: ssid, iface: iface, at: now)
        }
    }

    /// 应用启动时：判断磁盘上遗留的进行中会话能否续接（同一网络 + 5 分钟内 + 计数器未清零）
    func adoptStoredState() {
        guard let st = store.open else { return }
        let now = Date()
        guard now.timeIntervalSince(st.lastSeen) < 300,
              let w = primaryWiFi(), w.associated,
              w.iface == st.session.iface,
              w.ssid == st.session.ssid,
              let raw = rawCounters(w.iface),
              raw.rx >= st.lastRx, raw.tx >= st.lastTx else {
            store.finalizeStored()
            return
        }
        counters[w.iface] = (st.lastRx, st.lastTx)
    }
}

// MARK: - 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    lazy var monitor = Monitor(store: store)
    var statusItem: NSStatusItem?
    var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        // 菜单栏应用常驻采样，禁用 App Nap 防止系统挂起计时器
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Wi-Fi 流量采样")
        monitor.adoptStoredState()
        monitor.poll()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: "Wi-Fi 流量")
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusItem = item
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateTitle()

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.monitor.poll()
            self?.updateTitle()
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.store.flush()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.poll()
            self?.updateTitle()
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.flush()
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        let had = store.open != nil
        monitor.poll()
        if had, let st = store.open {
            store.close(at: st.lastSeen)
        } else {
            store.flush()
        }
    }

    func updateTitle() {
        guard let btn = statusItem?.button else { return }
        if let st = store.open {
            let bytes = store.todayBytes(ssid: st.session.ssid)
            btn.title = bytes > 0 ? " " + fmtBytes(bytes) : ""
            btn.appearsDisabled = false
        } else {
            btn.title = ""
            btn.appearsDisabled = true
        }
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        monitor.poll()
        updateTitle()
        rebuild(menu)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, action: Selector? = nil, sub: NSMenu? = nil, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action != nil && action != #selector(NSApplication.terminate(_:)) { it.target = self }
        if let sub = sub { it.submenu = sub }
        menu.addItem(it)
        return it
    }

    private func info(_ menu: NSMenu, _ title: String) {
        let it = add(menu, title)
        it.isEnabled = false
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        info(menu, "📶 Wi-Fi 流量统计（仅本机）")

        if let st = store.open {
            info(menu, "● 当前网络：\(st.session.ssid)")
            info(menu, "   本次连接 \(hmFmt.string(from: st.session.start)) 起 · 已 \(fmtDuration(Date().timeIntervalSince(st.session.start)))")
            info(menu, "   本次用量 ↓\(fmtBytes(st.session.rx))  ↑\(fmtBytes(st.session.tx))")
        } else {
            info(menu, "● 未连接 Wi-Fi（暂停统计）")
        }

        // 未授权定位的提示/入口
        if let st = store.open, st.session.ssid.hasPrefix("Wi-Fi(") {
            menu.addItem(.separator())
            switch monitor.locationStatus {
            case .notDetermined:
                add(menu, "🔒 授权读取 Wi-Fi 名称…", action: #selector(requestLocation))
            default:
                add(menu, "🔒 需「定位服务」权限才能显示网络名（点此打开设置）", action: #selector(openLocationSettings))
            }
        }

        let today = store.dailyRows(days: 1).first
        if let t = today, !t.perSSID.isEmpty {
            menu.addItem(.separator())
            info(menu, "— 今日各网络 —")
            let cur = store.open?.session.ssid
            for row in t.perSSID.prefix(8) {
                info(menu, "\(row.ssid == cur ? "●" : "○") \(row.ssid)：\(fmtBytes(row.bytes))")
            }
        }

        menu.addItem(.separator())

        let recent = store.recentSessions(12)
        if !recent.isEmpty {
            let sub = NSMenu()
            for s in recent {
                let line = "\(fullFmt.string(from: s.start)) – \(hmFmt.string(from: s.end ?? Date()))　\(s.ssid)　\(fmtBytes(s.bytes))（↓\(fmtBytes(s.rx)) ↑\(fmtBytes(s.tx))）"
                let it = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                it.isEnabled = false
                sub.addItem(it)
            }
            add(menu, "最近连接（每次用量）", sub: sub)
        }

        let days = store.dailyRows(days: 14)
        if days.contains(where: { !$0.perSSID.isEmpty }) {
            let sub = NSMenu()
            for row in days where !row.perSSID.isEmpty {
                let dsub = NSMenu()
                for p in row.perSSID {
                    let it = NSMenuItem(title: "\(p.ssid)：\(fmtBytes(p.bytes))", action: nil, keyEquivalent: "")
                    it.isEnabled = false
                    dsub.addItem(it)
                }
                let ditem = NSMenuItem(title: "\(dayFmt.string(from: row.day)) \(weekday(row.day)) · \(fmtBytes(row.total))", action: nil, keyEquivalent: "")
                ditem.submenu = dsub
                sub.addItem(ditem)
            }
            add(menu, "每日统计（最近 14 天）", sub: sub)
        }

        let totals = store.ssidTotals()
        if !totals.isEmpty {
            let sub = NSMenu()
            for t in totals.prefix(15) {
                let tsub = NSMenu()
                let all = NSMenuItem(title: "合计：\(fmtBytes(t.bytes))", action: nil, keyEquivalent: "")
                all.isEnabled = false
                tsub.addItem(all)
                for row in store.dailyRows(days: 14).reversed() {
                    if let b = row.perSSID.first(where: { $0.ssid == t.ssid })?.bytes {
                        let it = NSMenuItem(title: "\(dayFmt.string(from: row.day))：\(fmtBytes(b))", action: nil, keyEquivalent: "")
                        it.isEnabled = false
                        tsub.addItem(it)
                    }
                }
                let item = NSMenuItem(title: "\(t.ssid)", action: nil, keyEquivalent: "")
                item.submenu = tsub
                sub.addItem(item)
            }
            add(menu, "按网络统计", sub: sub)
        }

        menu.addItem(.separator())
        add(menu, "打开数据目录", action: #selector(openDataDir))
        let launch = add(menu, "开机自启", action: #selector(toggleLogin))
        launch.state = isLoginItem() ? .on : .off
        add(menu, "清空统计数据…", action: #selector(resetData))
        menu.addItem(.separator())
        add(menu, "退出 WiFiMeter", action: #selector(NSApplication.terminate(_:)), key: "q")
    }

    // MARK: 动作

    @objc func requestLocation() {
        NSApp.activate(ignoringOtherApps: true)
        monitor.requestLocationAuth()
    }

    @objc func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openDataDir() { NSWorkspace.shared.open(store.dir) }

    private func isLoginItem() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch { NSSound.beep() }
        }
    }

    @objc func resetData() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "清空全部统计数据？"
        a.informativeText = "将删除 \(store.dir.path) 下的所有记录，无法恢复。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn {
            store.resetAll()
            monitor.poll()
            updateTitle()
        }
    }
}

// MARK: - 命令行模式（无界面）

func printStats() {
    let store = Store()
    print("== 今日各网络 ==")
    let today = store.dailyRows(days: 1).first
    if let t = today, !t.perSSID.isEmpty {
        let cur = store.open?.session.ssid
        for p in t.perSSID { print("  \(p.ssid == cur ? "● " : "")\(p.ssid)\t\(fmtBytes(p.bytes))") }
        print("  合计\t\(fmtBytes(t.total))")
    } else {
        print("  （暂无数据）")
    }
    print("\n== 最近 7 天 ==")
    for r in store.dailyRows(days: 7) {
        if !r.perSSID.isEmpty { print("  \(dayFmt.string(from: r.day)) \(weekday(r.day))\t\(fmtBytes(r.total))") }
    }
    print("\n== 各网络累计 ==")
    let totals = store.ssidTotals()
    if totals.isEmpty { print("  （暂无数据）") }
    for t in totals { print("  \(t.ssid)\t\(fmtBytes(t.bytes))") }
    print("\n== 最近 10 次连接 ==")
    let recent = store.recentSessions(10)
    if recent.isEmpty { print("  （暂无数据）") }
    for s in recent {
        let e = s.end ?? Date()
        print("  \(fullFmt.string(from: s.start)) – \(hmFmt.string(from: e))  \(s.ssid)  \(fmtBytes(s.bytes))  时长\(fmtDuration(e.timeIntervalSince(s.start)))\(s.open ? "（进行中）" : "")")
    }
    print("\n数据目录：\(store.dir.path)")
}

let args = CommandLine.arguments
if args.contains("--version") {
    print("WiFiMeter 1.0")
    exit(0)
}
if args.contains("--probe") {
    let store = Store()
    let m = Monitor(store: store)
    let w = m.primaryWiFi()
    print("wifi: \(String(describing: w))")
    if let w = w { print("counters: \(String(describing: m.rawCounters(w.iface)))") }
    print("locationAuthorized: \(m.locationAuthorized)")
    print("openState: \(String(describing: store.open))")
    exit(0)
}
if args.contains("--stats") {
    printStats()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
