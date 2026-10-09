import Foundation

// Pure models and connection planning: no AppKit, no I/O. Exercised by `HomeLab selftest`.

let freerdpPath = "/opt/homebrew/bin/sdl-freerdp"

enum Target: String, CaseIterable, Identifiable, Codable {
    case session
    case login
    var id: String { rawValue }
    var title: String { self == .session ? "Sessão atual" : "Login remoto" }
}

/// One RDP door of an environment, with the certificate it must present.
struct Endpoint: Equatable {
    var host: String
    var port: Int
    var fingerprint: String
    var windowTitle: String
    var keychainService: String
    var keychainAccount: String
    var keychainLabel: String
}

/// A machine the app can monitor and connect to.
struct HostEnvironment: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Name or address the RDP client dials (tailnet name when there is one).
    var rdpHost: String
    /// `ssh` destinations tried in order: aliases from ~/.ssh/config or user@host.
    var sshTargets: [String]
    var sessionPort: Int
    var sessionFingerprint: String
    var loginPort: Int?
    var loginFingerprint: String?
    var smbURL: String?
    var lanHost: String?
    var tailscaleName: String?

    /// The first environment keeps this id: its Keychain items were created by the helper that came
    /// before this app, under service names that do not carry an environment id.
    static let legacyID = "default"
    /// Stands in while no environment is configured; it reaches nothing.
    static let placeholder = HostEnvironment(id: "", name: "Home Lab", rdpHost: "", sshTargets: [],
                                             sessionPort: 3390, sessionFingerprint: "")

    var targets: [Target] { loginPort != nil && loginFingerprint != nil ? [.session, .login] : [.session] }

    func endpoint(_ target: Target) -> Endpoint? {
        let port: Int, fingerprint: String
        switch target {
        case .session: (port, fingerprint) = (sessionPort, sessionFingerprint)
        case .login:
            guard let p = loginPort, let f = loginFingerprint else { return nil }
            (port, fingerprint) = (p, f)
        }
        let legacy = id == HostEnvironment.legacyID
        return Endpoint(
            host: rdpHost, port: port, fingerprint: fingerprint,
            windowTitle: "\(name) — \(target.title.lowercased())",
            keychainService: legacy ? "com.codex.homelab-rdp.v1.\(port)" : "com.codex.homelab-rdp.v2.\(id).\(target.rawValue)",
            keychainAccount: legacy ? "endpoint-\(port)" : "rdp",
            keychainLabel: legacy ? (target == .session ? "Home Lab — sessão atual3390" : "Home Lab — login remoto3389")
                                  : "\(name) — RDP \(target.title.lowercased())")
    }

    var linuxPasswordService: String { "com.codex.homelab-host.v1." + id }
}

/// Accepts what a person pastes: `AA:BB:…`, upper case, spaces. Returns 64 lowercase hex digits or nil.
func normalizeFingerprint(_ text: String) -> String? {
    let hex = text.lowercased().filter { $0.isHexDigit }
    let separatorsOnly = text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == " " }
    return hex.count == 64 && separatorsOnly ? hex : nil
}

/// `user@host`, a bare host, or an alias from ~/.ssh/config. Rejects anything ssh could read as an option.
func validSSHTarget(_ text: String) -> Bool {
    guard !text.isEmpty, text.count < 256, !text.hasPrefix("-") else { return false }
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@:[]")
    return text.allSatisfy { allowed.contains($0) } && text.filter { $0 == "@" }.count <= 1
}

