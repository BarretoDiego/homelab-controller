import AppKit
import SwiftUI

// Services section: systemd units, Docker containers and processes of the host, with the
// controls and the logs next to the list.

@MainActor
final class ServiceCenter: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case units, containers, images, processes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .units: return "Serviços"
            case .containers: return "Containers"
            case .images: return "Imagens"
            case .processes: return "Processos"
            }
        }
        var icon: String {
            switch self {
            case .units: return "gearshape.2.fill"
            case .containers: return "shippingbox.fill"
            case .images: return "square.stack.fill"
            case .processes: return "cpu"
            }
        }
    }

    @Published var tab: Tab = .units { didSet { search = ""; logs = nil } }
    @Published var search = ""
    @Published var unitFilter: UnitFilter = .mine
    @Published var units: [UnitInfo] = []
    @Published var containers: [ContainerInfo] = []
    @Published var dockerError: String?
    @Published var processes: [ProcessRow] = []
    @Published var images: [ImageInfo] = []
    /// `docker inspect` of the selected container, and whether the detail pane shows it instead of the log.
    @Published var detail: ContainerDetail?
    @Published var showDetails = false
    @Published var execOutput: String?
    @Published var sortByMemory = false
    @Published var selectedUnit: String?
    @Published var selectedContainer: String?
    @Published var selectedProcess: Int?
    @Published var loading = false
    @Published var loadedOnce: Set<Tab> = []
    @Published var logs: LogResult?
    @Published var logsLoading = false
    /// What is being done right now, shown next to the buttons.
    @Published var acting: String?
    @Published var message: (text: String, isError: Bool)?

    var visibleUnits: [UnitInfo] { filterUnits(units, filter: unitFilter, search: search) }
    var visibleContainers: [ContainerInfo] { filterContainers(containers, search: search) }
    var visibleProcesses: [ProcessRow] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? processes : processes.filter { ($0.name + " " + $0.command + " " + $0.user).lowercased().contains(needle) }
    }
    var visibleImages: [ImageInfo] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? images : images.filter { $0.name.lowercased().contains(needle) }
    }
    var unit: UnitInfo? { units.first { $0.id == selectedUnit } }
    var container: ContainerInfo? { containers.first { $0.name == selectedContainer } }
    var process: ProcessRow? { processes.first { $0.pid == selectedProcess } }

    func refresh(_ model: Model) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        switch tab {
        case .units:
            if let list: UnitList = await model.host("services", timeout: 25) { units = list.units }
        case .containers:
            if let list: ContainerList = await model.host("containers", timeout: 20) {
                containers = list.containers
                dockerError = list.available ? nil : (list.error ?? "Docker indisponível")
            }
        case .images:
            if let list: ImageList = await model.host("docker-images", timeout: 25) { images = list.images }
        case .processes:
            if let list: ProcessList = await model.host("processes", ["limit": 60, "sort": sortByMemory ? "mem" : "cpu"], timeout: 20) {
                processes = list.processes
            }
        }
        loadedOnce.insert(tab)
#if SNAPSHOT
        // Development renders: open on the requested tab with its first row selected.
        if let wanted = ProcessInfo.processInfo.environment["HOMELAB_SNAP_TAB"].flatMap(Tab.init(rawValue:)) {
            if tab != wanted { tab = wanted; loading = false; await refresh(model); return }
            if tab == .units, selectedUnit == nil, let first = visibleUnits.first { selectedUnit = first.id; await loadLogs(model) }
            if tab == .containers, selectedContainer == nil, let first = visibleContainers.first { selectedContainer = first.name; await loadLogs(model) }
            if tab == .processes, selectedProcess == nil { selectedProcess = visibleProcesses.first?.pid }
        }
