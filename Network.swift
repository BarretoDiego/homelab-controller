import AppKit
import SwiftUI

// Network section: what the host listens on and how it is reached from outside:
// ports and firewall, Tailscale (serve, funnel), Cloudflare (tunnels).

@MainActor
final class NetworkCenter: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case ports, tailscale, cloudflare
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ports: return "Portas"
            case .tailscale: return "Tailscale"
            case .cloudflare: return "Cloudflare"
            }
        }
        var icon: String {
            switch self {
            case .ports: return "door.left.hand.open"
            case .tailscale: return "point.3.filled.connected.trianglepath.dotted"
            case .cloudflare: return "cloud.fill"
            }
        }
    }

    @Published var tab: Tab = .ports
    @Published var ports: [PortInfo] = []
    @Published var firewall: FirewallInfo?
    @Published var scope: PortScope = .all
    @Published var showUDP = false
    @Published var search = ""
    @Published var tailscale: TailscaleInfo?
    @Published var cloudflare: CloudflareInfo?
    @Published var loading = false
    @Published var loaded: Set<Tab> = []
    @Published var message: (text: String, isError: Bool)?

    var visiblePorts: [PortInfo] { filterPorts(ports, scope: scope, search: search, udp: showUDP) }

    func refresh(_ model: Model) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        switch tab {
        case .ports:
            if let list: PortList = await model.host("ports", timeout: 30) { ports = list.ports; firewall = list.firewall }
        case .tailscale:
            if let info: TailscaleInfo = await model.host("tailscale", timeout: 25) { tailscale = info }
        case .cloudflare:
            if let info: CloudflareInfo = await model.host("cloudflare", timeout: 40) { cloudflare = info }
        }
        loaded.insert(tab)
#if SNAPSHOT
        // Development renders: open on the requested tab.
        if let wanted = ProcessInfo.processInfo.environment["HOMELAB_SNAP_NET"].flatMap(Tab.init(rawValue:)), tab != wanted {
            tab = wanted; loading = false; await refresh(model)
        }
#endif
    }

    func reset() {
        ports = []; firewall = nil; tailscale = nil; cloudflare = nil; loaded = []; message = nil
    }

    /// Runs one host action, reports it, opens the address it answers with (logins), and reloads the tab.
    @discardableResult
    func act(_ label: String, command: String, _ parameters: [String: Any], timeout: TimeInterval = 60, _ model: Model) async -> ActionResult? {
        let result: ActionResult? = await model.privileged(label, command: command, parameters: parameters, timeout: timeout) { $0.auth }
        if let result {
            let detail = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = result.ok ? ("\(label): feito.", false) : ("\(label) falhou" + (detail.isEmpty ? "." : ": " + detail), true)
            if result.ok, let url = result.url.flatMap(URL.init(string:)), command != "cloudflare-action" || parameters["action"] as? String == "login" {
                NSWorkspace.shared.open(url)
            }
        }
        await refresh(model)
        return result
    }
}

/// Segmented control in the app's own style.
struct PillTabs<Item: Identifiable & Equatable>: View {
    var items: [Item]
    @Binding var selection: Item
    var title: (Item) -> String
    var icon: (Item) -> String
    var accent: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let selected = item == selection
                Button { selection = item } label: {
                    Label(title(item), systemImage: icon(item))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(selected ? 0.2 : 0.0001)))
                        .foregroundStyle(selected ? accent : Color.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.25)))
    }
}