/// Environment ids go into Keychain service names and file names.
func slug(_ name: String, taken: Set<String>) -> String {
    let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    var base = String(folded.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
    base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if base.isEmpty { base = "ambiente" }
    var candidate = base, n = 2
    while taken.contains(candidate) || candidate == HostEnvironment.legacyID {
        candidate = "\(base)-\(n)"
        n += 1
    }
    return candidate
}

/// How the current session is shown. Maps to GNOME's `screen-share-mode`.
enum ScreenMode: String, CaseIterable, Identifiable {
    case virtual   // extend: host creates a virtual monitor sized by the client; works headless
    case mirror    // mirror-primary: needs a physical monitor on the host
    var id: String { rawValue }
    var gsettingsValue: String { self == .virtual ? "extend" : "mirror-primary" }
}

struct PixelSize: Equatable, Hashable {
    var width: Int
    var height: Int
    var text: String { "\(width)x\(height)" }

    init(_ width: Int, _ height: Int) { self.width = width; self.height = height }

    /// Parses "1920x1080". Rejects anything a virtual monitor could not sensibly use.
    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              (640...7680).contains(w), (480...4320).contains(h) else { return nil }
        self.init(w, h)
    }

    /// Virtual monitors want even dimensions.
    var even: PixelSize { PixelSize(width - width % 2, height - height % 2) }

    /// Largest size with this aspect ratio that fits inside `box`, never upscaled.
    func fitted(in box: PixelSize) -> PixelSize {
        let scale = min(1.0, min(Double(box.width) / Double(width), Double(box.height) / Double(height)))
        let w = min(box.width, Int((Double(width) * scale).rounded()))
        let h = min(box.height, Int((Double(height) * scale).rounded()))
        return PixelSize(w, h).even
    }
}

enum SizeChoice: Equatable, Hashable {
    case fit            // window filling the usable area of the chosen Mac display
    case fullscreen
    case fixed(PixelSize)

    var storage: String {
        switch self {
        case .fit: return "fit"
        case .fullscreen: return "full"
        case .fixed(let s): return s.text
        }
    }

    init(storage: String) {
        switch storage {
        case "full": self = .fullscreen
        case "fit": self = .fit
        default: self = PixelSize(storage).map(SizeChoice.fixed) ?? .fit
        }
    }
}

/// A Mac display in FreeRDP/SDL coordinates (origin top-left of the main display).
struct LocalDisplay: Equatable, Hashable, Identifiable {
    var id: Int             // SDL monitor id, as printed by `sdl-freerdp /list:monitor`
    var name: String
    var originX: Int
    var originY: Int
    var size: PixelSize
    /// Area left for a window after the menu bar, Dock and title bar.
    var usableOriginX: Int
    var usableOriginY: Int
    var usable: PixelSize
}

struct ConnectPlan {
    var endpoint: Endpoint
    var target: Target
    var mode: ScreenMode
    var size: SizeChoice
    /// Mac displays to open on. More than one means one virtual screen per display, fullscreen.
    var displays: [LocalDisplay]
    /// Current resolution of the host's primary physical monitor, when it has one.
    var hostMonitor: PixelSize?
    var clipboard: Bool
}

enum PlanError: Error, Equatable {
    case mirrorNeedsHostMonitor
    case noLocalDisplay
}

func freerdpArguments(_ plan: ConnectPlan) throws -> [String] {
    var args = ["/v:" + plan.endpoint.host + ":" + String(plan.endpoint.port),
                "/sec:nla", "/cert:deny,fingerprint:sha256:" + plan.endpoint.fingerprint,
                "/from-stdin", "+force-console-callbacks",
                "+gfx", "+disp",
                "/t:" + plan.endpoint.windowTitle, "/log-level:OFF",
                plan.clipboard ? "+clipboard" : "-clipboard", "-grab-keyboard", "-grab-mouse"]
    guard let display = plan.displays.first else { throw PlanError.noLocalDisplay }

    func centered(_ window: PixelSize) -> String {
        let x = display.usableOriginX + max(0, (display.usable.width - window.width) / 2)
        let y = display.usableOriginY + max(0, (display.usable.height - window.height) / 2)
        return "/window-position:\(x)x\(y)"
    }

    // The remote login always gets its own virtual screen; only the current session can mirror.
    if plan.target == .session && plan.mode == .mirror {
        guard let host = plan.hostMonitor else { throw PlanError.mirrorNeedsHostMonitor }
        // The host keeps its own resolution; the picture is scaled into the local window.
        // FreeRDP treats smart-sizing and dynamic-resolution as mutually exclusive.
        if plan.size == .fullscreen {
            args += ["/size:" + host.text, "+f", "/monitors:\(display.id)", "/smart-sizing"]
        } else {
            let window = host.fitted(in: display.usable)
            args += ["/size:" + window.text, "/smart-sizing", centered(window)]
        }
        return args
    }

    if plan.displays.count > 1 {
        // The host creates one virtual monitor per Mac display, laid out like the Mac's.
        args += ["/multimon", "/monitors:" + plan.displays.map { String($0.id) }.joined(separator: ","),
                 "+f", "+dynamic-resolution"]
        return args
    }
    switch plan.size {
    case .fullscreen:
        args += ["/size:" + display.size.even.text, "+f", "/monitors:\(display.id)"]
    case .fit:
        args += ["/size:" + display.usable.even.text, centered(display.usable.even)]
    case .fixed(let requested):
        args += ["/size:" + requested.even.text, centered(requested.even)]
    }
    // Resizing the local window resizes the virtual monitor on the host.
    args.append("+dynamic-resolution")
    return args
}

