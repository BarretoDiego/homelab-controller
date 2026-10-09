import AppKit
import Darwin
import Security
import ServiceManagement
import SwiftUI

// MARK: - Processes

struct RunResult {
    var status: Int32
    var output: String
    var ok: Bool { status == 0 }
}

func run(_ path: String, _ arguments: [String], stdin: Data? = nil, mergeStderr: Bool = false,
         environment: [String: String]? = nil, timeout: TimeInterval = 15) async -> RunResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let output = Pipe(), input = Pipe()
            process.standardOutput = output
            process.standardError = mergeStderr ? output : FileHandle.nullDevice
            if stdin == nil { process.standardInput = FileHandle.nullDevice } else { process.standardInput = input }
            do { try process.run() } catch {
                continuation.resume(returning: RunResult(status: -1, output: ""))
                return
            }
            if let stdin {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            continuation.resume(returning: RunResult(status: process.terminationStatus,
                                                     output: String(data: data, encoding: .utf8) ?? ""))
        }
    }
}

let tailscalePaths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                      "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                  "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/cm-homelab-%C", "-o", "ControlPersist=120"]

func ssh(_ target: String, _ command: String, stdin: Data? = nil, timeout: TimeInterval = 12) async -> RunResult {
    await run("/usr/bin/ssh", sshOptions + [target, command], stdin: stdin, timeout: timeout)
}

func portOpen(_ host: String, _ port: String) async -> Bool {
    await run("/usr/bin/nc", ["-z", "-G", "2", host, port], timeout: 4).ok
}

func runningClientPIDs() async -> [Int32] {
    let result = await run("/usr/bin/pgrep", ["-x", "sdl-freerdp"], timeout: 4)
    return result.output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
}

func tailscaleLink(_ name: String) async -> TailscaleLink? {
    guard let tool = tailscalePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let result = await run(tool, ["ping", "-c", "1", "--timeout", "2s", name], mergeStderr: true, timeout: 5)
    return parseTailscalePing(result.output)
}

// MARK: - Host script

enum HostScript {
    /// Shipped inside the app; the development snapshot build reads it from HOMELAB_HOST_SCRIPT.
    static let text: String = {
        let candidates = [Bundle.main.url(forResource: "homelab-host", withExtension: "py"),
                          ProcessInfo.processInfo.environment["HOMELAB_HOST_SCRIPT"].map { URL(fileURLWithPath: $0) }]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return ""
    }()
    static var package: URL? { Bundle.main.url(forResource: "homelab-host", withExtension: "deb") }
}

/// Runs one command of the host script on the first SSH target that answers.
func hostCall<T: Decodable>(_ targets: [String], _ command: String, _ parameters: [String: Any] = [:],
                            timeout: TimeInterval = 12, as type: T.Type = T.self) async -> (target: String, value: T)? {
    guard !HostScript.text.isEmpty else { return nil }
    let input = hostScriptInput(script: HostScript.text, parameters: parameters)
    for target in targets {
        let result = await ssh(target, "python3 - " + command, stdin: input, timeout: timeout)
        if let value = try? JSONDecoder().decode(T.self, from: Data(result.output.utf8)) { return (target, value) }
    }
    return nil
}

// MARK: - Keychain

struct Credential: Codable {
    var username: String
    var password: String
}

enum KeychainError: Error {
    case status(OSStatus)
    case invalidRecord
}

