import AppKit
import Darwin
import SwiftUI

// MARK: - Building blocks

/// Green while comfortable, orange when getting tight, red when it needs attention.
func loadColor(_ percent: Double, calm: Color) -> Color {
    percent >= 90 ? .red : (percent >= 75 ? .orange : calm)
}

/// The panel's cards are the same glass the main window uses.
struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(Card()) }
}

struct Sparkline: View {
    var values: [Double]
    var ceiling: Double?
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let top = max(ceiling ?? (values.max() ?? 1) * 1.15, 0.0001)
            let samples = values.count > 1 ? values : [values.first ?? 0, values.first ?? 0]
            let step = geo.size.width / CGFloat(samples.count - 1)
            let points = samples.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step,
                        y: geo.size.height - CGFloat(min(max(value / top, 0), 1)) * (geo.size.height - 2) - 1)
            }
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: points[0])
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

struct MeterBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct MetricTile<Chart: View>: View {
    var title: String
    var icon: String
    var value: String
    var valueColor: Color = .primary
    var side: String = ""
    var footnote: String
    @ViewBuilder var chart: Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(side).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(valueColor).lineLimit(1).minimumScaleFactor(0.7)
            chart.frame(height: 24)
            Text(footnote).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct Chip: View {
    var text: String
    var state: Bool?
    var color: Color?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color ?? (state == nil ? Color.secondary.opacity(0.5) : (state == true ? Color.green : Color.red)))
                .frame(width: 7, height: 7)
            Text(text).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == nil ? "" : (state == true ? "ok" : "indisponível"))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (points, y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 380
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = arrange(width: bounds.width, subviews: subviews).points
        for (subview, point) in zip(subviews, points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
}

struct SectionTitle: View {
    var title: String
    var summary: String = ""
    var expanded: Binding<Bool>?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6)
            Spacer()
            Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if let expanded {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let expanded { withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() } } }
        .accessibilityAddTraits(expanded == nil ? [] : .isButton)
    }
}

// MARK: - Panel

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Lets a view reach the window it lives in.
final class WindowBox {
    weak var window: NSWindow?
}

struct WindowReader: NSViewRepresentable {
    var box: WindowBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { box.window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { box.window = nsView.window }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The menu bar panel, detached: a floating window that stays open and can be moved around.
@MainActor
final class PinnedPanelController {
    static let shared = PinnedPanelController()
    private var panel: NSPanel?

    func pin(model: Model, from popover: NSWindow?) {
        guard panel == nil else { return bringForward() }
        let screen = popover?.screen ?? NSScreen.main
        let start = popover?.frame ?? NSRect(x: (screen?.visibleFrame.maxX ?? 1400) - 450, y: (screen?.visibleFrame.maxY ?? 900) - 640, width: 430, height: 620)
        let created = FloatingPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .floating
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.contentView = NSHostingView(rootView: PanelView(model: model, pinned: true)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)))
        panel = created
        model.pinned = true
        created.orderFrontRegardless()
        popover?.close()
    }

    func unpin(model: Model) {
        model.pinned = false
        panel?.close()
        panel = nil
    }

    func bringForward() { panel?.orderFrontRegardless() }

    /// Follows the content's height, keeping the top edge where the user put it.
    func fit(height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    /// True for the detached copy that stays open.
    var pinned = false
    @ObservedObject private var updater = Updater.shared
    @AppStorage("showServices") private var showServices = true
    @AppStorage("showProcesses") private var showProcesses = false
    @AppStorage("showAuth") private var showAuth = true
    @AppStorage("showFiles") private var showFiles = false
    @State private var customCommand = ""
    private let presets = ["1280x720", "1600x900", "1920x1080", "2560x1080", "2560x1440", "3440x1440"]

    private var metrics: HostMetrics? { model.status?.metrics }
    /// The panel wears the overview's colours, so it reads as a pocket version of the main window.
    private let theme = MainSection.dashboard.theme

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [theme.top, theme.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(gradient: glowGradient(theme.glow, peak: 0.9), center: .init(x: 0.8, y: 0.12), startRadius: 0, endRadius: 420)
        }
    }

    @State private var contentHeight: CGFloat = 600
    @State private var host = WindowBox()