/// Parses `sdl-freerdp /list:monitor` lines such as `     * [1] [LC34G55T] 3440x1440	+0+0`.
func parseMonitorList(_ text: String) -> [(id: Int, name: String, size: PixelSize, x: Int, y: Int)] {
    let pattern = #"\[(\d+)\]\s+\[(.*?)\]\s+(\d+)x(\d+)\s+([+-]\d+)([+-]\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    var result: [(id: Int, name: String, size: PixelSize, x: Int, y: Int)] = []
    for line in text.split(separator: "\n") {
        let s = String(line)
        guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
        func group(_ i: Int) -> String { String(s[Range(m.range(at: i), in: s)!]) }
        guard let id = Int(group(1)), let w = Int(group(3)), let h = Int(group(4)),
              let x = Int(group(5)), let y = Int(group(6)) else { continue }
        result.append((id, group(2), PixelSize(w, h), x, y))
    }
    return result
}

/// The host script travels over ssh's stdin with its parameters on the first line,
/// so secrets never reach argv, the environment or a file on either machine.
func hostScriptInput(script: String, parameters: [String: Any]) -> Data {
    let json = (try? JSONSerialization.data(withJSONObject: parameters)) ?? Data("{}".utf8)
    return Data(("HOMELAB_PARAMS = \"" + json.base64EncodedString() + "\"\n" + script).utf8)
}

// MARK: - Host status

struct HostMonitor: Codable, Equatable {
    var connector: String
    var name: String
    var width: Int
    var height: Int
    var virtual: Bool
    var primary: Bool
    var size: PixelSize { PixelSize(width, height) }
}

struct GPUInfo: Codable, Equatable {
    var name: String
    var util: Double
    var memUsedMB: Double
    var memTotalMB: Double
    var temp: Double?
    var power: Double?
    var fan: Double?
}

struct DiskInfo: Codable, Equatable, Identifiable {
    var mount: String
    var totalGB: Double
    var usedGB: Double
    var id: String { mount }
    var percent: Double { totalGB > 0 ? usedGB / totalGB * 100 : 0 }
}

/// The disk to show: the chosen mount if the host still has it, otherwise root, otherwise the first.
func pickDisk(_ disks: [DiskInfo], mount: String) -> DiskInfo? {
    disks.first { $0.mount == mount } ?? disks.first { $0.mount == "/" } ?? disks.first
}

func nextDisk(_ disks: [DiskInfo], after mount: String?, step: Int = 1) -> DiskInfo? {
    guard !disks.isEmpty else { return nil }
    let current = disks.firstIndex { $0.mount == mount } ?? 0
    return disks[((current + step) % disks.count + disks.count) % disks.count]
}

struct ServiceInfo: Codable, Equatable, Identifiable {
    var name: String
    var active: String
    var sub: String
    var id: String { name }
}

struct TopProcess: Codable, Equatable, Identifiable {
    var pid: Int
    var name: String
    var cpu: Double
    var memMB: Double
    var id: Int { pid }
}

struct KeyringInfo: Codable, Equatable, Identifiable {
    var path: String
    var label: String
    var locked: Bool
    var items: Int
    var id: String { path }
}

/// Everything here is optional: a host missing a tool just shows less.
struct HostMetrics: Codable, Equatable {
    var osName: String?
    var kernel: String?
    var cpuModel: String?
    var cpuCores: Int?
    var cpuPercent: Double?
    var cpuTemp: Double?
    var loads: [Double]?
    var memTotalMB: Double?
    var memUsedMB: Double?
    var swapTotalMB: Double?
    var swapUsedMB: Double?
    var disks: [DiskInfo]?
    var gpu: GPUInfo?
    var rxKbps: Double?
    var txKbps: Double?
    var lanIP: String?
    var tailscaleIP: String?
    var services: [ServiceInfo]?
    var failedSystem: Int?
    var failedUser: Int?
    var containers: Int?
    var top: [TopProcess]?
}