/// Generic-password items readable only by this app. The original environment reuses the items
/// the first helper created, so nothing has to be typed again.
enum CredentialStore {
    static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }

    static func read(service: String, account: String) throws -> Credential? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(Credential.self, from: data) else {
            throw KeychainError.invalidRecord
        }
        return credential
    }

    static func store(_ credential: Credential, service: String, account: String, label: String) throws {
        guard let path = Bundle.main.executablePath else { throw KeychainError.invalidRecord }
        var trusted: SecTrustedApplication?
        let trustStatus = path.withCString { SecTrustedApplicationCreateFromPath($0, &trusted) }
        guard trustStatus == errSecSuccess, let trusted else { throw KeychainError.status(trustStatus) }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(label as CFString, [trusted] as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else { throw KeychainError.status(accessStatus) }
        var q = query(service, account)
        q[kSecAttrLabel as String] = label
        q[kSecAttrAccess as String] = access
        q[kSecAttrSynchronizable as String] = false
        q[kSecValueData as String] = try JSONEncoder().encode(credential)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    static func read(_ endpoint: Endpoint) throws -> Credential? {
        try read(service: endpoint.keychainService, account: endpoint.keychainAccount)
    }

    static func store(_ credential: Credential, _ endpoint: Endpoint) throws {
        try store(credential, service: endpoint.keychainService, account: endpoint.keychainAccount, label: endpoint.keychainLabel)
    }

    static let linuxAccount = "linux-password"
}

// MARK: - Environments on disk

enum EnvironmentStore {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Home Lab RDP", isDirectory: true)
    }
    static var file: URL { folder.appendingPathComponent("environments.json") }

    static func load() -> [HostEnvironment] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([HostEnvironment].self, from: data) else {
            return []   // first run: the setup assistant adds the first one
        }
        return list
    }

    static func save(_ environments: [HostEnvironment]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(environments) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Local displays

@MainActor
func localDisplays(monitorList: String) -> [LocalDisplay] {
    let listed = parseMonitorList(monitorList)
    let screens = NSScreen.screens
    guard let main = screens.first else { return [] }
    let titleBar = 28
    return screens.enumerated().map { index, screen in
        // AppKit measures from the bottom-left of the main screen; FreeRDP from its top-left.
        let frame = screen.frame, visible = screen.visibleFrame
        let x = Int(frame.minX), y = Int(main.frame.maxY - frame.maxY)
        let id = listed.first { $0.x == x && $0.y == y }?.id ?? index + 1
        return LocalDisplay(id: id, name: screen.localizedName, originX: x, originY: y,
                            size: PixelSize(Int(frame.width), Int(frame.height)),
                            usableOriginX: Int(visible.minX),
                            usableOriginY: Int(main.frame.maxY - visible.maxY) + titleBar,
                            usable: PixelSize(Int(visible.width), Int(visible.height) - titleBar))
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    enum Phase: Equatable { case idle, preparing, connected }
    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }
    struct History {
        var cpu: [Double] = []
        var memory: [Double] = []
        var gpu: [Double] = []
        var download: [Double] = []
        mutating func push(_ metrics: HostMetrics) {
            func add(_ list: inout [Double], _ value: Double?) {
                guard let value else { return }
                list.append(value)
                if list.count > 40 { list.removeFirst(list.count - 40) }
            }
            add(&cpu, metrics.cpuPercent)
            if let used = metrics.memUsedMB, let total = metrics.memTotalMB, total > 0 { add(&memory, used / total * 100) }
            add(&gpu, metrics.gpu?.util)
            add(&download, metrics.rxKbps)
        }
    }
    /// The panel asks for a secret inline; `answer(nil, _)` means the user gave up.
    struct EditorRequest: Identifiable, Equatable {
        var path: String
        var title: String
        /// "user" or "system" reloads systemd after saving; nil for ordinary files.
        var reload: String?
        var id: String { path }
    }

    struct PasswordRequest: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var answer: (String?, Bool) -> Void
    }
    static let allDisplays = "*"
    /// One model for the menu bar panel, the main window and the app delegate.
    static let shared = Model()

    @Published var environments: [HostEnvironment]
    @Published var environmentID: String { didSet { defaults.set(environmentID, forKey: "environment") } }

    @Published var status: HostStatus?
    @Published var history = History()
    @Published var link: TailscaleLink?
    @Published var sshAlias: String?
    @Published var ports: [String: Bool] = [:]
    @Published var checkedOnce = false
    @Published var refreshing = false
    @Published var lastUpdate: Date?
    @Published var phase: Phase = .idle
    @Published var notice: Notice? {
        didSet {
            guard let notice else { return }
            NSLog("HomeLab: %@", notice.text)
            // Confirmations fade on their own; problems stay until something replaces them.
            guard !notice.isError else { return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if self?.notice == notice { self?.notice = nil }
            }
        }
    }
    @Published var displays: [LocalDisplay] = []
    @Published var otherClientPIDs: [Int32] = []
    @Published var credentialRequest: Target?
    @Published var passwordRequest: PasswordRequest?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published var system: SystemInfo?
    /// A file of the host open in the editor.
    @Published var editor: EditorRequest?
    /// SSH tunnels to loopback-only ports of the host: remote port → local port.
    @Published var tunnels: [Int: Int] = [:]
    private var tunnelProcesses: [Int: Process] = [:]

    // Host actions
    @Published var busyAction: String?
    @Published var actionOutput: String?

    // Files
    @Published var fileRoot = ""
    @Published var listings: [String: FileListing] = [:]
    @Published var expandedFolders: Set<String> = []
    @Published var loadingFolders: Set<String> = []
    @Published var showHidden = false { didSet { reloadFiles() } }

    @Published var target: Target { didSet { defaults.set(target.rawValue, forKey: "target") } }
    @Published var mode: ScreenMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var sizeTag: String { didSet { defaults.set(sizeTag, forKey: "size") } }
    @Published var customSize: String { didSet { defaults.set(customSize, forKey: "customSize") } }
    @Published var displayName: String { didSet { defaults.set(displayName, forKey: "display") } }
    @Published var clipboard: Bool { didSet { defaults.set(clipboard, forKey: "clipboard") } }
    /// Mount point of the disk the tiles show; empty means the root disk.
    @Published var diskMount: String { didSet { defaults.set(diskMount, forKey: "diskMount") } }

    /// The panel refreshes often while open and rarely while closed.
    var panelVisible = false { didSet { if panelVisible { wake = true } } }
    /// How many surfaces are showing live data: the menu bar panel, its pinned copy, the main window.
    var viewers = 0 { didSet { panelVisible = viewers > 0 } }
    /// The menu bar panel is detached and stays open.
    @Published var pinned = false
    private var wake = false
    private let defaults = UserDefaults.standard
    private var client: Process?
    private var monitorList = ""

    init() {
        environments = EnvironmentStore.load()
        environmentID = defaults.string(forKey: "environment") ?? HostEnvironment.legacyID
        target = Target(rawValue: defaults.string(forKey: "target") ?? "") ?? .session
        mode = ScreenMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .virtual
        sizeTag = defaults.string(forKey: "size") ?? "fit"
        customSize = defaults.string(forKey: "customSize") ?? ""
        displayName = defaults.string(forKey: "display") ?? ""
        clipboard = defaults.bool(forKey: "clipboard")
        diskMount = defaults.string(forKey: "diskMount") ?? ""
        Task { [weak self] in
            await self?.refresh()
            // `open -n "Home Lab.app" --args connect` connects straight away with the saved options.
            if CommandLine.arguments.dropFirst().first == "connect" { await self?.connect() }
            while let self {
                let seconds = self.panelVisible ? 10 : 60
                for _ in 0..<(seconds * 2) where !self.wake {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                self.wake = false
                await self.refresh()
            }
        }
    }

    // MARK: Environments

    var env: HostEnvironment { environments.first { $0.id == environmentID } ?? environments.first ?? .placeholder }
    var effectiveTarget: Target { env.targets.contains(target) ? target : .session }
    private var sshTargets: [String] {
        // The target that answered last goes first.
        sshAlias.map { alias in [alias] + env.sshTargets.filter { $0 != alias } } ?? env.sshTargets
    }

    func select(_ id: String) {
        guard id != environmentID, environments.contains(where: { $0.id == id }) else { return }
        environmentID = id
        resetHostState()
        wake = true
    }

    private func resetHostState() {
        status = nil; history = History(); link = nil; sshAlias = nil; ports = [:]; checkedOnce = false
        notice = nil; actionOutput = nil; fileRoot = ""; listings = [:]; expandedFolders = []; system = nil
        editor = nil; closeAllTunnels()
    }

    func add(_ environment: HostEnvironment) {
        environments.append(environment)
        EnvironmentStore.save(environments)
        select(environment.id)
    }

    /// Forgets the environment and its secrets. The first helper's Keychain items are left alone:
    /// the old Desktop shortcuts still use them.
    func removeCurrentEnvironment() {
        guard !environments.isEmpty else { return }
        let removed = env
        environments.removeAll { $0.id == removed.id }
        EnvironmentStore.save(environments)
        if removed.id != HostEnvironment.legacyID {
            for target in Target.allCases {
                if let endpoint = removed.endpoint(target) {
                    try? CredentialStore.delete(service: endpoint.keychainService, account: endpoint.keychainAccount)
                }
            }
        }
        try? CredentialStore.delete(service: removed.linuxPasswordService, account: CredentialStore.linuxAccount)
        environmentID = environments.first?.id ?? ""
        resetHostState()
        wake = true
    }

    // MARK: Status

    var online: Bool { ports["session"] == true || ports["login"] == true || sshAlias != nil }
    var mirrorSource: HostMonitor? { status?.mirrorSource }
    /// Mirroring needs a physical monitor on the host; without one the virtual screen is the only option.
    var effectiveMode: ScreenMode { effectiveTarget == .session && mode == .mirror && mirrorSource != nil ? .mirror : .virtual }
    var selectedDisplay: LocalDisplay? { displays.first { $0.name == displayName } ?? displays.first }
    /// One virtual screen per Mac display; mirroring a single host monitor has nothing to spread.
    var usesAllDisplays: Bool { displayName == Model.allDisplays && displays.count > 1 && effectiveMode == .virtual }
    var selectedDisplays: [LocalDisplay] { usesAllDisplays ? displays : selectedDisplay.map { [$0] } ?? [] }
    var clientRunning: Bool { phase == .connected || !otherClientPIDs.isEmpty }

    var sizeChoice: SizeChoice? {
        if sizeTag == "custom" { return PixelSize(customSize.trimmingCharacters(in: .whitespaces)).map(SizeChoice.fixed) }
        return SizeChoice(storage: sizeTag)
    }

    func refresh() async {
        guard !refreshing else { return }
        guard !environments.isEmpty else {
            checkedOnce = true
            return
        }
        refreshing = true
        let env = env
        defer { refreshing = false }
        let rdpPorts = [env.sessionPort] + (env.loginPort.map { [$0] } ?? [])
        async let files: Bool? = env.lanHost == nil ? nil : portOpen(env.lanHost!, "445")
        async let probe: (target: String, value: HostStatus)? =
            hostCall(sshTargets, "probe", ["sessionPort": env.sessionPort, "ports": rdpPorts])
        async let ping: TailscaleLink? = env.tailscaleName == nil ? nil : tailscaleLink(env.tailscaleName!)
        // Listing monitors runs sdl-freerdp itself, so it must finish before looking for open clients.
        monitorList = await run(freerdpPath, ["/list:monitor"], mergeStderr: true, timeout: 6).output
        let running = await runningClientPIDs()
        let probed = await probe, pinged = await ping, smb = await files
        var open: [String: Bool] = [:]
        if let smb { open["smb"] = smb }
        if let listening = probed?.value.listening {
            open["session"] = listening.contains(env.sessionPort)
            if let login = env.loginPort { open["login"] = listening.contains(login) }
        } else {
            // No SSH: fall back to knocking on the RDP ports (each knock shows up in the host's journal).
            open["session"] = await portOpen(env.rdpHost, String(env.sessionPort))
            if let login = env.loginPort { open["login"] = await portOpen(env.rdpHost, String(login)) }
        }
        // The user may have switched environment while this one was being read.
        guard env.id == environmentID else { return }
        displays = localDisplays(monitorList: monitorList)
        sshAlias = probed?.target
        status = probed?.value
        link = pinged
        if let metrics = status?.metrics { history.push(metrics) }
        ports = open
        otherClientPIDs = running.filter { $0 != client?.processIdentifier }
        checkedOnce = true
        lastUpdate = Date()
        if fileRoot.isEmpty, let home = status?.home { fileRoot = home }
    }

    // MARK: Disks

    var disks: [DiskInfo] { status?.metrics?.disks ?? [] }
    var selectedDisk: DiskInfo? { pickDisk(disks, mount: diskMount) }

    /// Steps through the host's disks, wrapping around.
    func cycleDisk(_ step: Int = 1) {
        guard let next = nextDisk(disks, after: selectedDisk?.mount, step: step) else { return }
        diskMount = next.mount
    }

    // MARK: Connect

    func connect() async {
        guard phase == .idle else { return }
        notice = nil
        guard let size = sizeChoice else {
            notice = Notice(text: "Resolução inválida. Use o formato 1920x1080.", isError: true)
            return
        }
        phase = .preparing
        await refresh()
        let target = effectiveTarget
        guard let endpoint = env.endpoint(target) else {
            phase = .idle
            notice = Notice(text: "Este ambiente não tem \(target.title.lowercased()) configurado.", isError: true)
            return
        }
        guard otherClientPIDs.isEmpty else {
            phase = .idle
            notice = Notice(text: "Já existe um cliente RDP aberto. Encerre-o antes de abrir outro.", isError: true)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: freerdpPath) else {
            phase = .idle
            notice = Notice(text: "FreeRDP não encontrado em \(freerdpPath). Instale com: brew install freerdp", isError: true)
            return
        }
        let wanted = effectiveMode, chosen = selectedDisplays
        let credential: Credential
        do {
            guard let stored = try await Task.detached(operation: { try CredentialStore.read(endpoint) }).value else {
                phase = .idle
                credentialRequest = target
                return
            }
            credential = stored
        } catch {
            phase = .idle
            NSLog("HomeLab: keychain read failed: %@", String(describing: error))
            notice = Notice(text: "O Keychain recusou o acesso à credencial. Nada foi enviado.", isError: true)
            return
        }

        var warning: String?
        if target == .session, status?.shareMode != wanted.gsettingsValue {
            if await setShareMode(wanted) {
                status?.shareMode = wanted.gsettingsValue
            } else {
                warning = "Sem SSH não foi possível trocar o modo de tela do host; conectando no modo atual."
            }
        }
        let plan = ConnectPlan(endpoint: endpoint, target: target, mode: wanted, size: size, displays: chosen,
                               hostMonitor: mirrorSource?.size, clipboard: clipboard)
        do {
            try launch(freerdpArguments(plan), credential: credential)
            phase = .connected
            notice = warning.map { Notice(text: $0, isError: true) }
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await refresh()
            }
        } catch PlanError.noLocalDisplay {
            phase = .idle
            notice = Notice(text: "Nenhum monitor local encontrado.", isError: true)
        } catch {
            phase = .idle
            notice = Notice(text: "Não foi possível abrir o cliente RDP.", isError: true)
        }
    }

    private func setShareMode(_ mode: ScreenMode) async -> Bool {
        let command = "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
            + "export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus; "
            + "gsettings set org.gnome.desktop.remote-desktop.rdp screen-share-mode " + mode.gsettingsValue
        for target in sshTargets where await ssh(target, command).ok { return true }
        return false
    }

    private func launch(_ arguments: [String], credential: Credential) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: freerdpPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "FREERDP_ASKPASS")
        // Otherwise LaunchServices files the client under this app's bundle id, and once the app
        // quits `open "Home Lab.app"` just focuses the RDP window instead of starting the app.
        environment.removeValue(forKey: "__CFBundleIdentifier")
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in self?.clientEnded(finished, code: code) }
        }
        try process.run()
        client = process
        // Credentials never enter argv, files, environment, logs, or clipboard.
        // FreeRDP reads username, blank domain and password from this private pipe.
        var data = Data((credential.username + "\n\n" + credential.password + "\n").utf8)
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        data.resetBytes(in: 0..<data.count)
    }

    private func clientEnded(_ process: Process, code: Int32) {
        guard client === process else { return }
        client = nil
        phase = .idle
        switch code {
        case 0, 1, 2, 12, 15: notice = Notice(text: "Sessão encerrada.", isError: false)
        case 5: notice = Notice(text: "Outra conexão assumiu a sessão.", isError: false)
        case 131: notice = Notice(text: "Não foi possível conectar ao host (código 131).", isError: true)
        case 132, 134: notice = Notice(text: "Credencial recusada pelo host (código \(code)).", isError: true)
        default: notice = Notice(text: "O cliente RDP encerrou com código \(code).", isError: true)
        }
        Task { await refresh() }
    }

    func disconnect() async {
        if let client, client.isRunning { client.terminate() }
        for pid in otherClientPIDs { kill(pid, SIGTERM) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        await refresh()
    }

    func saveCredential(_ credential: Credential, for target: Target) async {
        guard let endpoint = env.endpoint(target) else { return }
        do {
            try await Task.detached { try CredentialStore.store(credential, endpoint) }.value
            credentialRequest = nil
            await connect()
        } catch {
            credentialRequest = nil
            notice = Notice(text: "O Keychain não guardou a credencial. Nada foi gravado fora dele.", isError: true)
        }
    }

    func resetCredential() async {
        let target = effectiveTarget
        guard let endpoint = env.endpoint(target) else { return }
        do {
            try await Task.detached {
                try CredentialStore.delete(service: endpoint.keychainService, account: endpoint.keychainAccount)
            }.value
            notice = Notice(text: "Credencial de \(target.title.lowercased()) removida. Ela será pedida na próxima conexão.", isError: false)
        } catch {
            notice = Notice(text: "O Keychain não permitiu remover a credencial.", isError: true)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = Notice(text: "O macOS não permitiu alterar a abertura automática.", isError: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Host authentication

    private func storedLinuxPassword() async -> String? {
        let service = env.linuxPasswordService
        return try? await Task.detached {
            try CredentialStore.read(service: service, account: CredentialStore.linuxAccount)?.password
        }.value
    }

    private func askPassword(title: String, message: String) async -> (password: String, save: Bool)? {
        await withCheckedContinuation { continuation in
            passwordRequest = PasswordRequest(title: title, message: message) { [weak self] password, save in
                self?.passwordRequest = nil
                continuation.resume(returning: password.map { ($0, save) })
            }
        }
    }

    /// Runs a host command that may want the Linux password. Hosts that ask for nothing (blank
    /// keyring, NOPASSWD sudo) never see a prompt; otherwise the Keychain is tried before asking.
    /// One command of the host script, on the current environment.
    func host<T: Decodable>(_ command: String, _ parameters: [String: Any] = [:], timeout: TimeInterval = 15) async -> T? {
        await hostCall(sshTargets, command, parameters, timeout: timeout)?.value
    }

    func privileged<T: Decodable>(_ label: String, command: String, parameters: [String: Any],
                                          timeout: TimeInterval, accepted: (T) -> Bool) async -> T? {
        guard busyAction == nil else { return nil }
        busyAction = label
        defer { busyAction = nil }
        let service = env.linuxPasswordService, name = env.name
        var params = parameters
        let stored = await storedLinuxPassword()
        if let stored { params["password"] = stored }
        guard var result: T = await hostCall(sshTargets, command, params, timeout: timeout)?.value else {
            notice = Notice(text: "\(label): o host não respondeu por SSH.", isError: true)
            return nil
        }
        var refusedBefore = stored != nil
        while !accepted(result) {
            let message = refusedBefore ? "A senha foi recusada. Digite a senha do seu usuário no Linux."
                                        : "O host pede a senha do seu usuário no Linux para isto."
            guard let answer = await askPassword(title: label, message: message) else { return nil }
            params["password"] = answer.password
            guard let retry: T = await hostCall(sshTargets, command, params, timeout: timeout)?.value else {
                notice = Notice(text: "\(label): o host não respondeu por SSH.", isError: true)
                return nil
            }
            result = retry
            refusedBefore = true
            if accepted(result) && answer.save {
                let credential = Credential(username: "", password: answer.password)
                _ = try? await Task.detached {
                    try CredentialStore.delete(service: service, account: CredentialStore.linuxAccount)
                    try CredentialStore.store(credential, service: service, account: CredentialStore.linuxAccount,
                                              label: "\(name) — senha do Linux")
                }.value
            }
        }
        return result
    }

    func unlockScreen() async {
        guard busyAction == nil else { return }
        busyAction = "Desbloquear tela"
        let result: UnlockScreenResult? = await hostCall(sshTargets, "unlock-screen")?.value
        busyAction = nil
        notice = result?.ok == true ? Notice(text: "Pedido de desbloqueio enviado à sessão do host.", isError: false)
                                    : Notice(text: "Não foi possível desbloquear a tela do host.", isError: true)
        await refresh()
    }

    func unlockKeyrings() async {
        let result: KeyringUnlock? = await privileged("Destrancar cofres", command: "unlock-keyring", parameters: [:],
                                                      timeout: 25) { $0.ok }
        if let result {
            let names = result.results.map(\.label).joined(separator: ", ")
            notice = Notice(text: result.results.isEmpty ? "Nenhum cofre estava trancado." : "Cofre destrancado: \(names).", isError: false)
        }
        await refresh()
    }

    func runAdmin(_ action: AdminAction) async {
        var params: [String: Any] = ["argv": action.argv, "timeout": action.timeout]
        if !action.env.isEmpty { params["env"] = action.env }
        let result: SudoResult? = await privileged(action.title, command: "sudo", parameters: params,
                                                   timeout: TimeInterval(action.timeout + 20)) { $0.auth }
        guard let result else { return }
        let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        actionOutput = "$ sudo " + action.argv.joined(separator: " ") + "\n" + (output.isEmpty ? "(sem saída)" : output)
            + (result.ok ? "" : "\n[código \(result.code ?? -1)]")
        notice = result.ok ? Notice(text: "\(action.title): concluído.", isError: false)
                           : Notice(text: "\(action.title): terminou com código \(result.code ?? -1).", isError: true)
        await refresh()
    }

    func runAdminShell(_ command: String) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runAdmin(AdminAction(id: "custom", title: "Comando de administrador", argv: ["sh", "-c", trimmed], timeout: 300))
    }

    func setPolkit(_ enable: Bool) async {
        let label = enable ? "Liberar diálogos de administrador" : "Voltar a pedir senha nos diálogos"
        let result: SudoResult? = await privileged(label, command: "polkit", parameters: ["enable": enable],
                                                   timeout: 40) { $0.auth }
        if let result {
            notice = result.ok && result.polkitOpen == enable
                ? Notice(text: enable ? "Diálogos de administrador liberados para o seu usuário neste host."
                                      : "O host voltou a pedir senha nos diálogos de administrador.", isError: false)
                : Notice(text: "\(label): a regra não entrou em vigor.", isError: true)
        }
        await refresh()
    }

    // MARK: System controls

    func refreshSystem() async {
        let envID = environmentID
        let info: SystemInfo? = await host("system", timeout: 35)
        if envID == environmentID, let info { system = info }
    }

    /// One of the fixed maintenance actions of the host script.
    func systemAction(_ action: String, label: String, extra: [String: Any] = [:]) async {
        var params = extra
        params["action"] = action
        let result: ActionResult? = await privileged(label, command: "system-action", parameters: params, timeout: 260) { $0.auth }
        if let result {
            let detail = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            notice = result.ok ? Notice(text: "\(label): feito." + (detail.isEmpty ? "" : " " + detail), isError: false)
                               : Notice(text: "\(label) falhou" + (detail.isEmpty ? "." : ": " + detail), isError: true)
        }
        await refreshSystem()
        await refresh()
    }

    // MARK: Ports

    /// Opens a host port in the browser. A port that only listens on the host's loopback gets an SSH
    /// tunnel first, so it shows up on this Mac's localhost.
    func openPort(_ port: PortInfo) async {
        if port.exposure != "local" {
            if let url = portURL(port, environment: env, tunnelPort: nil) { NSWorkspace.shared.open(url) }
            return
        }
        if tunnels[port.port] == nil {
            guard let target = sshAlias else {
                notice = Notice(text: "Sem SSH não dá para abrir um túnel até a porta \(port.port).", isError: true)
                return
            }
            // Same number on this side when it is free, otherwise a high port nobody uses.
            var local = port.port >= 1024 ? port.port : port.port + 20000
            if await portOpen("127.0.0.1", String(local)) { local = 20000 + port.port % 20000 }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                                 "-L", "127.0.0.1:\(local):127.0.0.1:\(port.port)", target]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let remote = port.port
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in self?.tunnels[remote] = nil; self?.tunnelProcesses[remote] = nil }
            }
            do { try process.run() } catch {
                notice = Notice(text: "Não foi possível abrir o túnel SSH.", isError: true)
                return
            }
            tunnelProcesses[remote] = process
            tunnels[remote] = local
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard process.isRunning else {
                notice = Notice(text: "O túnel para a porta \(remote) não subiu.", isError: true)
                return
            }
        }
        if let url = portURL(port, environment: env, tunnelPort: tunnels[port.port]) { NSWorkspace.shared.open(url) }
    }

    func closeTunnel(_ remote: Int) {
        tunnelProcesses[remote]?.terminate()
    }

    func closeAllTunnels() {
        tunnelProcesses.values.forEach { $0.terminate() }
    }

    // MARK: Files

    func loadFolder(_ path: String) async {
        guard !path.isEmpty, !loadingFolders.contains(path) else { return }
        loadingFolders.insert(path)
        defer { loadingFolders.remove(path) }
        let envID = environmentID
        let listing: FileListing? = await hostCall(sshTargets, "ls", ["path": path, "hidden": showHidden])?.value
        guard envID == environmentID else { return }
        listings[path] = listing ?? FileListing(path: path, parent: path, entries: [], truncated: false,
                                                error: "sem resposta do host")
    }

    func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
            if listings[path] == nil { Task { await loadFolder(path) } }
        }
    }

    func setFileRoot(_ path: String) {
        fileRoot = path
        Task { await loadFolder(path) }
    }

    func fileRootUp() {
        guard fileRoot != "/", !fileRoot.isEmpty else { return }
        let parent = (fileRoot as NSString).deletingLastPathComponent
        // Keep what was open: the old root shows up expanded inside its parent.
        expandedFolders.insert(fileRoot)
        setFileRoot(parent.isEmpty ? "/" : parent)
    }

    func reloadFiles() {
        let open = [fileRoot] + expandedFolders.filter { listings[$0] != nil }
        Task { for path in open { await loadFolder(path) } }
    }

    var visibleFileRows: [FileRow] { fileRows(root: fileRoot, listings: listings, expanded: expandedFolders) }

    /// Copies one file to ~/Downloads over SFTP and shows it in Finder.
    func download(_ row: FileRow) async {
        guard !row.entry.dir, let target = sshAlias, busyAction == nil else { return }
        busyAction = "Baixar \(row.entry.name)"
        defer { busyAction = nil }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var destination = downloads.appendingPathComponent(row.entry.name)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (row.entry.name as NSString).deletingPathExtension, ext = (row.entry.name as NSString).pathExtension
            destination = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        // scp speaks SFTP, so the remote path is taken literally; brackets keep IPv6 targets working.
        let result = await run("/usr/bin/scp", sshOptions + ["-q", "--", "\(target):\(row.path)", destination.path], timeout: 600)
        if result.ok {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            notice = Notice(text: "\(row.entry.name) salvo em Downloads.", isError: false)
        } else {
            try? FileManager.default.removeItem(at: destination)
            notice = Notice(text: "Não foi possível baixar \(row.entry.name).", isError: true)
        }
    }
}

struct UnlockScreenResult: Codable {
    var ok: Bool
    var error: String?
}