    var body: some View {
        // Scrolls only when the panel would not fit below the menu bar.
        ScrollView(.vertical, showsIndicators: false) {
            content.background(GeometryReader { geo in
                Color.clear.preference(key: HeightKey.self, value: geo.size.height)
            })
        }
        .onPreferenceChange(HeightKey.self) { height in
            contentHeight = height
            if pinned { PinnedPanelController.shared.fit(height: min(height, (NSScreen.main?.visibleFrame.height ?? 900) - 24)) }
        }
        .frame(width: 430, height: min(contentHeight, (NSScreen.main?.visibleFrame.height ?? 900) - 24))
        .background(WindowReader(box: host))
        .background(backdrop)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .tint(theme.accent)
        .onAppear {
            model.viewers += 1
            // The pinned copy is already on screen: the menu bar click just brings it forward.
            if !pinned && model.pinned {
                PinnedPanelController.shared.bringForward()
                DispatchQueue.main.async { host.window?.close() }
            }
        }
        .onDisappear { model.viewers -= 1 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.checkedOnce && !model.online {
                offline
            } else {
                if metrics != nil {
                    tiles
                    network
                }
                quick
                access
                if model.status != nil {
                    authCard
                    filesCard
                }
                if let services = metrics?.services, !services.isEmpty { servicesCard(services) }
                if let top = metrics?.top, !top.isEmpty { processesCard(top) }
            }
            if let request = model.passwordRequest {
                PasswordForm(request: request)
            }
            if let target = model.credentialRequest {
                CredentialForm(target: target,
                               onSave: { credential in Task { await model.saveCredential(credential, for: target) } },
                               onCancel: { model.credentialRequest = nil })
            } else {
                connectCard
            }
            if let notice = model.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(notice.isError ? Neon.amber : Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.3)))
            }
            footer
        }
        .padding(14)
        .frame(width: 430)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { MainWindowController.shared.show(model: model) } label: {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            }
            .buttonStyle(.plain).help("Abrir a janela do Home Lab")
            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    ForEach(model.environments) { environment in
                        Button { model.select(environment.id) } label: {
                            Label(environment.name, systemImage: environment.id == model.environmentID ? "checkmark" : "server.rack")
                        }
                    }
                    Divider()
                    Button("Adicionar ambiente…") { openWizard() }
                    Button("Remover \(model.env.name)…") { confirmRemoveEnvironment() }
                        .disabled(model.environments.isEmpty || model.phase != .idle)
                } label: {
                    // The same environment pill as the main window's top bar.
                    HStack(spacing: 8) {
                        ZStack {
                            if model.checkedOnce { SoftGlow(color: model.online ? Neon.green : Neon.red, width: 22, height: 22, peak: 0.55) }
                            Circle().fill(!model.checkedOnce ? Color.gray : (model.online ? Neon.green : Neon.red)).frame(width: 8, height: 8)
                        }
                        .frame(width: 14)
                        Text(model.env.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(!model.checkedOnce ? "verificando…" : (model.clientRunning ? "conectado" : (model.online ? "online" : "offline")))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .liquidGlass(Capsule(), interactive: true)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Trocar de ambiente")
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).padding(.leading, 4)
            }
            Spacer(minLength: 6)
            if pinned { Grip() }
            Button {
                if pinned { PinnedPanelController.shared.unpin(model: model) }
                else { PinnedPanelController.shared.pin(model: model, from: host.window) }
            } label: { Image(systemName: pinned ? "pin.fill" : "pin").rotationEffect(.degrees(pinned ? 0 : 45)) }
            .buttonStyle(.borderless).foregroundStyle(pinned ? theme.accent : Color.white.opacity(0.8))
            .help(pinned ? "Soltar: o painel volta a fechar sozinho" : "Fixar: o painel fica aberto e pode ser movido")
            .accessibilityLabel(pinned ? "Soltar painel" : "Fixar painel")
            if model.refreshing {
                ProgressView().controlSize(.small).frame(width: 22)
            } else {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Atualizar agora").frame(width: 22)
            }
        }
        // Empty stretches of the header also move the pinned panel.
        .background { if pinned { WindowDragArea() } }
    }

    private var subtitle: String {
        guard model.checkedOnce else { return "Verificando…" }
        guard let status = model.status else { return model.online ? "Sem SSH: só o estado das portas" : "Sem resposta" }
        var parts = [status.hostname, "ligado há " + formatUptime(status.uptimeSeconds)]
        if let os = status.metrics?.osName { parts.insert(os, at: 1) }
        return parts.joined(separator: " · ")
    }

    private var offline: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.environments.isEmpty {
                Label("Nenhum ambiente configurado", systemImage: "plus.circle").font(.callout.weight(.medium))
                Text("Adicione a primeira máquina: o assistente testa o SSH, prepara o compartilhamento de tela e fixa o certificado.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Adicionar ambiente…") { openWizard() }.buttonStyle(GlassButtonStyle())
            } else {
                Label("Home Lab fora de alcance", systemImage: "wifi.slash").font(.callout.weight(.medium))
                Text("Nem SSH nem as portas RDP responderam. Confira se o Tailscale está ligado neste Mac e se o host está ligado.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    // MARK: Metrics

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
            cpuTile
            memoryTile
            gpuTile
            diskTile
        }
    }

    private var cpuTile: some View {
        let percent = metrics?.cpuPercent ?? 0
        var notes: [String] = []
        if let temp = metrics?.cpuTemp { notes.append(String(format: "%.0f °C", temp)) }
        if let loads = metrics?.loads, loads.count == 3 {
            notes.append("carga " + loads.map { String(format: "%.2f", $0) }.joined(separator: " "))
        }
        return MetricTile(title: "CPU", icon: "cpu", value: String(format: "%.0f%%", percent),
                          valueColor: loadColor(percent, calm: .primary),
                          side: metrics?.cpuCores.map { "\($0) threads" } ?? "",
                          footnote: notes.joined(separator: " · ")) {
            Sparkline(values: model.history.cpu, ceiling: 100, color: loadColor(percent, calm: theme.accent))
        }
        .help(metrics?.cpuModel ?? "")
    }

    private var memoryTile: some View {
        let used = metrics?.memUsedMB ?? 0, total = metrics?.memTotalMB ?? 0
        let percent = total > 0 ? used / total * 100 : 0
        var note = ""
        if let swapTotal = metrics?.swapTotalMB, swapTotal > 0, let swapUsed = metrics?.swapUsedMB {
            note = "swap \(formatGB(swapUsed)) / \(formatGB(swapTotal)) GB"
        }
        return MetricTile(title: "Memória", icon: "memorychip", value: "\(formatGB(used)) GB",
                          valueColor: loadColor(percent, calm: .primary),
                          side: "de \(formatGB(total)) GB", footnote: note) {
            Sparkline(values: model.history.memory, ceiling: 100, color: loadColor(percent, calm: theme.accent))
        }
    }

    @ViewBuilder private var gpuTile: some View {
        if let gpu = metrics?.gpu {
            let vram = gpu.memTotalMB > 0 ? gpu.memUsedMB / gpu.memTotalMB * 100 : 0
            let notes = ["VRAM \(formatGB(gpu.memUsedMB)) / \(formatGB(gpu.memTotalMB)) GB",
                         gpu.temp.map { String(format: "%.0f °C", $0) },
                         gpu.power.map { String(format: "%.0f W", $0) }].compactMap { $0 }
            MetricTile(title: "GPU", icon: "cube.transparent", value: String(format: "%.0f%%", gpu.util),
                       valueColor: loadColor(max(gpu.util, vram), calm: .primary), side: gpu.name,
                       footnote: notes.joined(separator: " · ")) {
                VStack(spacing: 3) {
                    Sparkline(values: model.history.gpu, ceiling: 100, color: loadColor(gpu.util, calm: theme.accent))
                    MeterBar(fraction: vram / 100, color: loadColor(vram, calm: theme.accent))
                }
            }
        } else {
            MetricTile(title: "GPU", icon: "cube.transparent", value: "—", footnote: "nvidia-smi indisponível") { Color.clear }
        }
    }

    /// One disk at a time; the arrows, the menu or a click on the tile switch between the host's disks.
    @ViewBuilder private var diskTile: some View {
        let disks = model.disks
        if let disk = model.selectedDisk {
            let color = loadColor(disk.percent, calm: theme.accent)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Label("Disco", systemImage: "internaldrive").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if disks.count > 1 {
                        Button { model.cycleDisk(-1) } label: { Image(systemName: "chevron.left") }.help("Disco anterior")
                        Menu {
                            ForEach(disks) { item in
                                Button { model.diskMount = item.mount } label: {
                                    Label(String(format: "%@ · %.0f%%", item.mount, item.percent),
                                          systemImage: item.mount == disk.mount ? "checkmark" : "internaldrive")
                                }
                            }
                        } label: {
                            Text("\((disks.firstIndex { $0.mount == disk.mount } ?? 0) + 1)/\(disks.count)").monospacedDigit()
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Escolher disco")
                        Button { model.cycleDisk(1) } label: { Image(systemName: "chevron.right") }.help("Próximo disco")
                    }
                }
                .buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", disk.percent))
                    .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(loadColor(disk.percent, calm: .primary))
                VStack(spacing: 5) {
                    MeterBar(fraction: disk.percent / 100, color: color)
                    HStack {
                        Text(disk.mount).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f GB livres", disk.totalGB - disk.usedGB))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(height: 24)
                Text(String(format: "%.0f de %.0f GB usados", disk.usedGB, disk.totalGB))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .card()
            .contentShape(Rectangle())
            .onTapGesture { model.cycleDisk() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Disco \(disk.mount), \(Int(disk.percent)) por cento usado")
        } else {
            MetricTile(title: "Disco", icon: "internaldrive", value: "—", footnote: "") { Color.clear }
        }
    }

    /// The overview's shortcuts, in the same glass spheres.
    private var quick: some View {
        let locked = model.status?.lockedKeyrings.count ?? 0
        let busy = model.busyAction != nil
        return HStack(alignment: .top, spacing: 0) {
            if model.clientRunning {
                QuickOrb(icon: "stop.fill", title: "Encerrar", detail: "sessão RDP", theme: theme) { Task { await model.disconnect() } }
            } else {
                QuickOrb(icon: "play.fill", title: "Conectar", detail: "últimas opções", theme: theme,
                         enabled: model.ports[model.effectiveTarget.rawValue] == true && model.phase == .idle) { Task { await model.connect() } }
            }
            QuickOrb(icon: "terminal.fill", title: "Terminal", detail: "SSH", theme: theme, enabled: model.sshAlias != nil) {
                if let url = model.sshAlias.flatMap({ URL(string: "ssh://" + $0) }) { NSWorkspace.shared.open(url) }
            }
            QuickOrb(icon: "key.fill", title: "Cofres", detail: locked > 0 ? "destrancar \(locked)" : "abertos", theme: theme,
                     enabled: locked > 0 && !busy) { Task { await model.unlockKeyrings() } }
            QuickOrb(icon: "memorychip.fill", title: "Cache", detail: "liberar", theme: theme, enabled: !busy && model.sshAlias != nil) {
                Task { await model.systemAction("drop-caches", label: "Liberar cache") }
            }
            QuickOrb(icon: "macwindow", title: "Janela", detail: "abrir o app", theme: theme) { MainWindowController.shared.show(model: model) }
        }
        .padding(.vertical, 2)
    }

    private var network: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Rede", systemImage: "network").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(formatRate(metrics?.rxKbps ?? 0), systemImage: "arrow.down")
                    Label(formatRate(metrics?.txKbps ?? 0), systemImage: "arrow.up")
                }
                .font(.system(.callout, design: .rounded).weight(.medium)).monospacedDigit()
                .labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
            }
            Sparkline(values: model.history.download, ceiling: nil, color: theme.accent).frame(height: 30)
            VStack(alignment: .trailing, spacing: 3) {
                if let link = model.link {
                    Text((link.direct ? "Tailscale direto · " : "Tailscale via relay · ") + "\(link.milliseconds) ms")
                        .help("Caminho: " + link.via)
                }
                if let lan = metrics?.lanIP { Text("LAN " + lan) }
                if let ts = metrics?.tailscaleIP { Text("TS " + ts) }
            }
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
            .lineLimit(1).fixedSize()
        }
        .card()
    }

    // MARK: Access

    private func portState(_ port: String) -> Bool? { model.checkedOnce ? model.ports[port] : nil }

    private var access: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Acesso remoto", summary: clientSummary)
            FlowLayout {
                Chip(text: "Sessão · \(model.env.sessionPort)", state: portState("session"))
                if let login = model.env.loginPort { Chip(text: "Login · \(login)", state: portState("login")) }
                Chip(text: model.sshAlias.map { "SSH · " + $0 } ?? "SSH", state: model.checkedOnce ? model.sshAlias != nil : nil)
                if model.env.lanHost != nil {
                    Chip(text: model.ports["smb"] == true ? "SMB · LAN" : "SMB · fora da LAN", state: portState("smb"))
                }
            }
            if let status = model.status {
                ForEach(monitorLines(status), id: \.self) { line in
                    Label(line, systemImage: "display").font(.caption).foregroundStyle(.secondary)
                }
                if status.locked == true {
                    Label("Tela do host bloqueada: o compartilhamento pode cair", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !status.remoteDesktopActive {
                    Label("Serviço GNOME Remote Desktop parado", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .card()
    }

    private var clientSummary: String {
        guard let clients = model.status?.rdpClients else { return "" }
        return clients == 0 ? "nenhum cliente RDP" : "\(clients) cliente(s) RDP"
    }

    private func monitorLines(_ status: HostStatus) -> [String] {
        var lines = status.physicalMonitors.map {
            "\($0.name) · \($0.width)×\($0.height) · \($0.connector)" + ($0.primary ? " · principal" : "")
        }
        if lines.isEmpty { lines.append("Nenhum monitor físico ligado no host") }
        let virtual = status.monitors.filter(\.virtual)
        if !virtual.isEmpty {
            lines.append((virtual.count == 1 ? "Tela virtual · " : "\(virtual.count) telas virtuais · ")
                         + virtual.map { "\($0.width)×\($0.height)" }.joined(separator: " + "))
        }
        return lines
    }

    // MARK: Services and processes

    private func servicesCard(_ services: [ServiceInfo]) -> some View {
        let running = services.filter { $0.active == "active" }.count
        let failed = services.filter { $0.active == "failed" }.count
        var summary = ["\(running) ativos"]
        if failed > 0 { summary.append("\(failed) com falha") }
        if let containers = metrics?.containers { summary.append("\(containers) containers") }
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Serviços", summary: summary.joined(separator: " · "), expanded: $showServices)
            if showServices {
                FlowLayout {
                    ForEach(services) { service in
                        Chip(text: service.name, state: nil,
                             color: service.active == "active" ? .green
                                 : service.active == "failed" ? .red
                                 : service.active == "activating" ? .yellow : Color.secondary.opacity(0.45))
                            .help("\(service.active) (\(service.sub))")
                    }
                }
                if let system = metrics?.failedSystem, system > 0 {
                    Label("\(system) unidade(s) do sistema com falha (systemctl --failed)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .card()
    }

    private func processesCard(_ top: [TopProcess]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Processos", summary: top.first.map { "\($0.name) \(String(format: "%.0f%%", $0.cpu))" } ?? "",
                         expanded: $showProcesses)
            if showProcesses {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(top) { process in
                        GridRow {
                            Text(process.name).lineLimit(1)
                            Text(String(format: "%.1f%% CPU", process.cpu)).gridColumnAlignment(.trailing)
                            Text(process.memMB >= 1024 ? String(format: "%.1f GB", process.memMB / 1024)
                                                       : String(format: "%.0f MB", process.memMB))
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("CPU média desde o início de cada processo.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    // MARK: Host authentication

    private var authCard: some View {
        let status = model.status
        let lockedRings = status?.lockedKeyrings ?? []
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Autenticação do host",
                         summary: status?.sudoNeedsPassword == false ? "sudo sem senha" : "sudo pede senha",
                         expanded: $showAuth)
            if showAuth {
                authRow(icon: status?.locked == true ? "lock.fill" : "lock.open",
                        title: "Tela", detail: status?.locked == true ? "bloqueada" : "desbloqueada",
                        warn: status?.locked == true) {
                    Button("Desbloquear") { Task { await model.unlockScreen() } }.disabled(status?.locked != true)
                }
                authRow(icon: "key", title: "Cofres",
                        detail: lockedRings.isEmpty ? "todos abertos" : lockedRings.map(\.label).joined(separator: ", ") + " trancado",
                        warn: !lockedRings.isEmpty) {
                    Button("Destrancar") { Task { await model.unlockKeyrings() } }.disabled(lockedRings.isEmpty)
                }
                authRow(icon: "person.badge.shield.checkmark", title: "Diálogos de admin",
                        detail: status?.polkitOpen == true ? "liberados sem senha" : "pedem senha na tela",
                        warn: false) {
                    if status?.polkitOpen == true {
                        Button("Voltar a pedir") { Task { await model.setPolkit(false) } }
                    } else {
                        Button("Liberar…") { confirmPolkit() }
                    }
                }
                HStack(spacing: 8) {
                    Menu {
                        ForEach(AdminAction.presets) { action in
                            Button(action.title) { runAdmin(action) }
                        }
                    } label: { Label("Ação de administrador", systemImage: "bolt.shield").font(.caption) }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                    Spacer()
                    if let busy = model.busyAction {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption)
                HStack(spacing: 6) {
                    TextField("sudo: comando personalizado", text: $customCommand)
                        .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                        .onSubmit { runCustomCommand() }
                    Button("Executar") { runCustomCommand() }
                        .disabled(customCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .font(.caption)
                if let output = model.actionOutput {
                    ZStack(alignment: .topTrailing) {
                        ScrollView {
                            Text(output).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                        .frame(maxHeight: 110)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                        Button { model.actionOutput = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).padding(4).help("Fechar saída")
                    }
                }
            }
        }
        .disabled(model.busyAction != nil && model.passwordRequest == nil)
        .card()
    }

    private func authRow<Trailing: View>(icon: String, title: String, detail: String, warn: Bool,
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(warn ? Color.orange : Color.secondary)
            Text(title).font(.caption.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(warn ? Color.orange : Color.secondary).lineLimit(1)
            Spacer(minLength: 6)
            trailing().controlSize(.small)
        }
    }

    private func runAdmin(_ action: AdminAction) {
        if let question = action.confirm, !confirm(action.title, question, button: "Executar") { return }
        Task { await model.runAdmin(action) }
    }

    private func runCustomCommand() {
        let command = customCommand
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard confirm("Executar como administrador?", "sudo sh -c '\(command)' em \(model.env.name).", button: "Executar") else { return }
        customCommand = ""
        Task { await model.runAdminShell(command) }
    }

    private func confirmPolkit() {
        guard confirm("Liberar diálogos de administrador em \(model.env.name)?",
                      "Instala uma regra polkit no host: pedidos de administrador feitos pelo seu usuário passam sem diálogo de senha. Qualquer programa rodando como você ganha esse poder. Dá para desfazer aqui mesmo.",
                      button: "Liberar") else { return }
        Task { await model.setPolkit(true) }
    }

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancelar")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRemoveEnvironment() {
        guard confirm("Remover o ambiente \(model.env.name)?",
                      "O app esquece este ambiente e apaga as credenciais dele do Keychain. Nada é alterado no host.",
                      button: "Remover") else { return }
        model.removeCurrentEnvironment()
    }

    private func openWizard() {
        MainWindowController.shared.show(model: model, section: .setup)
    }

    // MARK: Files

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Arquivos", summary: showFiles ? "" : model.fileRoot, expanded: $showFiles)
            if showFiles {
                HStack(spacing: 8) {
                    Button { model.fileRootUp() } label: { Image(systemName: "arrow.up") }
                        .disabled(model.fileRoot == "/" || model.fileRoot.isEmpty).help("Pasta acima")
                    Button { if let home = model.status?.home { model.setFileRoot(home) } } label: { Image(systemName: "house") }
                        .help("Pasta pessoal")
                    Button { model.setFileRoot("/") } label: { Image(systemName: "externaldrive") }.help("Raiz do sistema")
                    Text(model.fileRoot).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    if !model.loadingFolders.isEmpty { ProgressView().controlSize(.mini) }
                    Toggle(isOn: $model.showHidden) { Image(systemName: "eye") }
                        .toggleStyle(.button).help("Mostrar arquivos ocultos")
                    Button { model.reloadFiles() } label: { Image(systemName: "arrow.clockwise") }.help("Recarregar")
                }
                .buttonStyle(.borderless).controlSize(.small)
                fileTree
            }
        }
        .card()
        .onChange(of: showFiles) { open in
            if open && model.listings[model.fileRoot] == nil { model.setFileRoot(model.fileRoot) }
        }
        .onAppear { if showFiles && model.listings[model.fileRoot] == nil { model.setFileRoot(model.fileRoot) } }
    }

    private var fileTree: some View {
        let rows = model.visibleFileRows
        let root = model.listings[model.fileRoot]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = root?.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(6)
                } else if root != nil && rows.isEmpty {
                    Text("Pasta vazia").font(.caption).foregroundStyle(.secondary).padding(6)
                }
                ForEach(rows) { row in fileRow(row) }
                if root?.truncated == true {
                    Text("Lista cortada: pasta com muitos itens.").font(.caption2).foregroundStyle(.tertiary).padding(6)
                }
            }
        }
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.18)))
    }

    private func fileRow(_ row: FileRow) -> some View {
        let open = model.expandedFolders.contains(row.path)
        let failed = open ? model.listings[row.path]?.error : nil
        return HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0)).opacity(row.entry.dir ? 1 : 0).frame(width: 10)
            Image(systemName: row.entry.dir ? "folder.fill" : (row.entry.link ? "arrow.up.right.square" : "doc"))
                .font(.caption).foregroundStyle(row.entry.dir ? Color.accentColor : Color.secondary).frame(width: 16)
            Text(row.entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
            if let failed { Text(failed).font(.caption2).foregroundStyle(.orange).lineLimit(1) }
            Spacer(minLength: 6)
            if model.loadingFolders.contains(row.path) {
                ProgressView().controlSize(.mini)
            } else if !row.entry.dir {
                Text(formatBytes(row.entry.size)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 6).padding(.trailing, 8).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if row.entry.dir { model.toggleFolder(row.path) } }
        .contextMenu {
            Button("Copiar caminho") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.path, forType: .string)
            }
            if row.entry.dir {
                Button("Abrir como raiz") { model.setFileRoot(row.path) }
            } else {
                Button("Baixar para Downloads") { Task { await model.download(row) } }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.entry.dir ? .isButton : [])
    }

    // MARK: Connect

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Destino")
                    Picker("Destino", selection: Binding(get: { model.effectiveTarget }, set: { model.target = $0 })) {
                        ForEach(model.env.targets) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if model.effectiveTarget == .session {
                    GridRow {
                        Text("Tela")
                        Picker("Tela", selection: $model.mode) {
                            Text("Tela virtual").tag(ScreenMode.virtual)
                            if let monitor = model.mirrorSource {
                                Text(verbatim: "Espelhar \(monitor.name) · \(monitor.width)×\(monitor.height)").tag(ScreenMode.mirror)
                            } else if model.mode == .mirror {
                                Text("Espelhar monitor do host (indisponível)").tag(ScreenMode.mirror)
                            }
                        }
                        .labelsHidden()
                    }
                }
                GridRow {
                    Text("Abrir em")
                    Picker("Abrir em", selection: Binding(
                        get: { model.usesAllDisplays ? Model.allDisplays : (model.selectedDisplay?.name ?? "") },
                        set: { model.displayName = $0 })) {
                        ForEach(model.displays) { display in
                            Text(verbatim: "\(display.name) · \(display.size.width)×\(display.size.height)").tag(display.name)
                        }
                        if model.displays.count > 1 && model.effectiveMode == .virtual {
                            Divider()
                            Text(verbatim: "Todos os monitores · \(model.displays.count) telas").tag(Model.allDisplays)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Resolução")
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("Resolução", selection: $model.sizeTag) {
                            Text(fitLabel).tag("fit")
                            Text("Tela cheia").tag("full")
                            if model.effectiveMode == .virtual {
                                Divider()
                                ForEach(presets, id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                                Text("Outra…").tag("custom")
                            }
                        }
                        .labelsHidden()
                        .disabled(model.usesAllDisplays)
                        if model.sizeTag == "custom" && model.effectiveMode == .virtual && !model.usesAllDisplays {
                            TextField("1920x1080", text: $model.customSize)
                                .textFieldStyle(.roundedBorder).frame(width: 130)
                        }
                    }
                }
            }
            .font(.callout)
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Área de transferência", isOn: $model.clipboard).font(.callout).toggleStyle(.switch).controlSize(.small)
                Spacer()
                // The same sphere the main window uses for its main action, in a smaller size.
                if model.clientRunning {
                    ActionOrb(title: "Encerrar", icon: "stop.fill", theme: MainSection.connect.theme, action: { Task { await model.disconnect() } }, size: 66)
                } else {
                    ActionOrb(title: "Conectar", icon: "play.fill", busy: model.phase == .preparing,
                              enabled: model.ports[model.effectiveTarget.rawValue] == true, theme: MainSection.connect.theme,
                              action: { Task { await model.connect() } }, size: 66)
                }
            }
        }
        .disabled(model.phase == .preparing)
        .card()
        .onChange(of: model.effectiveMode) { newMode in
            // Fixed resolutions only make sense for a virtual screen.
            if newMode == .mirror && model.sizeTag != "full" { model.sizeTag = "fit" }
        }
    }

    private var fitLabel: String {
        if model.effectiveMode == .mirror, let monitor = model.mirrorSource {
            return "Janela no tamanho do host · \(monitor.width)×\(monitor.height)"
        }
        guard let display = model.selectedDisplay else { return "Ajustar ao monitor do Mac" }
        return "Ajustar ao monitor do Mac · \(display.usable.even.width)×\(display.usable.even.height)"
    }

    private var hint: String {
        if model.effectiveTarget == .login {
            return "Abre o login do GNOME em uma sessão separada, com credencial RDP própria."
        }
        if model.effectiveMode == .mirror {
            return "Mostra o que está no monitor físico do host, na resolução dele."
        }
        if model.usesAllDisplays {
            return "Tela cheia em todos os monitores do Mac: o host cria uma tela virtual para cada um."
        }
        if model.status != nil && model.mirrorSource == nil {
            return "Host sem monitor físico: a tela virtual é criada na resolução escolhida."
        }
        return "Cria uma tela na resolução escolhida; funciona com ou sem monitor no host."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.lastUpdate.map { "Atualizado " + $0.formatted(date: .omitted, time: .standard) } ?? "")
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            Spacer()
            if let share = model.env.smbURL.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(share) } label: { Label("Finder", systemImage: "folder") }
                    .disabled(model.ports["smb"] != true).help("Abre a pasta compartilhada no Finder (requer LAN)")
            }
            Button {
                if let url = model.sshAlias.flatMap({ URL(string: "ssh://" + $0) }) { NSWorkspace.shared.open(url) }
            } label: { Label("Terminal", systemImage: "terminal") }
            .disabled(model.sshAlias == nil).help("Abre uma sessão SSH no Terminal")
            Menu {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(get: { model.launchAtLogin },
                                                                 set: { model.setLaunchAtLogin($0) }))
                if let offer = updater.offer {
                    Button("Atualizar para \(offer.version)…") { confirmUpdate(offer, updater) }
                } else {
                    Button(updater.state == .checking ? "Procurando atualizações…" : "Procurar atualizações (versão \(UpdateEngine.runningVersion))") {
                        Task { await updater.check() }
                    }
                    .disabled(updater.busy)
                }
                Button("Adicionar ambiente…") { openWizard() }
                Button("Redefinir credencial de \(model.effectiveTarget.title.lowercased())…") { confirmReset() }
                    .disabled(model.phase != .idle)
                Divider()
                Button("Sair do Home Lab") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(GlassButtonStyle())
        .font(.caption)
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Remover a credencial guardada de \(model.effectiveTarget.title.lowercased())?"
        alert.informativeText = "A senha no Home Lab não muda. O app pedirá a credencial de novo na próxima conexão."
        alert.addButton(withTitle: "Remover do Keychain").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Task { await model.resetCredential() } }
    }
}