struct HostStatus: Codable, Equatable {
    var hostname: String
    var uptimeSeconds: Int
    var load: String
    var remoteDesktopActive: Bool
    var shareMode: String
    var monitors: [HostMonitor]
    var physicalConnected: [String]
    var rdpClients: Int
    var locked: Bool?
    /// RDP ports the host is listening on, so the app need not knock on them itself.
    var listening: [Int]?
    var metrics: HostMetrics?
    var keyrings: [KeyringInfo]?
    /// Admin dialogs are pre-approved for this user (polkit rule installed).
    var polkitOpen: Bool?
    var sudoNeedsPassword: Bool?
    var user: String?
    var home: String?
    var packageInstalled: Bool?

    var physicalMonitors: [HostMonitor] { monitors.filter { !$0.virtual } }
    /// What `mirror-primary` would show.
    var mirrorSource: HostMonitor? { physicalMonitors.first { $0.primary } ?? physicalMonitors.first }
    var lockedKeyrings: [KeyringInfo] { (keyrings ?? []).filter(\.locked) }
}

// MARK: - Files

struct FileEntry: Codable, Equatable {
    var name: String
    var dir: Bool
    var link: Bool
    var size: Int
    var mtime: Int
}

struct FileListing: Codable, Equatable {
    var path: String
    var parent: String
    var entries: [FileEntry]
    var truncated: Bool
    var error: String?
}

struct FileRow: Identifiable, Equatable {
    var path: String
    var entry: FileEntry
    var depth: Int
    var id: String { path }
}

func joinPath(_ folder: String, _ name: String) -> String { folder.hasSuffix("/") ? folder + name : folder + "/" + name }

/// Flattens the folders the user opened into the rows the tree shows, depth first.
func fileRows(root: String, listings: [String: FileListing], expanded: Set<String>) -> [FileRow] {
    var rows: [FileRow] = []
    func walk(_ folder: String, _ depth: Int) {
        guard depth < 24, let listing = listings[folder] else { return }
        for entry in listing.entries {
            let path = joinPath(folder, entry.name)
            rows.append(FileRow(path: path, entry: entry, depth: depth))
            if entry.dir && expanded.contains(path) { walk(path, depth + 1) }
        }
    }
    walk(root, 0)
    return rows
}

func formatBytes(_ bytes: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(max(0, bytes)), unit = 0
    while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
    return unit == 0 ? "\(Int(value)) B" : String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
}

// MARK: - Host actions

struct KeyringUnlock: Codable, Equatable {
    struct Result: Codable, Equatable {
        var label: String
        var ok: Bool
    }
    var ok: Bool
    var results: [Result]
}

struct SudoResult: Codable, Equatable {
    var ok: Bool
    /// False when sudo wanted a password and the one given (if any) was refused.
    var auth: Bool
    var code: Int?
    var output: String?
    var polkitOpen: Bool?
}

struct AdminAction: Identifiable, Equatable {
    var id: String
    var title: String
    var argv: [String]
    var env: [String: String] = [:]
    var timeout: Int = 120
    /// Asks before running: the host goes away or the change is slow to undo.
    var confirm: String?

    static let presets: [AdminAction] = [
        AdminAction(id: "grd", title: "Reiniciar o serviço de login remoto (3389)",
                    argv: ["systemctl", "restart", "gnome-remote-desktop.service"]),
        AdminAction(id: "reset-failed", title: "Limpar unidades com falha do systemd",
                    argv: ["systemctl", "reset-failed"]),
        AdminAction(id: "apt-update", title: "Atualizar lista de pacotes", argv: ["apt-get", "update"], timeout: 300),
        AdminAction(id: "apt-upgrade", title: "Instalar atualizações de pacotes", argv: ["apt-get", "-y", "upgrade"],
                    env: ["DEBIAN_FRONTEND": "noninteractive"], timeout: 900,
                    confirm: "Instalar todas as atualizações pendentes? Pode levar vários minutos e reiniciar serviços."),
        AdminAction(id: "reboot", title: "Reiniciar o host", argv: ["systemctl", "reboot"],
                    confirm: "Reiniciar o host agora? Sessões e trabalhos em andamento serão interrompidos."),
        AdminAction(id: "poweroff", title: "Desligar o host", argv: ["systemctl", "poweroff"],
                    confirm: "Desligar o host agora? Ele só volta se alguém ligar fisicamente."),
    ]
}