struct NetworkSection: View {
    @ObservedObject var model: Model
    @ObservedObject var center: NetworkCenter
    var theme: Theme
    @State private var servePort = "8443"
    @State private var serveTarget = ""
    @State private var serveFunnel = false
    @State private var quickPort = ""
    @State private var tunnelName = ""
    @State private var routeTunnel = ""
    @State private var routeHost = ""
    @State private var serviceToken = ""
    private let ticker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var busy: Bool { model.busyAction != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                SectionHeader(kicker: model.env.name, title: "Rede e acesso externo")
                Spacer()
                PillTabs(items: NetworkCenter.Tab.allCases, selection: $center.tab, title: \.title, icon: \.icon, accent: theme.accent)
            }
            HStack(spacing: 10) {
                if let message = center.message {
                    Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(message.isError ? Neon.amber : Neon.green)
                        .lineLimit(1).truncationMode(.tail).help(message.text)
                }
                if let action = model.busyAction {
                    ProgressView().controlSize(.small)
                    Text(action + "…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                Spacer()
                if center.loading { ProgressView().controlSize(.small) }
                Button { Task { await center.refresh(model) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle()).help("Atualizar agora")
            }
            .frame(height: 26)
            Group {
                switch center.tab {
                case .ports: portsTab
                case .tailscale: tailscaleTab
                case .cloudflare: cloudflareTab
                }
            }
            .disabled(busy && model.passwordRequest == nil)
        }
        .task(id: center.tab) { await center.refresh(model) }
        .onReceive(ticker) { _ in Task { if !busy { await center.refresh(model) } } }
        .onChange(of: model.environmentID) { _ in
            center.reset()
            Task { await center.refresh(model) }
        }
    }

    private func loadingText(_ tab: NetworkCenter.Tab) -> some View {
        Text(center.loaded.contains(tab) ? "Nada encontrado." : (model.sshAlias == nil && model.checkedOnce ? "Sem SSH: o host precisa estar online." : "Carregando…"))
            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).padding(12)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(1.1).foregroundStyle(.white.opacity(0.5))
    }