struct PasswordForm: View {
    var request: Model.PasswordRequest
    @State private var password = ""
    @State private var save = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.title, systemImage: "lock.shield").font(.callout.weight(.medium))
            Text(request.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Senha do Linux", text: $password).textFieldStyle(.roundedBorder)
                .onSubmit { if !password.isEmpty { request.answer(password, save) } }
            HStack {
                Toggle("Guardar no Keychain deste Mac", isOn: $save).font(.caption)
                Spacer()
                Button("Cancelar", role: .cancel) { request.answer(nil, false) }.keyboardShortcut(.cancelAction)
                Button("Continuar") { request.answer(password, save) }
                    .buttonStyle(.borderedProminent).disabled(password.isEmpty)
            }
        }
        .card()
    }
}

struct CredentialForm: View {
    var target: Target
    var onSave: (Credential) -> Void
    var onCancel: () -> Void
    @State private var username = ""
    @State private var password = ""

    private var valid: Bool {
        !username.isEmpty && !password.isEmpty && username.utf8.count < 512 && password.utf8.count < 512
            && !(username + password).contains { $0.isNewline }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Credencial RDP · " + target.title, systemImage: "key.fill").font(.callout.weight(.medium))
            Text("Digite a credencial RDP já existente deste destino. Ela fica só no Keychain deste Mac, com acesso limitado a este app.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Usuário RDP", text: $username)
            SecureField("Senha RDP", text: $password)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar e conectar") { onSave(Credential(username: username, password: password)) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .card()
    }
}