// MARK: - Services, containers, processes

struct UnitInfo: Codable, Equatable, Identifiable {
    var scope: String          // "user" or "system"
    var name: String
    var description: String
    var active: String
    var sub: String
    var enabled: String
    var custom: Bool
    var result: String?
    var restarts: Int?
    var activeSeconds: Int?
    var memoryMB: Double?
    var pid: Int?
    var timer: String?
    var timerActive: Bool?
    var nextRun: String?
    /// Path of the unit file on the host, when it has one.
    var file: String?
    var id: String { scope + ":" + name }
    var shortName: String { name.hasSuffix(".service") ? String(name.dropLast(8)) : name }
    var isRunning: Bool { active == "active" || active == "activating" }
    /// `enable`/`disable` only make sense for units with an install section.
    var canToggleBoot: Bool { enabled == "enabled" || enabled == "disabled" }
}

enum UnitFilter: String, CaseIterable, Identifiable {
    case mine, user, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mine: return "Meus"
        case .user: return "Usuário"
        case .system: return "Sistema"
        }
    }
}

/// Health of a unit in one word, for the dot and the label next to it.
enum Tone { case good, bad, busy, idle }

func unitTone(_ unit: UnitInfo) -> Tone {
    switch unit.active {
    case "active": return .good
    case "failed": return .bad
    case "activating", "deactivating", "reloading": return .busy
    default: return .idle
    }
}

func unitStateText(_ unit: UnitInfo) -> String {
    switch unit.active {
    case "active": return unit.sub == "exited" ? "concluído" : "em execução"
    case "failed": return "falhou"
    case "activating": return "iniciando"
    case "deactivating": return "parando"
    default: return unit.timer != nil ? (unit.timerActive == true ? "aguardando o timer" : "timer parado") : "parado"
    }
}

func filterUnits(_ units: [UnitInfo], filter: UnitFilter, search: String) -> [UnitInfo] {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    return units.filter { unit in
        switch filter {
        case .mine: guard unit.scope == "user" && unit.custom else { return false }
        case .user: guard unit.scope == "user" else { return false }
        case .system: guard unit.scope == "system" else { return false }
        }
        return needle.isEmpty || unit.name.lowercased().contains(needle) || unit.description.lowercased().contains(needle)
    }
}

/// Unit names go to systemctl on the host; the host checks them again.
func validUnitName(_ name: String) -> Bool {
    guard name.hasSuffix(".service") || name.hasSuffix(".timer"), name.count < 200, !name.hasPrefix("-") else { return false }
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@_.:-")
    return name.allSatisfy { allowed.contains($0) }
}

struct ContainerInfo: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var ports: String
    var project: String
    var isRunning: Bool { state == "running" || state == "restarting" || state == "paused" }
}

func containerTone(_ container: ContainerInfo) -> Tone {
    switch container.state {
    case "running": return .good
    case "restarting", "paused", "created": return .busy
    case "dead": return .bad
    default: return container.status.contains("Exited (0)") || !container.status.contains("Exited") ? .idle : .bad
    }
}

func filterContainers(_ containers: [ContainerInfo], search: String) -> [ContainerInfo] {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return containers }
    return containers.filter { ($0.name + " " + $0.image + " " + $0.project).lowercased().contains(needle) }
}

struct ProcessRow: Codable, Equatable, Identifiable {
    var pid: Int
    var name: String
    var cpu: Double
    var memMB: Double
    var seconds: Int
    var user: String
    var own: Bool
    var command: String
    var id: Int { pid }
}