#endif
    }

    func loadLogs(_ model: Model) async {
        logsLoading = true
        defer { logsLoading = false }
        switch tab {
        case .units:
            guard let unit, validUnitName(unit.name) else { return }
            let name = unit.id
            let result: LogResult? = await model.host("service-logs", ["scope": unit.scope, "unit": unit.name, "lines": 200], timeout: 25)
            if selectedUnit == name { logs = result ?? LogResult(ok: false, text: "O host não respondeu.") }
        case .containers:
            guard let container else { return }
            let name = container.name
            async let inspect: ContainerDetail? = model.host("docker-inspect", ["name": name], timeout: 20)
            let result: LogResult? = await model.host("container-detail", ["name": name, "lines": 200], timeout: 35)
            let inspected = await inspect
            if selectedContainer == name {
                logs = result ?? LogResult(ok: false, text: "O host não respondeu.")
                detail = inspected
            }
        case .processes, .images:
            break
        }
    }

    private func finish(_ label: String, _ result: ActionResult?, _ model: Model) async {
        acting = nil
        if let result {
            let detail = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = result.ok ? ("\(label): feito.", false) : ("\(label) falhou" + (detail.isEmpty ? "." : ": " + detail), true)
        }
        await refresh(model)
        if tab == .units || tab == .containers { await loadLogs(model) }
    }

    func compose(_ project: String, _ action: String, label: String, _ model: Model) async {
        guard acting == nil else { return }
        acting = label
        let result: ActionResult? = await model.host("docker-compose", ["project": project, "action": action], timeout: 920)
        if result == nil { message = ("\(label): o host não respondeu.", true) }
        await finish("\(label) \(project)", result, model)
    }

    func removeContainer(force: Bool, _ model: Model) async {
        guard let container, acting == nil else { return }
        acting = "Remover"
        let result: ActionResult? = await model.host("docker-remove", ["name": container.name, "force": force], timeout: 70)
        if result?.ok == true { selectedContainer = nil; logs = nil; detail = nil }
        await finish("Remover \(container.name)", result, model)
    }

    func exec(_ command: String, _ model: Model) async {
        guard let container, acting == nil else { return }
        acting = "Executar"
        let result: ActionResult? = await model.host("docker-exec", ["name": container.name, "command": command], timeout: 45)
        acting = nil
        execOutput = "$ " + command + "\n" + (result?.output ?? "O host não respondeu.")
    }

    func removeImage(_ image: ImageInfo, _ model: Model) async {
        guard acting == nil else { return }
        acting = "Remover imagem"
        let result: ActionResult? = await model.host("docker-image-remove", ["id": image.id], timeout: 130)
        await finish("Remover \(image.name)", result, model)
    }

    func unitAction(_ action: String, label: String, _ model: Model) async {
        guard let unit, validUnitName(unit.name), acting == nil else { return }
        acting = label
        let params: [String: Any] = ["scope": unit.scope, "unit": unit.name, "action": action]
        let result: ActionResult?
        if unit.scope == "system" {
            // System units go through sudo; the password is asked only if the host wants one.
            result = await model.privileged("\(label) \(unit.shortName)", command: "service-action", parameters: params, timeout: 80) { $0.auth }
        } else {
            result = await model.host("service-action", params, timeout: 80)
        }
        if result == nil && unit.scope != "system" { message = ("\(label): o host não respondeu.", true) }
        await finish("\(label) \(unit.shortName)", result, model)
    }

    func containerAction(_ action: String, label: String, _ model: Model) async {
        guard let container, acting == nil else { return }
        acting = label
        let result: ActionResult? = await model.host("container-action", ["name": container.name, "action": action], timeout: 110)
        if result == nil { message = ("\(label): o host não respondeu.", true) }
        await finish("\(label) \(container.name)", result, model)
    }

    func kill(_ signal: String, _ model: Model) async {
        guard let process, acting == nil else { return }
        let label = signal == "KILL" ? "Forçar encerramento" : "Encerrar"
        acting = label
        let params: [String: Any] = ["pid": process.pid, "signal": signal]
        let result: ActionResult? = process.own
            ? await model.host("process-kill", params)
            : await model.privileged("\(label) \(process.name)", command: "process-kill", parameters: params, timeout: 30) { $0.auth }
        try? await Task.sleep(nanoseconds: 600_000_000)
        await finish("\(label) \(process.name)", result, model)
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .good: return Neon.green
        case .bad: return Neon.red
        case .busy: return Neon.amber
        case .idle: return Color.white.opacity(0.4)
        }
    }
}

