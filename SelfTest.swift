import Foundation

// `HomeLab selftest`: scenario checks for the pure code. Opens no connection.

func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  → " + detail()))
        if !ok { failures += 1 }
    }
    let env = HostEnvironment(
        id: HostEnvironment.legacyID, name: "Home Lab", rdpHost: "lab.example.ts.net", sshTargets: ["lab-ts", "lab"],
        sessionPort: 3390, sessionFingerprint: "aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44",
        loginPort: 3389, loginFingerprint: "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
        smbURL: "smb://192.0.2.10/home", lanHost: "192.0.2.10", tailscaleName: "lab")
    let host = env.rdpHost
    // Main ultrawide plus a second display to its right, as SDL reports them.
    let wide = LocalDisplay(id: 1, name: "LC34G55T", originX: 0, originY: 0, size: PixelSize(3440, 1440),
                            usableOriginX: 0, usableOriginY: 53, usable: PixelSize(3440, 1317))
    let side = LocalDisplay(id: 2, name: "LF27T35", originX: 3440, originY: 206, size: PixelSize(1920, 1080),
                            usableOriginX: 3440, usableOriginY: 234, usable: PixelSize(1920, 1052))
    func plan(_ target: Target = .session, _ mode: ScreenMode = .virtual, _ size: SizeChoice = .fit,
              _ displays: [LocalDisplay], host: PixelSize? = nil, clipboard: Bool = false) -> ConnectPlan {
        ConnectPlan(endpoint: env.endpoint(target)!, target: target, mode: mode, size: size, displays: displays,
                    hostMonitor: host, clipboard: clipboard)
    }
    func args(_ p: ConnectPlan) -> [String] { (try? freerdpArguments(p)) ?? [] }

    // Headless host, virtual screen sized to the Mac display.
    var a = args(plan(.session, .virtual, .fit, [wide]))
    check("virtual/fit uses the display's usable area", a.contains("/size:3440x1316"), "\(a)")
    check("virtual/fit resizes with the window", a.contains("+dynamic-resolution") && !a.contains("/smart-sizing"), "\(a)")
    check("virtual/fit opens on the chosen display", a.contains("/window-position:0x53"), "\(a)")
    check("session uses port and pin 3390", a.contains("/v:\(host):3390")
          && a.contains("/cert:deny,fingerprint:sha256:" + env.sessionFingerprint), "\(a)")
    check("NLA and stdin credentials are kept", a.contains("/sec:nla") && a.contains("/from-stdin")
          && !a.contains { $0.hasPrefix("/p:") || $0.hasPrefix("/u:") }, "\(a)")
    check("clipboard is off by default", a.contains("-clipboard") && !a.contains("+clipboard"), "\(a)")
    a = args(plan(.session, .virtual, .fit, [wide], clipboard: true))
    check("clipboard toggle", a.contains("+clipboard") && !a.contains("-clipboard"), "\(a)")

    // Different resolutions, second display.
    a = args(plan(.session, .virtual, .fixed(PixelSize(1280, 720)), [side]))
    check("fixed size is centred on the second display", a.contains("/size:1280x720")
          && a.contains("/window-position:3760x400"), "\(a)")
    a = args(plan(.session, .virtual, .fixed(PixelSize(2560, 1440)), [side]))
    check("fixed size larger than the display stays on it", a.contains("/size:2560x1440")
          && a.contains("/window-position:3440x234"), "\(a)")
    a = args(plan(.session, .virtual, .fixed(PixelSize(1367, 769)), [side]))
    check("odd dimensions are rounded down to even", a.contains("/size:1366x768"), "\(a)")
    a = args(plan(.session, .virtual, .fullscreen, [side]))
    check("fullscreen targets the chosen display", a.contains("+f") && a.contains("/monitors:2")
          && a.contains("/size:1920x1080") && a.contains("+dynamic-resolution")
          && !a.contains { $0.hasPrefix("/window-position") }, "\(a)")

    // Host with a physical monitor: mirror it at its own resolution.
    a = args(plan(.session, .mirror, .fit, [wide], host: PixelSize(1920, 1080)))
    check("mirror opens at the host monitor's size when it fits", a.contains("/size:1920x1080")
          && a.contains("/window-position:760x171"), "\(a)")
    check("mirror scales instead of resizing the host", a.contains("/smart-sizing")
          && !a.contains("+dynamic-resolution"), "\(a)")
    a = args(plan(.session, .mirror, .fit, [side], host: PixelSize(3840, 2160)))
    check("mirror of a larger host monitor keeps its aspect ratio", a.contains("/size:1870x1052"), "\(a)")
    a = args(plan(.session, .mirror, .fullscreen, [side], host: PixelSize(2560, 1440)))
    check("mirror fullscreen", a.contains("+f") && a.contains("/monitors:2") && a.contains("/smart-sizing"), "\(a)")
    var refusal: PlanError?
    do { _ = try freerdpArguments(plan(.session, .mirror, .fit, [wide])) } catch { refusal = error as? PlanError }
    check("mirror without a host monitor is refused", refusal == .mirrorNeedsHostMonitor)

    // Remote login never mirrors, whatever the stored mode says.
    a = args(plan(.login, .mirror, .fit, [wide]))
    check("login ignores mirror mode", a.contains("+dynamic-resolution") && !a.contains("/smart-sizing")
          && a.contains("/v:\(host):3389")
          && a.contains("/cert:deny,fingerprint:sha256:" + (env.loginFingerprint ?? "")), "\(a)")

    // Several Mac displays: one virtual screen each.
    a = args(plan(.session, .virtual, .fixed(PixelSize(1280, 720)), [wide, side]))
    check("two displays open as multimon fullscreen", a.contains("/multimon") && a.contains("/monitors:1,2")
          && a.contains("+f") && a.contains("+dynamic-resolution"), "\(a)")
    check("two displays ignore the single-window size",
          !a.contains { $0.hasPrefix("/size:") || $0.hasPrefix("/window-position") }, "\(a)")
    a = args(plan(.login, .virtual, .fit, [wide, side]))
    check("login also supports two displays", a.contains("/multimon") && a.contains("/v:\(host):3389"), "\(a)")
    a = args(plan(.session, .mirror, .fit, [wide, side], host: PixelSize(1920, 1080)))
    check("mirror stays on the first display only", !a.contains("/multimon") && a.contains("/smart-sizing"), "\(a)")
    var noDisplay: PlanError?
    do { _ = try freerdpArguments(plan(.session, .virtual, .fit, [])) } catch { noDisplay = error as? PlanError }
    check("no local display is refused", noDisplay == .noLocalDisplay)

    // Environments.
    let legacy = env.endpoint(.session)!
    check("original environment keeps the Keychain items of the first helper",
          legacy.keychainService == "com.codex.homelab-rdp.v1.3390" && legacy.keychainAccount == "endpoint-3390"
          && env.endpoint(.login)?.keychainService == "com.codex.homelab-rdp.v1.3389")
    var other = env
    other.id = "estudio"; other.name = "Estúdio"; other.rdpHost = "10.0.0.9"; other.sessionPort = 3391
    other.loginPort = nil; other.loginFingerprint = nil
    let otherEndpoint = other.endpoint(.session)!
    check("each environment has its own Keychain items and address",
          otherEndpoint.keychainService == "com.codex.homelab-rdp.v2.estudio.session" && otherEndpoint.host == "10.0.0.9"
          && otherEndpoint.port == 3391 && other.linuxPasswordService != env.linuxPasswordService)
    check("environment without remote login offers only the session", other.targets == [.session]
          && other.endpoint(.login) == nil && env.targets == [.session, .login])
    a = (try? freerdpArguments(ConnectPlan(endpoint: otherEndpoint, target: .session, mode: .virtual, size: .fit,
                                           displays: [wide], hostMonitor: nil, clipboard: false))) ?? []
    check("plan dials the selected environment", a.contains("/v:10.0.0.9:3391") && a.contains("/t:Estúdio — sessão atual"), "\(a)")
    let encoded = try? JSONEncoder().encode([env, other])
    check("environments survive a save and load",
          encoded.flatMap { try? JSONDecoder().decode([HostEnvironment].self, from: $0) } == [env, other])

    let pin = "aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44"
    check("fingerprint: colon and upper-case forms are accepted",
          normalizeFingerprint("AA:11:BB:22:CC:33:DD:44:EE:55:FF:66:AA:11:BB:22:CC:33:DD:44:EE:55:FF:66:AA:11:BB:22:CC:33:DD:44") == pin
          && normalizeFingerprint(pin) == pin)
    check("fingerprint: wrong length or junk is refused", normalizeFingerprint("") == nil
          && normalizeFingerprint(String(pin.dropLast())) == nil && normalizeFingerprint(pin + "00") == nil
          && normalizeFingerprint("sha256:" + pin) == nil && normalizeFingerprint(String(pin.dropLast()) + "g") == nil)
    check("ssh target: aliases, user@host and addresses", validSSHTarget("homelab-ts") && validSSHTarget("ana@10.0.0.9")
          && validSSHTarget("me@host.tail.ts.net") && validSSHTarget("user@[fe80::1]"))
    check("ssh target: options, spaces and shell characters are refused", !validSSHTarget("-oProxyCommand=x")
          && !validSSHTarget("") && !validSSHTarget("a b") && !validSSHTarget("host;rm") && !validSSHTarget("a@b@c")
          && !validSSHTarget("host$(x)") && !validSSHTarget(String(repeating: "a", count: 300)))
    check("slug: accents, spaces and collisions", slug("Estúdio São Paulo", taken: []) == "estudio-sao-paulo"
          && slug("Estúdio", taken: ["estudio"]) == "estudio-2" && slug("Estúdio", taken: ["estudio", "estudio-2"]) == "estudio-3"
          && slug("!!!", taken: []) == "ambiente" && slug("default", taken: []) == "default-2")

    // Host script transport.
    let input = String(data: hostScriptInput(script: "print(1)\n", parameters: ["password": "a\"b\n$c", "n": 2]), encoding: .utf8) ?? ""
    let firstLine = input.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    let payload = firstLine.dropFirst("HOMELAB_PARAMS = \"".count).dropLast()
    let decoded = Data(base64Encoded: String(payload)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    check("host script: parameters travel base64 on the first line", firstLine.hasPrefix("HOMELAB_PARAMS = \"")
          && decoded?["password"] as? String == "a\"b\n$c" && decoded?["n"] as? Int == 2 && input.hasSuffix("print(1)\n"))
    check("host script: a secret never appears in clear", !input.contains("a\"b"))

    // Parsing and persistence.
    check("size parser accepts WxH", PixelSize("1920x1080") == PixelSize(1920, 1080) && PixelSize("3440X1440") != nil)
    check("size parser rejects junk", PixelSize("") == nil && PixelSize("1920") == nil && PixelSize("0x0") == nil
          && PixelSize("99999x1080") == nil && PixelSize("axb") == nil && PixelSize("1920x1080x2") == nil)
    check("size choice round-trips", [SizeChoice.fit, .fullscreen, .fixed(PixelSize(1600, 900))]
        .allSatisfy { SizeChoice(storage: $0.storage) == $0 })
    check("unknown stored size falls back to fit", SizeChoice(storage: "garbage") == .fit)

    let listed = parseMonitorList("listing 2 monitors:\n     * [1] [LC34G55T] 3440x1440\t+0+0\n       [2] [LF27T35] 1920x1080\t+3440+206\n")
    check("monitor list: two displays", listed.count == 2 && listed[0].id == 1 && listed[1].name == "LF27T35"
          && listed[1].x == 3440 && listed[1].y == 206 && listed[1].size == PixelSize(1920, 1080), "\(listed)")
    let left = parseMonitorList("  [3] [Built-in Retina Display] 1728x1117\t-1728+0")
    check("monitor list: negative origin and spaces in name", left.count == 1 && left[0].x == -1728
          && left[0].name == "Built-in Retina Display", "\(left)")
    check("monitor list: no displays", parseMonitorList("listing 0 monitors:\n").isEmpty)

    // Host status decoding.
    func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) -> T? { try? JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    let base = #""hostname":"h","uptimeSeconds":90,"load":"0.1","remoteDesktopActive":true"#
    let headless: HostStatus? = decode("{\(base),\"shareMode\":\"extend\",\"monitors\":[],\"physicalConnected\":[],\"rdpClients\":0,\"locked\":null}")
    check("status: headless host has nothing to mirror", headless != nil && headless?.mirrorSource == nil)
    let virtualOnly: HostStatus? = decode("{\(base),\"shareMode\":\"extend\",\"monitors\":[{\"connector\":\"Meta-0\",\"name\":\"Virtual remote monitor\",\"width\":1280,\"height\":720,\"virtual\":true,\"primary\":true}],\"physicalConnected\":[],\"rdpClients\":1,\"locked\":false}")
    check("status: a virtual monitor is not a mirror source", virtualOnly?.mirrorSource == nil && virtualOnly?.rdpClients == 1)
    let mixed: HostStatus? = decode("{\(base),\"shareMode\":\"mirror-primary\",\"monitors\":[{\"connector\":\"DP-1\",\"name\":\"A\",\"width\":2560,\"height\":1440,\"virtual\":false,\"primary\":false},{\"connector\":\"HDMI-1\",\"name\":\"LF27T35\",\"width\":1920,\"height\":1080,\"virtual\":false,\"primary\":true},{\"connector\":\"Meta-0\",\"name\":\"V\",\"width\":1280,\"height\":720,\"virtual\":true,\"primary\":false}],\"physicalConnected\":[\"DP-1\",\"HDMI-A-1\"],\"rdpClients\":0,\"locked\":true}")
    check("status: mirror source is the primary physical monitor", mixed?.mirrorSource?.connector == "HDMI-1"
          && mixed?.physicalMonitors.count == 2)
    let rich: HostStatus? = decode("{\(base),\"shareMode\":\"extend\",\"monitors\":[],\"physicalConnected\":[],\"rdpClients\":0,\"locked\":null,\"listening\":[3390],\"polkitOpen\":false,\"sudoNeedsPassword\":false,\"keyrings\":[{\"path\":\"/a\",\"label\":\"Login\",\"locked\":false,\"items\":16},{\"path\":\"/b\",\"label\":\"Default Keyring\",\"locked\":true,\"items\":4}],\"metrics\":{\"cpuPercent\":12.5,\"gpu\":{\"name\":\"RTX 2060\",\"util\":3,\"memUsedMB\":891,\"memTotalMB\":6144,\"temp\":36,\"power\":null,\"fan\":null},\"disks\":[{\"mount\":\"/\",\"totalGB\":875,\"usedGB\":780}],\"services\":[{\"name\":\"comfyui\",\"active\":\"active\",\"sub\":\"running\"}]}}")
    check("status: listening ports are optional", rich?.listening == [3390] && headless?.listening == nil)
    check("status: metrics decode with missing pieces", rich?.metrics?.cpuPercent == 12.5 && rich?.metrics?.gpu?.power == nil
          && rich?.metrics?.memTotalMB == nil && rich?.metrics?.services?.first?.name == "comfyui")
    check("status: disk percentage", abs((rich?.metrics?.disks?.first?.percent ?? 0) - 89.14) < 0.01
          && DiskInfo(mount: "/x", totalGB: 0, usedGB: 0).percent == 0)
    let three = [DiskInfo(mount: "/", totalGB: 939, usedGB: 661), DiskInfo(mount: "/mnt/a", totalGB: 491, usedGB: 392),
                 DiskInfo(mount: "/mnt/b", totalGB: 100, usedGB: 1)]
    check("disks: default is root, a chosen mount wins, a vanished mount falls back", pickDisk(three, mount: "")?.mount == "/"
          && pickDisk(three, mount: "/mnt/b")?.mount == "/mnt/b" && pickDisk(three, mount: "/gone")?.mount == "/"
          && pickDisk(Array(three.dropFirst()), mount: "/gone")?.mount == "/mnt/a" && pickDisk([], mount: "/") == nil)
    check("disks: cycling wraps both ways", nextDisk(three, after: "/")?.mount == "/mnt/a"
          && nextDisk(three, after: "/mnt/b")?.mount == "/" && nextDisk(three, after: "/", step: -1)?.mount == "/mnt/b"
          && nextDisk(three, after: "/gone")?.mount == "/mnt/a" && nextDisk(three, after: nil)?.mount == "/mnt/a")
    check("disks: one disk cycles to itself, none to nothing", nextDisk([three[0]], after: "/")?.mount == "/"
          && nextDisk([], after: "/") == nil)
    check("status: only locked keyrings need unlocking", rich?.lockedKeyrings.map(\.label) == ["Default Keyring"]
          && headless?.lockedKeyrings.isEmpty == true)
    check("status: metrics are optional", headless?.metrics == nil)
    check("status: malformed payload is rejected", (decode("{}") as HostStatus?) == nil && (decode("not json") as HostStatus?) == nil)

    // Files.
    func listing(_ path: String, _ names: [(String, Bool)]) -> FileListing {
        FileListing(path: path, parent: "/", entries: names.map { FileEntry(name: $0.0, dir: $0.1, link: false, size: 1, mtime: 0) },
                    truncated: false, error: nil)
    }
    let listings = ["/home/a": listing("/home/a", [("docs", true), ("src", true), ("a.txt", false)]),
                    "/home/a/docs": listing("/home/a/docs", [("deep", true), ("b.md", false)]),
                    "/home/a/docs/deep": listing("/home/a/docs/deep", [("c", false)]),
                    "/home/a/src": listing("/home/a/src", [])]
    var rows = fileRows(root: "/home/a", listings: listings, expanded: [])
    check("tree: collapsed shows only the root folder", rows.map(\.path) == ["/home/a/docs", "/home/a/src", "/home/a/a.txt"])
    rows = fileRows(root: "/home/a", listings: listings, expanded: ["/home/a/docs", "/home/a/docs/deep", "/home/a/src"])
    check("tree: expanded folders nest in order with depth",
          rows.map(\.path) == ["/home/a/docs", "/home/a/docs/deep", "/home/a/docs/deep/c", "/home/a/docs/b.md", "/home/a/src", "/home/a/a.txt"]
          && rows.map(\.depth) == [0, 1, 2, 1, 0, 0])
    rows = fileRows(root: "/home/a", listings: listings, expanded: ["/home/a/docs/deep", "/home/a/missing"])
    check("tree: a child stays hidden while its parent is collapsed or not loaded", rows.count == 3)
    check("tree: unknown root is empty", fileRows(root: "/nope", listings: listings, expanded: []).isEmpty)
    check("tree: root slash joins without doubling", joinPath("/", "etc") == "/etc" && joinPath("/a", "b") == "/a/b")
    let denied: FileListing? = decode(#"{"path":"/root","parent":"/","entries":[],"truncated":false,"error":"Permission denied"}"#)
    check("listing: error and odd names decode", denied?.error == "Permission denied"
          && (decode(#"{"path":"/t","parent":"/","entries":[{"name":"it's \"x\" $(y) é","dir":false,"link":true,"size":0,"mtime":1}],"truncated":true}"#) as FileListing?)?.entries.first?.name == "it's \"x\" $(y) é")
    check("byte formatting", formatBytes(0) == "0 B" && formatBytes(1023) == "1023 B" && formatBytes(1536) == "1.5 KB"
          && formatBytes(250 * 1024 * 1024) == "250 MB" && formatBytes(-5) == "0 B")

    // Host actions.
    let sudoOK: SudoResult? = decode(#"{"ok":true,"auth":true,"code":0,"output":"0"}"#)
    let sudoDenied: SudoResult? = decode(#"{"ok":false,"auth":false}"#)
    check("sudo: success, refused password and failed command are told apart", sudoOK?.ok == true
          && sudoDenied?.auth == false && (decode(#"{"ok":false,"auth":true,"code":3,"output":"x"}"#) as SudoResult?)?.code == 3)
    let unlock: KeyringUnlock? = decode(#"{"ok":false,"auth":false,"results":[{"label":"Login","ok":true},{"label":"Default Keyring","ok":false}],"keyrings":[]}"#)
    check("keyring: partial unlock reports each keyring", unlock?.ok == false && unlock?.results.filter(\.ok).count == 1)
    check("admin actions: destructive ones ask first", AdminAction.presets.filter { $0.confirm != nil }.map(\.id) == ["apt-upgrade", "reboot", "poweroff"]
          && Set(AdminAction.presets.map(\.id)).count == AdminAction.presets.count)

    // Services, containers, processes.
    let unitsJSON = #"{"units":[{"scope":"user","name":"comfyui.service","description":"ComfyUI na GPU","active":"active","sub":"running","enabled":"enabled","custom":true,"result":"success","restarts":0,"activeSeconds":53041,"memoryMB":331.2,"pid":2808},{"scope":"user","name":"bd-sync.service","description":"mantem o bd","active":"inactive","sub":"dead","enabled":"static","custom":true,"timer":"bd-sync.timer","timerActive":true,"nextRun":"Thu 2026-10-08 23:00:00 -03"},{"scope":"user","name":"gvfs-daemon.service","description":"Virtual filesystem","active":"active","sub":"running","enabled":"static","custom":false},{"scope":"system","name":"apport-autoreport.service","description":"Process error reports","active":"failed","sub":"failed","enabled":"static","custom":false,"result":"exit-code"},{"scope":"user","name":"old.service","description":"","active":"inactive","sub":"dead","enabled":"disabled","custom":true}]}"#
    let units = (decode(unitsJSON) as UnitList?)?.units ?? []
    check("units: decode with optional fields", units.count == 5 && units[0].memoryMB == 331.2 && units[1].pid == nil
          && units[1].timer == "bd-sync.timer" && units[0].shortName == "comfyui")
    check("units: filters keep scopes apart", filterUnits(units, filter: .mine, search: "").map(\.shortName) == ["comfyui", "bd-sync", "old"]
          && filterUnits(units, filter: .user, search: "").count == 4 && filterUnits(units, filter: .system, search: "").map(\.name) == ["apport-autoreport.service"])
    check("units: search matches name and description, ignoring case", filterUnits(units, filter: .user, search: " GPU ").map(\.shortName) == ["comfyui"]
          && filterUnits(units, filter: .user, search: "SYNC").count == 1 && filterUnits(units, filter: .mine, search: "zzz").isEmpty
          && filterUnits([], filter: .mine, search: "").isEmpty)
    check("units: state wording tells a timer job from a stopped service", unitStateText(units[0]) == "em execução"
          && unitStateText(units[1]) == "aguardando o timer" && unitStateText(units[3]) == "falhou" && unitStateText(units[4]) == "parado")
    check("units: tone", unitTone(units[0]) == .good && unitTone(units[1]) == .idle && unitTone(units[3]) == .bad)
    check("units: boot toggle only where it applies", units[0].canToggleBoot && units[4].canToggleBoot && !units[1].canToggleBoot)
    check("units: names are validated before leaving the Mac", validUnitName("comfyui.service") && validUnitName("user@1000.service")
          && validUnitName("bd-sync.timer") && !validUnitName("a; rm -rf x.service") && !validUnitName("--help.service")
          && !validUnitName("comfyui") && !validUnitName("") && !validUnitName("a b.service") && !validUnitName("x.socket"))
    let boxes = (decode(#"{"available":true,"containers":[{"id":"b213","name":"web-1","image":"nginx","state":"running","status":"Up 15 hours","ports":"127.0.0.1:4300->80/tcp","project":"site"},{"id":"c1","name":"job","image":"busybox","state":"exited","status":"Exited (0) 2 hours ago","ports":"","project":""},{"id":"c2","name":"crash","image":"api","state":"exited","status":"Exited (137) 1 minute ago","ports":"","project":"site"}]}"#) as ContainerList?)?.containers ?? []
    check("containers: tone separates a clean exit from a crash", boxes.map(containerTone) == [.good, .idle, .bad]
          && boxes.map(\.isRunning) == [true, false, false])
    check("containers: search covers name, image and project", filterContainers(boxes, search: "SITE").count == 2
          && filterContainers(boxes, search: "busy").map(\.name) == ["job"] && filterContainers(boxes, search: "").count == 3)
    check("containers: docker missing is reported, not an empty list", (decode(#"{"available":false,"containers":[],"error":"permission denied"}"#) as ContainerList?)?.available == false)
    let procs = (decode(#"{"processes":[{"pid":4197,"name":"localsearch-3","cpu":98.4,"memMB":1380.5,"seconds":53035,"user":"ana","own":true,"command":"/usr/libexec/localsearch-3"},{"pid":3666,"name":"dockerd","cpu":1.9,"memMB":119.5,"seconds":10,"user":"root","own":false,"command":""}],"cores":12}"#) as ProcessList?)
    check("processes: decode, ownership decides who may be killed without sudo", procs?.processes.map(\.own) == [true, false] && procs?.cores == 12)
    check("actions: refused, failed and done are distinct", (decode(#"{"ok":false,"auth":false,"output":""}"#) as ActionResult?)?.auth == false
          && (decode(#"{"ok":false,"auth":true,"output":"Unit x not found."}"#) as ActionResult?)?.output == "Unit x not found."
          && (decode(#"{"ok":true,"auth":true}"#) as ActionResult?)?.ok == true)
    check("logs: container detail carries the stats when present", (decode(#"{"ok":true,"text":"a\nb","cpu":"0.00%","memory":"9MiB / 30GiB"}"#) as LogResult?)?.cpu == "0.00%"
          && (decode(#"{"ok":false,"text":"invalid request"}"#) as LogResult?)?.memory == nil)
    check("memory formatting", formatMemory(331.2) == "331 MB" && formatMemory(1380.5) == "1.3 GB" && formatMemory(0) == "0 MB")

    // Ports, Tailscale, Cloudflare, Docker details.
    let portList: PortList? = decode(#"{"ports":[{"proto":"tcp","port":22,"exposure":"public","addresses":["0.0.0.0","[::]"],"process":"sshd","pid":900,"unit":"ssh.service","container":"","ufwAllowed":false},{"proto":"tcp","port":4300,"exposure":"local","addresses":["127.0.0.1"],"process":"docker-proxy","pid":6850,"unit":"docker.service","container":"game-1","ufwAllowed":false},{"proto":"tcp","port":8443,"exposure":"tailnet","addresses":["100.64.0.7"],"process":"tailscaled","pid":1,"unit":"tailscaled.service","container":""},{"proto":"udp","port":5353,"exposure":"public","addresses":["0.0.0.0"],"process":"","pid":0,"unit":"","container":""}],"firewall":{"state":"active","allowed":[445],"rules":["445/tcp ALLOW Anywhere"]}}"#)
    let ports = portList?.ports ?? []
    check("ports: owner prefers container, then unit, then process", ports.map(\.owner) == ["ssh", "game-1", "tailscaled", "desconhecido"])
    check("ports: scopes and UDP switch", filterPorts(ports, scope: .all, search: "", udp: false).count == 3
          && filterPorts(ports, scope: .all, search: "", udp: true).count == 4
          && filterPorts(ports, scope: .lan, search: "", udp: false).map(\.port) == [22]
          && filterPorts(ports, scope: .local, search: "", udp: false).map(\.port) == [4300]
          && filterPorts(ports, scope: .tailnet, search: "", udp: true).map(\.port) == [8443])
    check("ports: search by number, owner and process", filterPorts(ports, scope: .all, search: "430", udp: false).map(\.port) == [4300]
          && filterPorts(ports, scope: .all, search: "GAME", udp: false).count == 1
          && filterPorts(ports, scope: .all, search: "sshd", udp: false).count == 1 && filterPorts(ports, scope: .all, search: "zz", udp: true).isEmpty)
    check("ports: address a browser can use", portURL(ports[0], environment: env, tunnelPort: nil)?.absoluteString == "http://192.0.2.10:22"
          && portURL(ports[2], environment: env, tunnelPort: nil)?.absoluteString == "https://lab.example.ts.net:8443"
          && portURL(ports[1], environment: env, tunnelPort: nil) == nil
          && portURL(ports[1], environment: env, tunnelPort: 24300)?.absoluteString == "http://localhost:24300"
          && portURL(ports[3], environment: env, tunnelPort: nil) == nil
          && portURL(ports[0], environment: other, tunnelPort: nil)?.host == "192.0.2.10")
    check("firewall: state and allowed ports decode", portList?.firewall.state == "active" && portList?.firewall.allowed == [445])
    let ts: TailscaleInfo? = decode(#"{"installed":true,"version":"1.104.1","state":"Running","name":"box.tail.ts.net","ips":["100.1.1.1"],"serve":[{"port":443,"path":"/","funnel":false,"target":"http://127.0.0.1:3774","url":"https://box.tail.ts.net/"},{"port":8443,"path":"/","funnel":true,"target":"http://127.0.0.1:3101","url":"https://box.tail.ts.net:8443/"}],"peers":[{"name":"mac","ip":"100.2.2.2","os":"macOS","online":true}]}"#)
    check("tailscale: status, serve and funnel decode", ts?.running == true && ts?.serve.filter(\.funnel).map(\.port) == [8443] && ts?.peers.first?.online == true)
    check("tailscale: absent or stopped", (decode(#"{"installed":false,"serve":[],"peers":[]}"#) as TailscaleInfo?)?.running == false
          && (decode(#"{"installed":true,"state":"NeedsLogin","serve":[],"peers":[]}"#) as TailscaleInfo?)?.running == false)
    check("tailscale: serve target must be local", validServeTarget("3000") && validServeTarget("http://127.0.0.1:3000") && validServeTarget("https://localhost:8443/app")
          && !validServeTarget("http://evil.example.com") && !validServeTarget("0") && !validServeTarget("70000") && !validServeTarget("")
          && !validServeTarget("ftp://127.0.0.1") && !validServeTarget("http://10.0.0.5:80"))
    let cfInfo: CloudflareInfo? = decode(#"{"installed":true,"version":"2026.10.0","service":"inactive","serviceInstalled":false,"loggedIn":true,"tunnels":[{"id":"a","name":"homelab","created":"2026-08-19","connections":4}],"quick":[{"port":18459,"url":"https://x.trycloudflare.com"}]}"#)
    check("cloudflare: tunnels and quick tunnels decode", cfInfo?.tunnels.first?.connections == 4 && cfInfo?.quick.first?.port == 18459
          && (decode(#"{"installed":false,"tunnels":[],"quick":[]}"#) as CloudflareInfo?)?.installed == false)
    check("cloudflare: hostnames", validHostname("app.example.dev") && validHostname("a-b.example.com") && !validHostname("localhost")
          && !validHostname("not a host") && !validHostname("a..b.com") && !validHostname(".com") && !validHostname("x.c") && !validHostname("é.com"))
    check("actions: an address to open rides along", (decode(#"{"ok":true,"auth":true,"output":"","url":"https://login.tailscale.com/a/1"}"#) as ActionResult?)?.url == "https://login.tailscale.com/a/1")
    let detail: ContainerDetail? = decode(#"{"ok":true,"image":"api","restart":"unless-stopped","env":[{"key":"AWS_SECRET_ACCESS_KEY","value":"••••••"},{"key":"PORT","value":"3000"}],"mounts":["/a → /b"],"composeFiles":["/x/compose.yml"],"project":"cannexo-dev"}"#)
    check("docker: details decode; secret values arrive masked", detail?.env?.first?.value == "••••••" && detail?.composeFiles?.count == 1
          && (decode(#"{"ok":false,"error":"No such object"}"#) as ContainerDetail?)?.error != nil)
    check("files: content, refusal and missing permission decode", (decode(#"{"ok":true,"auth":true,"path":"/a","content":"x\n","writable":false,"backup":true}"#) as FileContent?)?.backup == true
          && (decode(#"{"ok":false,"path":"/usr/bin/true","error":"arquivo binário"}"#) as FileContent?)?.content == nil
          && (decode(#"{"ok":false,"auth":false,"path":"/etc/shadow","error":"sem permissão de leitura"}"#) as FileContent?)?.auth == false)
    check("units: file path is optional", units[0].file == nil
          && (decode(#"{"scope":"user","name":"a.service","description":"","active":"active","sub":"running","enabled":"enabled","custom":true,"file":"/home/a/.config/systemd/user/a.service"}"#) as UnitInfo?)?.file != nil)

    // Updates.
    check("versions: numeric comparison, not text", isNewer("5.10.0", than: "5.9.3") && isNewer("v5.1", than: "5.0.9")
          && isNewer("6", than: "5.99.99") && !isNewer("5.0", than: "5.0.0") && !isNewer("5.0.0", than: "5.0")
          && !isNewer("4.9.9", than: "5.0") && isNewer("5.0.1", than: "5.0"))
    check("versions: junk never counts as newer", !isNewer("", than: "5.0") && !isNewer("latest", than: "5.0")
          && isNewer("5.1.0-beta", than: "5.0.0") && versionNumbers("v5.2.1+build7") == [5, 2, 1] && versionNumbers("x") == [])
    let release: ReleaseInfo? = decode(#"{"tag_name":"v5.1.0","name":"Home Lab 5.1.0","body":"notas","html_url":"https://github.com/o/r/releases/tag/v5.1.0","draft":false,"prerelease":false,"assets":[{"name":"Home-Lab-5.1.0.dmg","browser_download_url":"https://e/x.dmg","size":9},{"name":"Home-Lab-5.1.0.app.zip","browser_download_url":"https://e/x.zip","digest":"sha256:abc","size":8},{"name":"homelab-host_1.3_all.deb","browser_download_url":"https://e/x.deb"}]}"#)
    check("release: the updater takes the zipped app, not the DMG or the .deb", release?.appArchive?.name == "Home-Lab-5.1.0.app.zip"
          && release?.appArchive?.digest == "sha256:abc" && release?.version == "5.1.0")
    check("release: offered only when newer", updateOffer(release, running: "5.0.0")?.version == "5.1.0"
          && updateOffer(release, running: "5.1.0") == nil && updateOffer(release, running: "5.2") == nil && updateOffer(nil, running: "1") == nil)
    var draft = release
    draft?.draft = true
    var beta = release
    beta?.prerelease = true
    var appless = release
    appless?.assets.removeAll { $0.name.hasSuffix(".zip") }
    check("release: drafts, pre-releases and releases without the app are not offered", updateOffer(draft, running: "5.0") == nil
          && updateOffer(beta, running: "5.0") == nil && updateOffer(appless, running: "5.0") == nil)
    check("release: a repository with no release yet decodes as nothing", (decode(#"{"message":"Not Found"}"#) as ReleaseInfo?) == nil)

    // System controls.
    let sys: SystemInfo? = decode(#"{"rebootRequired":false,"updates":12,"securityUpdates":6,"powerProfile":"balanced","powerProfiles":["performance","balanced","power-saver"],"cacheMB":11609.1,"failedUser":0,"failedSystem":1,"sessions":3}"#)
    check("system: updates wording", sys?.updatesText == "12 pendentes · 6 de segurança" && sys?.failedUnits == 1
          && (decode(#"{"rebootRequired":true,"updates":1,"securityUpdates":0}"#) as SystemInfo?)?.updatesText == "1 pendente"
          && (decode(#"{"rebootRequired":false,"updates":0}"#) as SystemInfo?)?.updatesText == "em dia")
    check("system: a host without apt-check or power profiles still decodes", (decode(#"{"rebootRequired":false}"#) as SystemInfo?)?.updatesText == "desconhecido"
          && (decode(#"{"rebootRequired":false}"#) as SystemInfo?)?.powerProfiles == nil && (decode(#"{"rebootRequired":false}"#) as SystemInfo?)?.failedUnits == 0)
    check("system: power profile names", powerProfileTitle("performance") == "Desempenho" && powerProfileTitle("power-saver") == "Economia"
          && powerProfileTitle("custom") == "custom")

    // Setup wizard.
    let ready: DetectInfo? = decode(#"{"user":"ana","hostname":"box","osName":"Ubuntu 26.04","desktop":"GNOME Shell 50.1","graphicalSession":true,"hasGrd":true,"hasOpenssl":true,"hasApt":true,"hasGi":true,"lanIP":"192.168.1.9","tailscaleName":"box.tail.ts.net","sudoNeedsPassword":false,"rdp":{"enabled":true,"port":3390,"fingerprint":"aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44","hasCredentials":true},"loginRdp":{"enabled":true,"port":3389,"fingerprint":"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0","hasCredentials":true},"smbShares":["home"]}"#)
    check("detect: a prepared host needs nothing", ready?.supported == true && ready?.needsPackages == false
          && ready?.needsSetup == false && ready?.missing.isEmpty == true)
    let bare: DetectInfo? = decode(#"{"user":"u","hostname":"new","desktop":"GNOME Shell 49","hasGrd":false,"hasOpenssl":true,"hasGi":true,"lanIP":"10.0.0.5","sudoNeedsPassword":true}"#)
    check("detect: a fresh host needs the package and the setup", bare?.needsPackages == true && bare?.needsSetup == true
          && bare?.missing == ["pacote gnome-remote-desktop"])
    let noGnome: DetectInfo? = decode(#"{"user":"u","hostname":"srv","desktop":""}"#)
    check("detect: a host without GNOME is not supported", noGnome?.supported == false && noGnome?.missing.count == 4)
    let built = ready.flatMap { makeEnvironment(name: "Estúdio", sshTarget: "ana@box", detect: $0, rdp: $0.rdp!, taken: ["estudio"]) }
    check("wizard: environment prefers the tailnet name and keeps both doors", built?.rdpHost == "box.tail.ts.net"
          && built?.id == "estudio-2" && built?.sessionPort == 3390 && built?.loginPort == 3389
          && built?.smbURL == "smb://192.168.1.9/home" && built?.tailscaleName == "box" && built?.sshTargets == ["ana@box"])
    let lanOnly = bare.flatMap { makeEnvironment(name: "Novo", sshTarget: "u@10.0.0.5", detect: $0,
                                                 rdp: RDPStatus(enabled: true, port: 3390, fingerprint: pin, hasCredentials: true), taken: []) }
    check("wizard: without tailnet it falls back to the LAN address and no remote login", lanOnly?.rdpHost == "10.0.0.5"
          && lanOnly?.loginPort == nil && lanOnly?.targets == [.session] && lanOnly?.smbURL == nil)
    check("wizard: no fingerprint, no environment", bare.flatMap { makeEnvironment(name: "x", sshTarget: "u@h", detect: $0,
              rdp: RDPStatus(enabled: true, port: 3390, fingerprint: nil, hasCredentials: true), taken: []) } == nil
          && bare.flatMap { makeEnvironment(name: "x", sshTarget: "u@h", detect: $0,
              rdp: RDPStatus(enabled: true, port: 3390, fingerprint: "zz", hasCredentials: true), taken: []) } == nil)
    let failedSetup: SetupResult? = decode(#"{"ok":false,"steps":[{"name":"certificate","ok":true,"detail":"kept"},{"name":"credentials","ok":false,"detail":"missing"}]}"#)
    check("setup: reports the step that failed", failedSetup?.steps?.first { !$0.ok }?.name == "credentials")
    check("setup: a crash in the host script still decodes", (decode(#"{"ok":false,"error":"KeyError: x"}"#) as SetupResult?)?.error != nil)

    let direct = parseTailscalePing("pong from lab (100.64.0.7) via 192.0.2.10:41641 in 2ms")
    check("tailscale ping: direct path", direct == TailscaleLink(direct: true, via: "192.0.2.10:41641", milliseconds: 2))
    let relay = parseTailscalePing("pong from lab (100.64.0.7) via DERP(gru) in 48ms")
    check("tailscale ping: relayed path", relay?.direct == false && relay?.milliseconds == 48)
    check("tailscale ping: timeout or junk", parseTailscalePing("ping \"x\" timed out") == nil && parseTailscalePing("") == nil)
    check("rate formatting", formatRate(0) == "0 KB/s" && formatRate(512) == "512 KB/s" && formatRate(2048) == "2.0 MB/s"
          && formatRate(-3) == "0 KB/s")
    check("uptime formatting", formatUptime(59) == "0min" && formatUptime(3700) == "1h 1min" && formatUptime(200000) == "2d 7h")

    print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
    return failures == 0 ? 0 : 1
}