struct UnitList: Codable { var units: [UnitInfo] }
struct ContainerList: Codable {
    var available: Bool
    var containers: [ContainerInfo]
    var error: String?
}
struct ProcessList: Codable {
    var processes: [ProcessRow]
    var cores: Int?
}
struct ActionResult: Codable, Equatable {
    var ok: Bool
    var auth: Bool
    var output: String?
    /// Login and tunnel commands answer with an address to open.
    var url: String?
}
struct LogResult: Codable, Equatable {
    var ok: Bool
    var text: String
    var cpu: String?
    var memory: String?
}

func formatMemory(_ megabytes: Double) -> String {
    megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : String(format: "%.0f MB", megabytes)
}

// MARK: - Docker details

struct EnvVar: Codable, Equatable, Identifiable {
    var key: String
    var value: String
    var id: String { key }
}

struct ContainerDetail: Codable, Equatable {
    var ok: Bool
    var error: String?
    var image: String?
    var created: String?
    var command: String?
    var restart: String?
    var health: String?
    var env: [EnvVar]?
    var mounts: [String]?
    var networks: [String]?
    var ports: [String]?
    var project: String?
    var composeFiles: [String]?
    var workingDir: String?
}

struct ImageInfo: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var size: String
    var created: String
    var inUse: Bool
}

struct ImageList: Codable {
    var available: Bool
    var images: [ImageInfo]
}

struct FileContent: Codable, Equatable {
    var ok: Bool
    var auth: Bool?
    var path: String
    var content: String?
    var writable: Bool?
    var backup: Bool?
    var error: String?
}

// MARK: - Ports, Tailscale, Cloudflare

struct PortInfo: Codable, Equatable, Identifiable {
    var proto: String
    var port: Int
    /// "public" (every interface), "tailnet" (only the Tailscale address) or "local" (loopback only).
    var exposure: String
    var addresses: [String]
    var process: String
    var pid: Int
    var unit: String
    var container: String
    var ufwAllowed: Bool?
    var id: String { "\(proto)-\(port)-\(exposure)" }
    /// Who answers on this port, most specific name first.
    var owner: String {
        if !container.isEmpty { return container }
        if !unit.isEmpty { return unit.hasSuffix(".service") ? String(unit.dropLast(8)) : unit }
        return process.isEmpty ? "desconhecido" : process
    }
}

struct FirewallInfo: Codable, Equatable {
    var state: String
    var allowed: [Int]
    var rules: [String]
}

struct PortList: Codable {
    var ports: [PortInfo]
    var firewall: FirewallInfo
}

enum PortScope: String, CaseIterable, Identifiable {
    case all, lan, tailnet, local
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Todas"
        case .lan: return "Rede"
        case .tailnet: return "Tailnet"
        case .local: return "Só local"
        }
    }
}

func filterPorts(_ ports: [PortInfo], scope: PortScope, search: String, udp: Bool) -> [PortInfo] {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    return ports.filter { port in
        guard udp || port.proto == "tcp" else { return false }
        switch scope {
        case .all: break
        case .lan: guard port.exposure == "public" else { return false }
        case .tailnet: guard port.exposure == "tailnet" else { return false }
        case .local: guard port.exposure == "local" else { return false }
        }
        return needle.isEmpty || String(port.port).contains(needle)
            || (port.owner + " " + port.process + " " + port.unit).lowercased().contains(needle)
    }
}

func exposureTitle(_ exposure: String) -> String {
    ["public": "rede", "tailnet": "tailnet", "local": "só local"][exposure] ?? exposure
}

/// Where a browser on this Mac reaches a host port. Loopback-only ports need an SSH tunnel first:
/// pass the local end of that tunnel, or get nil.
func portURL(_ port: PortInfo, environment: HostEnvironment, tunnelPort: Int?) -> URL? {
    guard port.proto == "tcp" else { return nil }
    let scheme = [443, 8443, 9443].contains(port.port) ? "https" : "http"
    switch port.exposure {
    case "local": return tunnelPort.flatMap { URL(string: "\(scheme)://localhost:\($0)") }
    case "tailnet": return URL(string: "\(scheme)://\(environment.rdpHost):\(port.port)")
    default: return URL(string: "\(scheme)://\(environment.lanHost ?? environment.rdpHost):\(port.port)")
    }
}

struct ServeEntry: Codable, Equatable, Identifiable {
    var port: Int
    var path: String
    var funnel: Bool
    var target: String
    var url: String
    var id: String { "\(port)\(path)" }
}