struct ServicesSection: View {
    @ObservedObject var model: Model
    @ObservedObject var center: ServiceCenter
    var theme: Theme
    private let ticker = Timer.publish(every: 12, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                SectionHeader(kicker: model.env.name, title: "Serviços")
                Spacer()
                tabs
            }
            toolbar
            HStack(alignment: .top, spacing: 12) {
                list.pane(6).frame(width: 450)
                detail.pane(16)
            }
        }
        .task(id: center.tab) { await center.refresh(model) }
        .task(id: center.unitFilter) { if center.tab == .units && center.units.isEmpty { await center.refresh(model) } }
        .onReceive(ticker) { _ in Task { if center.acting == nil { await center.refresh(model) } } }
        .onChange(of: model.environmentID) { _ in
            center.units = []; center.containers = []; center.processes = []; center.images = []; center.logs = nil
            center.detail = nil; center.loadedOnce = []
            Task { await center.refresh(model) }
        }
    }

    // MARK: Chrome

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(ServiceCenter.Tab.allCases) { tab in
                let selected = tab == center.tab
                Button { center.tab = tab } label: {
                    Label(tab.title + count(tab), systemImage: tab.icon)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(selected ? 0.2 : 0.0001)))
                        .foregroundStyle(selected ? theme.accent : Color.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.25)))
    }

    private func count(_ tab: ServiceCenter.Tab) -> String {
        switch tab {
        case .units:
            let failed = center.units.filter { $0.active == "failed" }.count
            return failed > 0 ? " · \(failed) falha" : ""
        case .containers:
            return center.containers.isEmpty ? "" : " · \(center.containers.filter(\.isRunning).count)/\(center.containers.count)"
        case .images:
            return center.images.isEmpty ? "" : " · \(center.images.count)"
        case .processes: return ""
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("Buscar", text: $center.search).textFieldStyle(.plain).font(.system(size: 13))
                if !center.search.isEmpty {
                    Button { center.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("Limpar busca")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.25)))
            .frame(width: 230)
            if center.tab == .units {
                Picker("Grupo", selection: $center.unitFilter) {
                    ForEach(UnitFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            if center.tab == .processes {
                Picker("Ordem", selection: $center.sortByMemory) {
                    Text("CPU").tag(false)
                    Text("Memória").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .onChange(of: center.sortByMemory) { _ in Task { await center.refresh(model) } }
            }
            Spacer()
            if let message = center.message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(message.isError ? Neon.amber : Neon.green)
                    .lineLimit(1).truncationMode(.tail).help(message.text)
            }
            if center.loading { ProgressView().controlSize(.small) }
            Button { Task { await center.refresh(model) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(GlassButtonStyle()).help("Atualizar agora")
        }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                switch center.tab {
                case .units:
                    let rows = center.visibleUnits
                    if rows.isEmpty { empty(center.unitFilter == .mine ? "Nenhum serviço em ~/.config/systemd/user." : "Nada encontrado.") }
                    ForEach(rows) { unit in unitRow(unit) }
                case .containers:
                    if let error = center.dockerError { empty("Docker: " + error) }
                    let rows = center.visibleContainers
                    if rows.isEmpty && center.dockerError == nil { empty("Nenhum container.") }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, container in
                        if index == 0 || rows[index - 1].project != container.project {
                            HStack {
                                Text(container.project.isEmpty ? "SEM PROJETO" : container.project.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.white.opacity(0.5))
                                Spacer()
                                if !container.project.isEmpty { projectMenu(container.project) }
                            }
                            .padding(.horizontal, 10).padding(.top, index == 0 ? 6 : 12).padding(.bottom, 2)
                        }
                        containerRow(container)
                    }
                case .images:
                    let rows = center.visibleImages
                    if rows.isEmpty { empty("Nenhuma imagem.") }
                    ForEach(rows) { image in imageRow(image) }
                case .processes:
                    let rows = center.visibleProcesses
                    if rows.isEmpty { empty("Nenhum processo.") }
                    ForEach(rows) { process in processRow(process) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(center.loadedOnce.contains(center.tab) ? text : (model.sshAlias == nil && model.checkedOnce ? "Sem SSH: o host precisa estar online." : "Carregando…"))
            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).padding(12)
    }

    private func row<Content: View>(selected: Bool, tone: Tone, @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(tone.color).frame(width: 8, height: 8)
                content()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0.0001)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func unitRow(_ unit: UnitInfo) -> some View {
        row(selected: unit.id == center.selectedUnit, tone: unitTone(unit)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(unit.shortName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(unit.description.isEmpty ? unitStateText(unit) : unit.description)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(unitStateText(unit)).font(.system(size: 11, weight: .medium)).foregroundStyle(unitTone(unit).color)
                if let memory = unit.memoryMB, unit.isRunning {
                    Text(formatMemory(memory)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                }
            }
        } action: {
            center.selectedUnit = unit.id
            center.logs = nil
            Task { await center.loadLogs(model) }
        }
    }

    private func containerRow(_ container: ContainerInfo) -> some View {
        row(selected: container.name == center.selectedContainer, tone: containerTone(container)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(container.image).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(container.status).font(.system(size: 11)).foregroundStyle(containerTone(container).color).lineLimit(1)
        } action: {
            center.selectedContainer = container.name
            center.logs = nil
            center.detail = nil
            center.execOutput = nil
            Task { await center.loadLogs(model) }
        }
    }

    /// Compose verbs for a whole project, run with the files it was started from.
    private func projectMenu(_ project: String) -> some View {
        Menu {
            Button("Subir (up -d)") { Task { await center.compose(project, "up", label: "Subir", model) } }
            Button("Reiniciar") { Task { await center.compose(project, "restart", label: "Reiniciar", model) } }
            Button("Baixar imagens (pull)") { Task { await center.compose(project, "pull", label: "Baixar imagens de", model) } }
            Button("Parar") {
                if confirmAlert("Parar o projeto \(project)?", "Todos os containers dele param até serem iniciados de novo.", button: "Parar") {
                    Task { await center.compose(project, "stop", label: "Parar", model) }
                }
            }
            Button("Derrubar (down)…") {
                if confirmAlert("Derrubar o projeto \(project)?", "Remove os containers e as redes do projeto. Volumes ficam.", button: "Derrubar") {
                    Task { await center.compose(project, "down", label: "Derrubar", model) }
                }
            }
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 12)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Ações do projeto compose")
            .disabled(center.acting != nil)
    }

    private func imageRow(_ image: ImageInfo) -> some View {
        HStack(spacing: 10) {
            Circle().fill(image.inUse ? Neon.green : Color.white.opacity(0.4)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(image.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(image.size) · \(image.created)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 6)
            if image.inUse {
                Text("em uso").font(.system(size: 11)).foregroundStyle(Neon.green)
            } else {
                Button {
                    if confirmAlert("Remover a imagem \(image.name)?", "Libera \(image.size). Para usá-la de novo, o Docker baixa ou reconstrói.", button: "Remover") {
                        Task { await center.removeImage(image, model) }
                    }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Remover imagem")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func processRow(_ process: ProcessRow) -> some View {
        row(selected: process.pid == center.selectedProcess, tone: process.cpu >= 80 ? .busy : .idle) {
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(process.user) · pid \(String(process.pid))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 6)
            Text(String(format: "%.0f%%", process.cpu)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(process.cpu >= 80 ? Neon.amber : theme.accent).frame(width: 46, alignment: .trailing)
            Text(formatMemory(process.memMB)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                .frame(width: 58, alignment: .trailing)
        } action: { center.selectedProcess = process.pid }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch center.tab {
        case .units:
            if let unit = center.unit { unitDetail(unit) } else { placeholder("Escolha um serviço para ver o estado, controlar e ler o log.") }
        case .containers:
            if let container = center.container { containerDetail(container) } else { placeholder("Escolha um container para controlar e ler o log.") }
        case .images:
            imagesSummary
        case .processes:
            if let process = center.process { processDetail(process) } else { placeholder("Escolha um processo para ver o comando e encerrá-lo.") }
        }
    }

    private var imagesSummary: some View {
        let unused = center.images.filter { !$0.inUse }
        return VStack(spacing: 12) {
            HeroObject(name: "hero-services", symbol: "square.stack.fill", theme: theme, size: 170)
            Text("\(center.images.count) imagens · \(unused.count) sem uso").font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("Remova uma imagem sem uso pela lixeira ao lado, ou limpe de uma vez as sem etiqueta e o cache de build.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).frame(width: 300)
            Button("Limpar sobras do Docker") {
                if confirmAlert("Limpar o Docker em \(model.env.name)?",
                                "Remove imagens sem etiqueta e o cache de build. Containers, volumes e imagens em uso ficam.", button: "Limpar") {
                    Task { await model.systemAction("docker-prune", label: "Limpar Docker"); await center.refresh(model) }
                }
            }
            .buttonStyle(GlassButtonStyle()).disabled(model.busyAction != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            HeroObject(name: "hero-services", symbol: "square.stack.3d.up.fill", theme: theme, size: 190)
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func title(_ name: String, _ subtitle: String, tone: Tone, state: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 20, weight: .semibold, design: .rounded)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Text(state).font(.system(size: 11, weight: .semibold)).foregroundStyle(tone.color)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(tone.color.opacity(0.16)))
            }
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func facts(_ items: [(String, String?)]) -> some View {
        FlowLayout(spacing: 14) {
            ForEach(items.filter { $0.1 != nil && $0.1?.isEmpty == false }, id: \.0) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0.uppercased()).font(.system(size: 9, weight: .semibold)).kerning(0.8).foregroundStyle(.white.opacity(0.45))
                    Text(item.1 ?? "").font(.system(size: 12, weight: .medium)).monospacedDigit().textSelection(.enabled)
                }
            }
        }
    }

    private func controls<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            if let acting = center.acting {
                ProgressView().controlSize(.small)
                Text(acting + "…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(GlassButtonStyle())
        .disabled(center.acting != nil)
    }

    private func console(reload: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LOG").font(.system(size: 9, weight: .semibold)).kerning(0.8).foregroundStyle(.white.opacity(0.45))
                if center.logsLoading { ProgressView().controlSize(.mini) }
                Spacer()
                if let text = center.logs?.text, !text.isEmpty {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Copiar log")
                }
                if reload {
                    Button { Task { await center.loadLogs(model) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Recarregar log")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(center.logs.map { $0.text.isEmpty ? "(sem linhas)" : $0.text } ?? (center.logsLoading ? "" : "—"))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.38)))
                // Newest lines are at the bottom; start there.
                .onChange(of: center.logs?.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private func unitDetail(_ unit: UnitInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title(unit.shortName, unit.description.isEmpty ? unit.name : unit.description, tone: unitTone(unit), state: unitStateText(unit))
            facts([("Escopo", unit.scope == "user" ? "usuário" : "sistema"),
                   ("Ativo há", unit.activeSeconds.map(formatUptime)),
                   ("Memória", unit.isRunning ? unit.memoryMB.map(formatMemory) : nil),
                   ("PID", unit.pid.map(String.init)),
                   ("Reinícios", (unit.restarts ?? 0) > 0 ? String(unit.restarts ?? 0) : nil),
                   ("Inicia no login", ["enabled": "sim", "disabled": "não", "static": "sob demanda"][unit.enabled] ?? unit.enabled),
                   ("Timer", unit.timer),
                   ("Próxima execução", unit.nextRun),
                   ("Resultado", unit.result == "success" ? nil : unit.result)])
            controls {
                if unit.isRunning {
                    Button { Task { await center.unitAction("restart", label: "Reiniciar", model) } } label: { Label("Reiniciar", systemImage: "arrow.clockwise") }
                    Button { Task { await center.unitAction("stop", label: "Parar", model) } } label: { Label("Parar", systemImage: "stop.fill") }
                } else {
                    Button { Task { await center.unitAction("start", label: "Iniciar", model) } } label: {
                        Label(unit.timer != nil ? "Executar agora" : "Iniciar", systemImage: "play.fill")
                    }
                }
                if unit.active == "failed" {
                    Button { Task { await center.unitAction("reset-failed", label: "Limpar falha", model) } } label: { Label("Limpar falha", systemImage: "eraser") }
                }
                if let file = unit.file {
                    Button { model.editor = Model.EditorRequest(path: file, title: "Unidade " + unit.name, reload: unit.scope) } label: {
                        Label("Editar unidade", systemImage: "square.and.pencil")
                    }
                }
                if unit.canToggleBoot {
                    let on = unit.enabled == "enabled"
                    Button { Task { await center.unitAction(on ? "disable" : "enable", label: on ? "Desativar no login" : "Ativar no login", model) } } label: {
                        Label(on ? "Não iniciar no login" : "Iniciar no login", systemImage: on ? "power.circle" : "power.circle.fill")
                    }
                }
            }
            console(reload: true)
        }
    }

    private func containerDetail(_ container: ContainerInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            title(container.name, container.image, tone: containerTone(container), state: container.state)
            facts([("Status", container.status), ("Projeto", container.project), ("Portas", container.ports),
                   ("CPU", center.logs?.cpu), ("Memória", center.logs?.memory), ("Reinício", center.detail?.restart)])
            controls {
                if container.isRunning {
                    Button { Task { await center.containerAction("restart", label: "Reiniciar", model) } } label: { Label("Reiniciar", systemImage: "arrow.clockwise") }
                    Button {
                        if confirmAlert("Parar \(container.name)?", "O container para de responder até ser iniciado de novo.", button: "Parar") {
                            Task { await center.containerAction("stop", label: "Parar", model) }
                        }
                    } label: { Label("Parar", systemImage: "stop.fill") }
                } else {
                    Button { Task { await center.containerAction("start", label: "Iniciar", model) } } label: { Label("Iniciar", systemImage: "play.fill") }
                }
                Button {
                    if confirmAlert("Remover o container \(container.name)?",
                                    container.isRunning ? "Ele está rodando: será parado à força e apagado. Dados fora de volumes se perdem."
                                                        : "O container é apagado. Dados fora de volumes se perdem.", button: "Remover") {
                        Task { await center.removeContainer(force: container.isRunning, model) }
                    }
                } label: { Label("Remover", systemImage: "trash") }
                Picker("Painel", selection: $center.showDetails) {
                    Text("Log").tag(false)
                    Text("Detalhes").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }
            if center.showDetails { containerFacts } else { console(reload: true) }
            ExecBar(center: center, model: model, enabled: container.isRunning)
        }
    }

    private func factList(_ title: String, _ lines: [String], mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).kerning(0.8).foregroundStyle(.white.opacity(0.45))
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 11, design: mono ? .monospaced : .default)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var containerFacts: some View {
        if let detail = center.detail, detail.ok {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    factList("Comando", [detail.command ?? ""].filter { !$0.isEmpty })
                    if let files = detail.composeFiles, !files.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ARQUIVOS COMPOSE").font(.system(size: 9, weight: .semibold)).kerning(0.8).foregroundStyle(.white.opacity(0.45))
                            ForEach(files, id: \.self) { file in
                                HStack {
                                    Text(file).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                                    Spacer(minLength: 6)
                                    Button("Editar") { model.editor = Model.EditorRequest(path: file, title: "Compose de " + (detail.project ?? ""), reload: nil) }
                                        .buttonStyle(GlassButtonStyle())
                                }
                            }
                        }
                    }
                    if let ports = detail.ports, !ports.isEmpty { factList("Portas", ports) }
                    if let mounts = detail.mounts, !mounts.isEmpty { factList("Volumes e pastas", mounts) }
                    if let networks = detail.networks, !networks.isEmpty { factList("Redes", networks) }
                    if let env = detail.env, !env.isEmpty { factList("Variáveis de ambiente", env.map { $0.key + "=" + $0.value }) }
                    factList("Criado em", [detail.created ?? ""].filter { !$0.isEmpty })
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.3)))
        } else {
            Text(center.detail?.error ?? "Carregando detalhes…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func processDetail(_ process: ProcessRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title(process.name, "Processo de \(process.user)", tone: process.cpu >= 80 ? .busy : .idle,
                  state: String(format: "%.0f%% CPU", process.cpu))
            facts([("PID", String(process.pid)), ("Memória", formatMemory(process.memMB)),
                   ("Rodando há", formatUptime(process.seconds)), ("Dono", process.user)])
            controls {
                Button {
                    if confirmAlert("Encerrar \(process.name) (pid \(process.pid))?", "Envia SIGTERM: o processo pode salvar e sair.", button: "Encerrar") {
                        Task { await center.kill("TERM", model) }
                    }
                } label: { Label("Encerrar", systemImage: "xmark.circle") }
                Button {
                    if confirmAlert("Forçar o encerramento de \(process.name) (pid \(process.pid))?",
                                    "Envia SIGKILL: o processo morre na hora, sem salvar nada.", button: "Forçar") {
                        Task { await center.kill("KILL", model) }
                    }
                } label: { Label("Forçar", systemImage: "bolt.fill") }
            }
            if !process.own {
                Label("Processo de outro usuário: o encerramento usa sudo.", systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("COMANDO").font(.system(size: 9, weight: .semibold)).kerning(0.8).foregroundStyle(.white.opacity(0.45))
                ScrollView {
                    Text(process.command.isEmpty ? "(processo do kernel ou sem linha de comando)" : process.command)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.38)))
            }
            Text("CPU medida em meio segundo; 100% equivale a um núcleo inteiro.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// Runs one shell command inside the selected container and shows what it printed.
struct ExecBar: View {
    @ObservedObject var center: ServiceCenter
    @ObservedObject var model: Model
    var enabled: Bool
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let output = center.execOutput {
                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        Text(output).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(maxHeight: 90)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.45)))
                    Button { center.execOutput = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).padding(5).help("Fechar saída")
                }
            }
            HStack(spacing: 8) {
                TextField("comando dentro do container (sh -c)", text: $command).textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.32)))
                    .onSubmit(run)
                Button("Executar", action: run).buttonStyle(GlassButtonStyle())
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || center.acting != nil)
            }
            .disabled(!enabled)
        }
    }

    private func run() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, enabled else { return }
        command = ""
        Task { await center.exec(text, model) }
    }
}