// MARK: - App

/// Asks before replacing the app: it restarts, and an unsigned build makes macOS ask for Keychain access again.
@MainActor
func confirmUpdate(_ release: ReleaseInfo, _ updater: Updater) {
    let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let text = "O app baixa a versão \(release.version) do GitHub, confere o arquivo, troca de lugar e reabre. "
        + "O macOS vai pedir de novo o acesso às credenciais no Keychain."
        + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
    if confirmAlert("Atualizar o Home Lab para \(release.version)?", text, button: "Atualizar") {
        Task { await updater.install() }
    }
}

let showWindowNotification = Notification.Name("com.codex.homelab.app.show")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(forName: showWindowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MainWindowController.shared.show(model: .shared) }
        }
        // Opened by hand: show the window. Started at login: stay quietly in the menu bar.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin { MainWindowController.shared.show(model: .shared) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Model.shared.closeAllTunnels() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainWindowController.shared.show(model: .shared)
        return false
    }
}

struct HomeLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = Model.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // The brand glyph as a template image; a dot marks an open session.
            if model.checkedOnce && !model.online {
                Image(systemName: "exclamationmark.triangle").accessibilityLabel("Home Lab offline")
            } else if let glyph = Assets.template(model.clientRunning ? "menubar-connected" : "menubar") {
                Image(nsImage: glyph).accessibilityLabel("Home Lab")
            } else {
                Image(systemName: model.clientRunning ? "display" : "server.rack").accessibilityLabel("Home Lab")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum Entry {
    static func main() {
        var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &coreLimit)
        // ssh runs this binary as its askpass while the wizard installs the SSH key.
        if let secret = ProcessInfo.processInfo.environment["HOMELAB_ASKPASS"] {
            print(secret)
            exit(0)
        }
        if CommandLine.arguments.dropFirst().first == "selftest" {
            var code = runSelfTest()
            // Inside the built app, the host script and the .deb must have been packed along.
            if Bundle.main.bundlePath.hasSuffix(".app") {
                let packed = !HostScript.text.isEmpty && HostScript.package != nil
                print((packed ? "ok   " : "FAIL ") + "bundle carries the host script and the .deb")
                if !packed { code = 1 }
            }
            exit(code)
        }
#if SNAPSHOT
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "snapshot" {
            MainActor.assumeIsolated { snapshot(to: CommandLine.arguments[2]) }
        }
#endif
        if let command = CommandLine.arguments.dropFirst().first, command == "update-check" || command == "update-install" {
            runUpdateCommand(command)
        }
        // One menu bar icon, even when started with `open -n`.
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && $0.executableURL?.lastPathComponent == "HomeLab" }
        if !twins.isEmpty {
            // Opening the app again brings up the window of the copy that is already running.
            DistributedNotificationCenter.default().postNotificationName(showWindowNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        HomeLabApp.main()
    }
}

#if SNAPSHOT
/// Development aid: renders the menu bar panel, or one section of the main window, off-screen to a PNG.
/// usage: snapshot <png> [main <section> [wizard step]]
@MainActor
func snapshot(to path: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = Model()
    let arguments = CommandLine.arguments
    let main = arguments.count > 3 && arguments[3] == "main"
    if arguments.count > 3 && arguments[3] == "pin" {
        // Smoke test of the detached panel: it must exist, float, and take the content's height.
        PinnedPanelController.shared.pin(model: model, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let panels = NSApp.windows.filter { $0 is FloatingPanel }
            print("pinned panels:", panels.count, "frame:", panels.first?.frame ?? .zero, "level floating:", panels.first?.level == .floating,
                  "visible:", panels.first?.isVisible ?? false, "model.pinned:", model.pinned, "viewers:", model.viewers)
            PinnedPanelController.shared.unpin(model: model)
            print("after unpin:", NSApp.windows.filter { $0 is FloatingPanel && $0.isVisible }.count, "model.pinned:", model.pinned)
            exit(0)
        }
        app.run()
    }
    let navigator = Navigator()
    if main, arguments.count > 4, let section = MainSection(rawValue: arguments[4]) { navigator.section = section }
    let root = main ? AnyView(MainView(model: model, navigator: navigator))
                    : AnyView(PanelView(model: model).background(Color(nsColor: .windowBackgroundColor)))
    let host = NSHostingView(rootView: root)
    let size = main ? MainWindowController.canvas : CGSize(width: 430, height: 900)
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: -5000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = host
    window.orderBack(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
        if !main { window.setContentSize(host.fittingSize) }
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
    app.run()
    exit(0)
}
#endif