struct TailscalePeer: Codable, Equatable, Identifiable {
    var name: String
    var ip: String
    var os: String
    var online: Bool
    var id: String { name + ip }
}

struct TailscaleInfo: Codable, Equatable {
    var installed: Bool
    var version: String?
    var state: String?
    var name: String?
    var ips: [String]?
    var tailnet: String?
    var health: [String]?
    var authURL: String?
    var serve: [ServeEntry]
    var peers: [TailscalePeer]
    var running: Bool { state == "Running" }
}

struct CloudflareTunnel: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var created: String
    var connections: Int
}

struct QuickTunnel: Codable, Equatable, Identifiable {
    var port: Int
    var url: String
    var id: Int { port }
}

struct CloudflareInfo: Codable, Equatable {
    var installed: Bool
    var version: String?
    var service: String?
    var serviceInstalled: Bool?
    var loggedIn: Bool?
    var config: String?
    var tunnels: [CloudflareTunnel]
    var quick: [QuickTunnel]
    var error: String?
}

/// Tailscale Funnel only publishes on these ports.
let funnelPorts = [443, 8443, 10000]

/// A local target for `tailscale serve`: a bare port or an http(s) URL on loopback.
func validServeTarget(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if let port = Int(trimmed) { return (1...65535).contains(port) }
    guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
          let host = url.host, ["127.0.0.1", "localhost"].contains(host) else { return false }
    return url.port.map { (1...65535).contains($0) } ?? true
}