    private func fact(_ title: String, _ value: String, tone: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.white.opacity(0.65)).frame(width: 92, alignment: .leading)
            Text(value).fontWeight(.medium).foregroundStyle(tone ?? Color.white).textSelection(.enabled)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    private func field(_ prompt: String, _ text: Binding<String>, width: CGFloat, secure: Bool = false) -> some View {
        Group {
            if secure { SecureField(prompt, text: text) } else { TextField(prompt, text: text).autocorrectionDisabled() }
        }
        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.32)))
        .frame(width: width)
    }

    // MARK: Ports

    private var portsTab: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                        TextField("Porta, serviço ou container", text: $center.search).textFieldStyle(.plain).font(.system(size: 13))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.black.opacity(0.25))).frame(width: 240)
                    Picker("Alcance", selection: $center.scope) {
                        ForEach(PortScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    Toggle("UDP", isOn: $center.showUDP).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        let rows = center.visiblePorts
                        if rows.isEmpty { loadingText(.ports).frame(maxWidth: .infinity, alignment: .leading) }
                        ForEach(rows) { port in portRow(port) }
                    }
                    .padding(.vertical, 4)
                }
                .pane(6)
            }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    caption("Túneis SSH abertos por este app")
                    if model.tunnels.isEmpty {
                        Text("Portas que só escutam no próprio host abrem aqui por um túnel SSH quando você clica em Abrir.")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.tunnels.keys.sorted(), id: \.self) { remote in
                        HStack {
                            Text(verbatim: "localhost:\(model.tunnels[remote] ?? 0) → host:\(remote)").font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button("Fechar") { model.closeTunnel(remote) }.buttonStyle(GlassButtonStyle())
                        }
                    }
                }
                .pane(14).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        caption("Firewall (ufw)")
                        Spacer()
                        let state = center.firewall?.state ?? "unknown"
                        Text(state == "active" ? "ativo" : (state == "inactive" ? "desligado" : "desconhecido"))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(state == "active" ? Neon.green : Neon.amber)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(center.firewall?.rules ?? [], id: \.self) { rule in
                                Text(rule).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if center.firewall?.rules.isEmpty != false {
                                Text("Sem regras listadas.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }
                    Text("Portas publicadas pelo Docker passam por fora do ufw.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
                .pane(14)
            }
            .frame(width: 330)
        }
    }

    private func portRow(_ port: PortInfo) -> some View {
        let tone: Color = port.exposure == "public" ? Neon.amber : (port.exposure == "tailnet" ? theme.accent : Color.white.opacity(0.55))
        return HStack(spacing: 10) {
            Text(verbatim: "\(port.port)").font(.system(size: 14, weight: .semibold, design: .monospaced)).frame(width: 56, alignment: .leading)
            Text(port.proto == "udp" ? "udp · " + exposureTitle(port.exposure) : exposureTitle(port.exposure))
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tone)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(tone.opacity(0.16)))
                .frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(port.owner).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text((port.container.isEmpty ? port.process : "container · " + port.process) + " · " + port.addresses.joined(separator: ", "))
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if port.ufwAllowed == true {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(Neon.green).help("Liberada no ufw")
            }
            if model.tunnels[port.port] != nil && port.exposure == "local" {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(theme.accent).help("Túnel SSH aberto")
            }
            if port.proto == "tcp" {
                Button(port.exposure == "local" && model.tunnels[port.port] == nil ? "Túnel" : "Abrir") { Task { await model.openPort(port) } }
                    .buttonStyle(GlassButtonStyle()).help(port.exposure == "local" ? "Abre um túnel SSH e mostra no navegador" : "Abre no navegador")
            }
            Menu {
                if let url = portURL(port, environment: model.env, tunnelPort: model.tunnels[port.port]) {
                    Button("Copiar endereço") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                if port.exposure != "local" {
                    if port.ufwAllowed == true {
                        Button("Remover a liberação no ufw") {
                            Task { await center.act("Fechar \(port.port) no ufw", command: "ufw-action", ["port": port.port, "proto": port.proto, "action": "remove"], model) }
                        }
                    } else {
                        Button("Liberar no ufw…") {
                            if confirmAlert("Liberar a porta \(port.port)/\(port.proto) no firewall?",
                                            "Qualquer máquina que alcance este host pela rede poderá conectar nela.", button: "Liberar") {
                                Task { await center.act("Liberar \(port.port) no ufw", command: "ufw-action", ["port": port.port, "proto": port.proto, "action": "allow"], model) }
                            }
                        }
                    }
                }
                if port.proto == "tcp" && center.tailscale?.installed != false {
                    Button("Publicar na tailnet (HTTPS)…") {
                        servePort = "8443"; serveTarget = String(port.port); serveFunnel = false
                        center.tab = .tailscale
                    }
                    Button("Túnel rápido do Cloudflare…") {
                        quickPort = String(port.port)
                        center.tab = .cloudflare
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    // MARK: Tailscale

    @ViewBuilder private var tailscaleTab: some View {
        if let ts = center.tailscale {
            if !ts.installed {
                installCard("Tailscale não está instalado neste host",
                            "O Tailscale dá ao host um endereço privado que funciona de qualquer lugar, sem abrir portas no roteador.",
                            button: "Instalar Tailscale") {
                    if confirmAlert("Instalar o Tailscale em \(model.env.name)?", "Roda o instalador oficial (tailscale.com/install.sh) com sudo.", button: "Instalar") {
                        Task { await center.act("Instalar Tailscale", command: "tailscale-action", ["action": "install"], timeout: 440, model) }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            caption("Estado")
                            fact("Ligação", ts.running ? "conectado" : (ts.state ?? "parado"), tone: ts.running ? Neon.green : Neon.amber)
                            fact("Nome", ts.name ?? "—")
                            fact("Endereços", (ts.ips ?? []).joined(separator: "  "))
                            fact("Tailnet", ts.tailnet ?? "—")
                            fact("Versão", ts.version ?? "—")
                            ForEach(ts.health ?? [], id: \.self) { line in
                                Label(line, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Neon.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack {
                                if ts.running {
                                    Button("Desconectar…") {
                                        if confirmAlert("Desconectar o host da tailnet?",
                                                        "O acesso pelo endereço do Tailscale cai na hora. Se este Mac chega ao host por ele, o app perde o host até alguém religar lá.",
                                                        button: "Desconectar") {
                                            Task { await center.act("Desconectar Tailscale", command: "tailscale-action", ["action": "down"], model) }
                                        }
                                    }
                                } else {
                                    Button("Conectar e autenticar") {
                                        Task { await center.act("Conectar Tailscale", command: "tailscale-action", ["action": "up"], model) }
                                    }
                                }
                            }
                            .buttonStyle(GlassButtonStyle()).padding(.top, 2)
                        }
                        .pane(14).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) {
                            caption("Publicar um serviço local")
                            HStack(spacing: 8) {
                                Text("https :").font(.system(size: 12))
                                field("8443", $servePort, width: 64)
                                Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.5))
                                field("porta local ou http://127.0.0.1:3000", $serveTarget, width: 230)
                            }
                            Toggle(isOn: $serveFunnel) {
                                Text("Funnel: público na internet (só nas portas 443, 8443 e 10000)").font(.system(size: 11.5))
                            }
                            .toggleStyle(.switch).controlSize(.small)
                            HStack {
                                Button("Publicar") { publishServe() }.buttonStyle(GlassButtonStyle()).disabled(!serveValid)
                                if !serveTarget.isEmpty && !validServeTarget(serveTarget) {
                                    Text("O destino precisa ser local.").font(.system(size: 11)).foregroundStyle(Neon.amber)
                                }
                            }
                        }
                        .pane(14).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 440)
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            caption("Publicado pelo Tailscale (\(ts.serve.count))")
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(ts.serve) { entry in serveRow(entry) }
                                    if ts.serve.isEmpty { Text("Nada publicado.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                            }
                        }
                        .pane(14)
                        VStack(alignment: .leading, spacing: 6) {
                            caption("Máquinas na tailnet (\(ts.peers.count))")
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(ts.peers) { peer in
                                        HStack(spacing: 8) {
                                            Circle().fill(peer.online ? Neon.green : Color.white.opacity(0.35)).frame(width: 7, height: 7)
                                            Text(peer.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(peer.os).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                                            Spacer()
                                            Text(peer.ip).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                        .pane(14).frame(height: 130)
                    }
                }
            }
        } else {
            loadingText(.tailscale).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var serveValid: Bool {
        guard let port = Int(servePort), (1...65535).contains(port), validServeTarget(serveTarget) else { return false }
        return !serveFunnel || funnelPorts.contains(port)
    }

    private func publishServe() {
        guard let port = Int(servePort) else { return }
        if serveFunnel && !confirmAlert("Publicar na internet pelo Funnel?",
                                        "Qualquer pessoa com o endereço chega ao serviço em \(serveTarget), sem login.", button: "Publicar") { return }
        let params: [String: Any] = ["action": "serve-add", "port": port, "target": serveTarget.trimmingCharacters(in: .whitespaces), "funnel": serveFunnel]
        Task {
            if await center.act(serveFunnel ? "Publicar no Funnel" : "Publicar na tailnet", command: "tailscale-action", params, model)?.ok == true {
                serveTarget = ""
            }
        }
    }

    private func serveRow(_ entry: ServeEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.funnel ? "público" : "tailnet").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(entry.funnel ? Neon.amber : theme.accent)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill((entry.funnel ? Neon.amber : theme.accent).opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.url).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("→ " + entry.target).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let url = URL(string: entry.url), entry.url.hasPrefix("https") {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }.buttonStyle(.plain).help("Abrir")
            }
            Button {
                if confirmAlert("Parar de publicar \(entry.url)?", "O serviço local continua rodando; só some este endereço.", button: "Parar") {
                    Task { await center.act("Remover publicação", command: "tailscale-action", ["action": "serve-remove", "port": entry.port, "funnel": entry.funnel], model) }
                }
            } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Parar de publicar")
        }
        .padding(.vertical, 3)
    }

    private func installCard(_ title: String, _ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            Button(button, action: action).buttonStyle(NeonButtonStyle())
        }
        .pane(20).fixedSize(horizontal: false, vertical: true).frame(width: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Cloudflare

    @ViewBuilder private var cloudflareTab: some View {
        if let cf = center.cloudflare {
            if !cf.installed {
                installCard("cloudflared não está instalado neste host",
                            "Os túneis do Cloudflare publicam um serviço local num domínio seu, sem abrir portas no roteador.",
                            button: "Instalar cloudflared") {
                    if confirmAlert("Instalar o cloudflared em \(model.env.name)?", "Baixa o pacote oficial do GitHub da Cloudflare e instala com sudo.", button: "Instalar") {
                        Task { await center.act("Instalar cloudflared", command: "cloudflare-action", ["action": "install"], timeout: 400, model) }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            caption("Estado")
                            fact("Versão", cf.version ?? "—")
                            fact("Conta", cf.loggedIn == true ? "autenticada" : "sem login", tone: cf.loggedIn == true ? Neon.green : Neon.amber)
                            fact("Serviço", cf.serviceInstalled == true ? (cf.service == "active" ? "ativo" : (cf.service ?? "parado")) : "não instalado",
                                 tone: cf.service == "active" ? Neon.green : nil)
                            if let config = cf.config { fact("Config", config) }
                            if let error = cf.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Neon.amber) }
                            HStack {
                                if cf.loggedIn != true {
                                    Button("Entrar na Cloudflare") {
                                        Task { await center.act("Login na Cloudflare", command: "cloudflare-action", ["action": "login"], model) }
                                    }
                                }
                                if let config = cf.config {
                                    Button("Editar config") { model.editor = Model.EditorRequest(path: config, title: "Configuração do cloudflared", reload: nil) }
                                }
                                if cf.serviceInstalled == true {
                                    Button("Reiniciar serviço") {
                                        Task { await center.act("Reiniciar cloudflared", command: "service-action", ["scope": "system", "unit": "cloudflared.service", "action": "restart"], model) }
                                    }
                                    Button("Remover serviço…") {
                                        if confirmAlert("Remover o serviço do cloudflared?", "Os túneis que ele mantém saem do ar.", button: "Remover") {
                                            Task { await center.act("Remover serviço", command: "cloudflare-action", ["action": "service-uninstall"], model) }
                                        }
                                    }
                                }
                            }
                            .buttonStyle(GlassButtonStyle()).padding(.top, 2)
                        }
                        .pane(14).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) {
                            caption("Túnel rápido (endereço temporário trycloudflare.com)")
                            HStack(spacing: 8) {
                                Text("porta local").font(.system(size: 12))
                                field("3000", $quickPort, width: 80)
                                Button("Publicar") {
                                    guard let port = Int(quickPort), (1...65535).contains(port) else { return }
                                    if confirmAlert("Publicar a porta \(port) na internet?",
                                                    "O Cloudflare cria um endereço público temporário. Qualquer pessoa com ele chega ao serviço.", button: "Publicar") {
                                        Task { await center.act("Túnel rápido da porta \(port)", command: "cloudflare-action", ["action": "quick-start", "port": port], timeout: 60, model) }
                                    }
                                }
                                .buttonStyle(GlassButtonStyle()).disabled(Int(quickPort).map { !(1...65535).contains($0) } ?? true)
                            }
                            ForEach(cf.quick) { quick in
                                HStack(spacing: 8) {
                                    Text(verbatim: ":\(quick.port)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Text(quick.url.isEmpty ? "aguardando endereço…" : quick.url).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Spacer(minLength: 4)
                                    if let url = URL(string: quick.url), !quick.url.isEmpty {
                                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }.buttonStyle(.plain).help("Abrir")
                                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(quick.url, forType: .string) } label: {
                                            Image(systemName: "doc.on.doc")
                                        }
                                        .buttonStyle(.plain).help("Copiar")
                                    }
                                    Button { Task { await center.act("Parar túnel rápido", command: "cloudflare-action", ["action": "quick-stop", "port": quick.port], model) } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Parar")
                                }
                            }
                        }
                        .pane(14).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) {
                            caption("Serviço gerenciado pelo painel da Cloudflare")
                            HStack(spacing: 8) {
                                field("token do túnel (Zero Trust › Tunnels)", $serviceToken, width: 290, secure: true)
                                Button("Instalar serviço") {
                                    let token = serviceToken
                                    serviceToken = ""
                                    Task { await center.act("Instalar serviço do cloudflared", command: "cloudflare-action", ["action": "service-install", "token": token], timeout: 100, model) }
                                }
                                .buttonStyle(GlassButtonStyle()).disabled(serviceToken.count < 20)
                            }
                            Text("O cloudflared grava o token no arquivo da unidade systemd do host.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                        }
                        .pane(14).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 470)
                    VStack(alignment: .leading, spacing: 8) {
                        caption("Túneis da conta (\(cf.tunnels.count))")
                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(cf.tunnels) { tunnel in
                                    HStack(spacing: 8) {
                                        Circle().fill(tunnel.connections > 0 ? Neon.green : Color.white.opacity(0.35)).frame(width: 7, height: 7)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(tunnel.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                            Text(tunnel.connections > 0 ? "\(tunnel.connections) conexões · criado em \(tunnel.created)" : "sem conexões · criado em \(tunnel.created)")
                                                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                                        }
                                        Spacer()
                                        Button("DNS") { routeTunnel = tunnel.name }.buttonStyle(GlassButtonStyle()).help("Apontar um domínio para este túnel")
                                        Button {
                                            if confirmAlert("Excluir o túnel \(tunnel.name)?", "Os domínios apontados para ele param de responder. Não dá para desfazer.", button: "Excluir") {
                                                Task { await center.act("Excluir túnel \(tunnel.name)", command: "cloudflare-action", ["action": "tunnel-delete", "name": tunnel.name], model) }
                                            }
                                        } label: { Image(systemName: "trash") }
                                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Excluir túnel")
                                    }
                                }
                                if cf.tunnels.isEmpty {
                                    Text(cf.loggedIn == true ? "Nenhum túnel nesta conta." : "Entre na Cloudflare para listar os túneis.")
                                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if cf.loggedIn == true {
                            Divider().overlay(Color.white.opacity(0.15))
                            HStack(spacing: 8) {
                                field("nome do novo túnel", $tunnelName, width: 190)
                                Button("Criar túnel") {
                                    let name = tunnelName
                                    tunnelName = ""
                                    Task { await center.act("Criar túnel \(name)", command: "cloudflare-action", ["action": "tunnel-create", "name": name], model) }
                                }
                                .buttonStyle(GlassButtonStyle()).disabled(tunnelName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            HStack(spacing: 8) {
                                field("túnel", $routeTunnel, width: 120)
                                field("app.seudominio.com", $routeHost, width: 190)
                                Button("Apontar DNS") {
                                    let name = routeTunnel, host = routeHost
                                    Task {
                                        if await center.act("Apontar \(host)", command: "cloudflare-action", ["action": "route-dns", "name": name, "hostname": host], model)?.ok == true {
                                            routeHost = ""
                                        }
                                    }
                                }
                                .buttonStyle(GlassButtonStyle()).disabled(routeTunnel.isEmpty || !validHostname(routeHost))
                            }
                            Text("Para o túnel servir algo, a regra de entrada (ingress) fica no config do cloudflared.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .pane(14)
                }
            }
        } else {
            loadingText(.cloudflare).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension NetworkCenter.Tab: Equatable {}