func validHostname(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2, text.count <= 253, (parts.last?.count ?? 0) >= 2 else { return false }
    return parts.allSatisfy { part in
        !part.isEmpty && part.count <= 63 && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

// MARK: - Updates

/// Releases are published here by the repository's GitHub Actions workflow.
let updateRepository = "BarretoDiego/homelab-controller"

struct ReleaseAsset: Codable, Equatable {
    var name: String
    var browser_download_url: String
    /// "sha256:<hex>", filled in by GitHub for uploaded assets.
    var digest: String?
    var size: Int?
}

struct ReleaseInfo: Codable, Equatable {
    var tag_name: String
    var name: String?
    var body: String?
    var html_url: String?
    var draft: Bool?
    var prerelease: Bool?
    var assets: [ReleaseAsset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    /// The zipped app the updater installs; the DMG is for people.
    var appArchive: ReleaseAsset? { assets.first { $0.name.hasSuffix(".app.zip") } }
}

/// "v5.10.2" → [5, 10, 2]. Anything after the numbers (-beta, +build) is ignored.
func versionNumbers(_ text: String) -> [Int] {
    let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
    let core = trimmed.prefix { $0.isNumber || $0 == "." }
    return core.split(separator: ".").compactMap { Int($0) }
}

func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = versionNumbers(candidate), b = versionNumbers(current)
    guard !a.isEmpty else { return false }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

/// The release to offer, if it is a finished one, newer than what is running, and carries the app.
func updateOffer(_ release: ReleaseInfo?, running: String) -> ReleaseInfo? {
    guard let release, release.draft != true, release.prerelease != true, release.appArchive != nil,
          isNewer(release.version, than: running) else { return nil }
    return release
}

// MARK: - System controls

/// Slow-changing facts the overview shows next to its quick actions.
struct SystemInfo: Codable, Equatable {
    var rebootRequired: Bool
    var updates: Int?
    var securityUpdates: Int?
    var powerProfile: String?
    var powerProfiles: [String]?
    var cacheMB: Double?
    var failedUser: Int?
    var failedSystem: Int?
    var sessions: Int?

    var failedUnits: Int { (failedUser ?? 0) + (failedSystem ?? 0) }
    var updatesText: String {
        guard let updates else { return "desconhecido" }
        if updates == 0 { return "em dia" }
        let security = securityUpdates ?? 0
        return "\(updates) pendente\(updates == 1 ? "" : "s")" + (security > 0 ? " · \(security) de segurança" : "")
    }
}

func powerProfileTitle(_ profile: String) -> String {
    ["performance": "Desempenho", "balanced": "Equilibrado", "power-saver": "Economia"][profile] ?? profile
}

// MARK: - Setup

struct RDPStatus: Codable, Equatable {
    var enabled: Bool
    var port: Int?
    var fingerprint: String?
    var hasCredentials: Bool?
}

struct DetectInfo: Codable, Equatable {
    var user: String
    var hostname: String
    var home: String?
    var osName: String?
    var desktop: String?
    var graphicalSession: Bool?
    var hasGrd: Bool?
    var hasOpenssl: Bool?
    var hasApt: Bool?
    var hasGi: Bool?
    var lanIP: String?
    var tailscaleIP: String?
    var tailscaleName: String?
    var sudoNeedsPassword: Bool?
    var packageInstalled: Bool?
    var rdp: RDPStatus?
    var loginRdp: RDPStatus?
    var smbShares: [String]?

    /// What still blocks desktop sharing, in the order the wizard fixes it.
    var missing: [String] {
        var list: [String] = []
        if desktop?.isEmpty != false { list.append("GNOME não encontrado: o compartilhamento usa o GNOME Remote Desktop") }
        if hasGrd != true { list.append("pacote gnome-remote-desktop") }
        if hasOpenssl != true { list.append("openssl") }
        if hasGi != true { list.append("python3-gi") }
        return list
    }
    var supported: Bool { desktop?.isEmpty == false }
    var needsPackages: Bool { hasGrd != true || hasOpenssl != true || hasGi != true }
    var needsSetup: Bool { rdp?.enabled != true || rdp?.fingerprint == nil || rdp?.hasCredentials != true }
}

struct SetupResult: Codable, Equatable {
    struct Step: Codable, Equatable, Identifiable {
        var name: String
        var ok: Bool
        var detail: String
        var id: String { name }
    }
    var ok: Bool
    var steps: [Step]?
    var rdp: RDPStatus?
    var error: String?
}

/// Builds the environment the wizard saves from what the host reported.
func makeEnvironment(name: String, sshTarget: String, detect: DetectInfo, rdp: RDPStatus,
                     taken: Set<String>) -> HostEnvironment? {
    guard let fingerprint = rdp.fingerprint.flatMap(normalizeFingerprint), let port = rdp.port else { return nil }
    // Prefer the tailnet name: it works from anywhere. Otherwise whatever ssh reached.
    let sshHost = sshTarget.split(separator: "@").last.map(String.init) ?? sshTarget
    let rdpHost = detect.tailscaleName ?? detect.lanIP ?? sshHost
    let login = detect.loginRdp
    let share = detect.smbShares?.first
    return HostEnvironment(
        id: slug(name, taken: taken), name: name, rdpHost: rdpHost, sshTargets: [sshTarget],
        sessionPort: port, sessionFingerprint: fingerprint,
        loginPort: login?.fingerprint.flatMap(normalizeFingerprint) != nil ? login?.port : nil,
        loginFingerprint: login?.port != nil ? login?.fingerprint.flatMap(normalizeFingerprint) : nil,
        smbURL: share.flatMap { s in detect.lanIP.map { "smb://\($0)/\(s)" } },
        lanHost: detect.lanIP,
        tailscaleName: detect.tailscaleName?.split(separator: ".").first.map(String.init))
}

// MARK: - Formatting

struct TailscaleLink: Equatable {
    var direct: Bool
    var via: String
    var milliseconds: Int
}

/// Parses `tailscale ping` output, e.g. `pong from host (100.x) via 192.0.2.10:41641 in 2ms`.
func parseTailscalePing(_ text: String) -> TailscaleLink? {
    guard let regex = try? NSRegularExpression(pattern: #"via (\S+) in (\d+)\s*ms"#),
          let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let via = Range(m.range(at: 1), in: text), let ms = Range(m.range(at: 2), in: text),
          let value = Int(text[ms]) else { return nil }
    let path = String(text[via])
    return TailscaleLink(direct: !path.uppercased().hasPrefix("DERP"), via: path, milliseconds: value)
}

func formatRate(_ kbps: Double) -> String {
    if kbps >= 1024 { return String(format: "%.1f MB/s", kbps / 1024) }
    return String(format: "%.0f KB/s", max(0, kbps))
}

func formatGB(_ megabytes: Double) -> String { String(format: "%.1f", megabytes / 1024) }

func formatUptime(_ seconds: Int) -> String {
    let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)min" }
    return "\(minutes)min"
}
