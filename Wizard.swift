import AppKit
import SwiftUI

// Guided setup of a new environment: reach the machine over SSH, see what it has,
// prepare it for desktop sharing, and save it with its certificate pinned.
// The steps are drawn by SetupSection in MainWindow.swift.

@MainActor
final class WizardModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case connection, check, prepare, done
        var title: String {
            switch self {
            case .connection: return "Conexão"
            case .check: return "Verificação"
            case .prepare: return "Preparação"
            case .done: return "Concluir"
            }
        }
        var icon: String {
            switch self {
            case .connection: return "point.3.connected.trianglepath.dotted"
            case .check: return "checklist"
            case .prepare: return "wrench.and.screwdriver"
            case .done: return "checkmark.seal"
            }
        }
    }
    enum SSHState: Equatable { case idle, testing, ok, failed(String) }
    struct LogLine: Identifiable {
        let id = UUID()
        var text: String
        var ok: Bool
    }

    @Published var step: Step = .connection
    @Published var name = ""
    @Published var sshTarget = ""
    @Published var sshState: SSHState = .idle
    @Published var linuxPassword = ""
    @Published var saveLinuxPassword = true
    @Published var detect: DetectInfo?
    @Published var installPackage = false
    @Published var rdpUser = ""
    @Published var rdpPassword = ""
    @Published var log: [LogLine] = []
    @Published var busy: String?
    @Published var prepared = false

    private let firstContact = ["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=8"]

    var target: String { sshTarget.trimmingCharacters(in: .whitespaces) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var connectionReady: Bool { !trimmedName.isEmpty && validSSHTarget(target) }
    /// New credentials are mandatory only when the host has none yet.
    var needsNewCredentials: Bool { detect?.rdp?.hasCredentials != true }
    var credentialsTyped: Bool { !rdpUser.isEmpty && !rdpPassword.isEmpty }
    var canPrepare: Bool {
        guard let detect, detect.supported, busy == nil else { return false }
        if needsNewCredentials && !credentialsTyped { return false }
        if (detect.needsPackages || installPackage) && detect.sudoNeedsPassword == true && linuxPassword.isEmpty { return false }
        return true
    }
    var ready: Bool { detect?.supported == true && detect?.needsSetup == false && detect?.needsPackages == false }

    func testSSH() async {
        guard connectionReady else { return }
        sshState = .testing
        // First contact records the host key (trust on first use); later calls refuse a changed key.
        let result = await run("/usr/bin/ssh", ["-o", "BatchMode=yes"] + firstContact + [target, "true"],
                               mergeStderr: true, timeout: 15)
        if result.ok {
            sshState = .ok
        } else {
            let reason = result.output.split(separator: "\n").last.map(String.init) ?? "sem resposta"
            sshState = .failed(reason.contains("Permission denied")
                               ? "O host respondeu, mas ainda não aceita a chave SSH deste Mac."
                               : "Não foi possível conectar: \(reason)")
        }
    }

    /// Adds this Mac's public key to the host, authenticating once with the Linux password.
    func installKey() async {
        guard connectionReady, !linuxPassword.isEmpty, let binary = Bundle.main.executablePath else { return }
        busy = "Instalando a chave SSH"
        defer { busy = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        var publicKey = ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"]
            .compactMap { try? String(contentsOf: home.appendingPathComponent($0), encoding: .utf8) }.first
        if publicKey == nil {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let key = home.appendingPathComponent("id_ed25519").path
            _ = await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key], timeout: 20)
            publicKey = try? String(contentsOfFile: key + ".pub", encoding: .utf8)
        }
        guard let line = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            sshState = .failed("Não foi possível criar uma chave SSH neste Mac.")
            return
        }
        // ssh has no terminal here, so it asks this same binary for the password (see Entry.main).
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = binary
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["HOMELAB_ASKPASS"] = linuxPassword
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        let remote = "k=$(cat); mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "{ grep -qxF \"$k\" ~/.ssh/authorized_keys || printf '%s\\n' \"$k\" >> ~/.ssh/authorized_keys; } && "
            + "chmod 600 ~/.ssh/authorized_keys"
        let result = await run("/usr/bin/ssh", firstContact + ["-o", "PubkeyAuthentication=no",
                               "-o", "PreferredAuthentications=password,keyboard-interactive",
                               "-o", "NumberOfPasswordPrompts=1", target, remote],
                               stdin: Data((line + "\n").utf8), mergeStderr: true, environment: environment, timeout: 25)
        if result.ok {
            await testSSH()
        } else {
            sshState = .failed(result.output.contains("Permission denied")
                               ? "Senha do Linux recusada pelo host."
                               : "Não foi possível instalar a chave: " + (result.output.split(separator: "\n").last.map(String.init) ?? "sem resposta"))
        }
    }

    func runDetect() async {
        busy = "Lendo o host"
        defer { busy = nil }
        var params: [String: Any] = [:]
        if !linuxPassword.isEmpty { params["password"] = linuxPassword }
        detect = await hostCall([target], "detect", params, timeout: 25)?.value
        if let detect {
            installPackage = detect.needsPackages
            prepared = !detect.needsSetup && !detect.needsPackages
        }
    }

    func prepare() async {
        guard let before = detect else { return }
        log = []
        var params: [String: Any] = [:]
        if !linuxPassword.isEmpty { params["password"] = linuxPassword }

        if before.needsPackages || installPackage {
            busy = "Instalando o pacote homelab-host"
            guard let package = HostScript.package else {
                log.append(LogLine(text: "Pacote homelab-host não encontrado dentro do app.", ok: false))
                busy = nil
                return
            }
            let remote = "/tmp/homelab-host-\(UUID().uuidString.prefix(8)).deb"
            let upload = await run("/usr/bin/scp", sshOptions + ["-q", "--", package.path, "\(target):\(remote)"], timeout: 60)
            guard upload.ok else {
                log.append(LogLine(text: "Não foi possível enviar o pacote ao host.", ok: false))
                busy = nil
                return
            }
            var install = params
            install["path"] = remote
            let result: SudoResult? = await hostCall([target], "install-package", install, timeout: 640)?.value
            if result?.ok == true {
                log.append(LogLine(text: "Pacote homelab-host instalado, com as dependências.", ok: true))
            } else {
                let why = result?.auth == false ? "senha do Linux recusada pelo sudo"
                    : (result?.output?.split(separator: "\n").last.map(String.init) ?? "sem resposta")
                log.append(LogLine(text: "Instalação do pacote falhou: \(why)", ok: false))
                busy = nil
                return
            }
        }

        busy = "Configurando o compartilhamento de tela"
        var setup: [String: Any] = [:]
        if needsNewCredentials { setup["rdpUser"] = rdpUser; setup["rdpPassword"] = rdpPassword }
        let result: SetupResult? = await hostCall([target], "setup", setup, timeout: 180)?.value
        let labels = ["certificate": "Certificado TLS", "credentials": "Credencial RDP", "port": "Porta",
                      "control": "Controle de teclado e mouse", "enable": "RDP ligado",
                      "virtual screen": "Tela virtual (funciona sem monitor)", "service": "Serviço em execução",
                      "gnome-remote-desktop": "GNOME Remote Desktop"]
        for item in result?.steps ?? [] {
            let detail = item.detail == "kept" ? " (mantido)" : (item.detail == "created" ? " (criado)" : (item.ok ? "" : ": " + item.detail))
            log.append(LogLine(text: (labels[item.name] ?? item.name) + detail, ok: item.ok))
        }
        if result == nil { log.append(LogLine(text: "O host não respondeu à configuração.", ok: false)) }
        if let error = result?.error { log.append(LogLine(text: error, ok: false)) }
        busy = nil
        await runDetect()
        prepared = result?.ok == true && detect?.needsSetup == false
    }

    /// Back to a blank wizard, ready for another environment.
    func reset() {
        step = .connection; name = ""; sshTarget = ""; sshState = .idle; linuxPassword = ""
        detect = nil; installPackage = false; rdpUser = ""; rdpPassword = ""; log = []; prepared = false
    }

    func environment(taken: Set<String>) -> HostEnvironment? {
        guard let detect, let rdp = detect.rdp else { return nil }
        return makeEnvironment(name: trimmedName, sshTarget: target, detect: detect, rdp: rdp, taken: taken)
    }

    /// Saves the environment and whatever secrets were typed along the way.
    func finish(into model: Model) async -> Bool {
        guard let environment = environment(taken: Set(model.environments.map(\.id))) else { return false }
        if credentialsTyped, let endpoint = environment.endpoint(.session) {
            let credential = Credential(username: rdpUser, password: rdpPassword)
            _ = try? await Task.detached { try CredentialStore.store(credential, endpoint) }.value
        }
        if saveLinuxPassword && !linuxPassword.isEmpty {
            let credential = Credential(username: "", password: linuxPassword)
            let service = environment.linuxPasswordService, label = "\(environment.name) — senha do Linux"
            _ = try? await Task.detached {
                try CredentialStore.store(credential, service: service, account: CredentialStore.linuxAccount, label: label)
            }.value
        }
        linuxPassword = ""; rdpPassword = ""
        model.add(environment)
        return true
    }
}

// MARK: - Look

enum Neon {
    static let navy = Color(red: 0.043, green: 0.063, blue: 0.125)
    static let indigo = Color(red: 0.106, green: 0.122, blue: 0.294)
    static let cyan = Color(red: 0.239, green: 0.878, blue: 1.0)
    static let violet = Color(red: 0.545, green: 0.361, blue: 1.0)
    static let green = Color(red: 0.30, green: 0.95, blue: 0.62)
    static let amber = Color(red: 1.0, green: 0.74, blue: 0.30)
    static let red = Color(red: 1.0, green: 0.38, blue: 0.42)
    static let beam = LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)
}

struct NeonButtonStyle: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        NeonButtonBody(configuration: configuration, primary: primary, enabled: enabled)
    }

    private struct NeonButtonBody: View {
        let configuration: Configuration
        let primary: Bool
        let enabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(primary ? Neon.navy : Color.white.opacity(0.9))
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background {
                    if primary {
                        Capsule().fill(Neon.beam)
                    } else {
                        Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0.06))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                    }
                }
                .shadow(color: .black.opacity(primary ? 0.3 : 0), radius: 6, y: 3)
                .brightness(primary && hovering ? 0.08 : 0)
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.03 : 1))
                .opacity(enabled ? 1 : 0.35)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
                .onHover { hovering = $0 && enabled }
        }
    }
}

/// Text field as a glass capsule whose border lights up with focus.
struct NeonField: View {
    var label: String
    var prompt: String
    @Binding var text: String
    var secure = false
    var icon: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(1.2)
                .foregroundStyle(focused ? Neon.cyan : Color.white.opacity(0.5))
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(focused ? Neon.cyan : Color.white.opacity(0.45)).frame(width: 18)
                Group {
                    if secure {
                        SecureField("", text: $text, prompt: Text(prompt).foregroundColor(.white.opacity(0.3)))
                    } else {
                        TextField("", text: $text, prompt: Text(prompt).foregroundColor(.white.opacity(0.3)))
                            .autocorrectionDisabled()
                    }
                }
                .textFieldStyle(.plain).focused($focused)
                .font(.system(size: 14, design: secure ? .default : .monospaced))
                .accessibilityLabel(label)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focused ? AnyShapeStyle(Neon.beam) : AnyShapeStyle(Color.white.opacity(0.12)), lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

/// This Mac and the host, joined by a line that carries pulses while they talk.
struct LinkDiagram: View {
    enum State { case idle, linking, linked, failed }
    var state: State
    var hostName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch state {
        case .idle: return .white.opacity(0.25)
        case .linking: return Neon.cyan
        case .linked: return Neon.green
        case .failed: return Neon.red
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            node("laptopcomputer", "Este Mac", lit: true)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || state == .idle || state == .failed)) { timeline in
                Canvas { context, size in
                    let y = size.height / 2
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(color.opacity(state == .linked ? 0.9 : 0.4)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: state == .linked ? [] : [5, 6]))
                    guard state == .linking || state == .linked, !reduceMotion else { return }
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let count = state == .linking ? 3 : 2, speed = state == .linking ? 0.9 : 0.35
                    for i in 0..<count {
                        let progress = (t * speed + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                        let x = CGFloat(progress) * size.width
                        let rect = CGRect(x: x - 9, y: y - 9, width: 18, height: 18)
                        context.fill(Path(ellipseIn: rect), with: .radialGradient(
                            glowGradient(color, peak: 1), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 9))
                    }
                }
            }
            .frame(height: 24).padding(.horizontal, 6).padding(.bottom, 18)
            node("server.rack", hostName, lit: state == .linked || state == .linking)
        }
        .animation(.easeInOut(duration: 0.4), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ligação entre este Mac e \(hostName)")
    }

    private func node(_ icon: String, _ label: String, lit: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                SoftGlow(color: state == .failed ? Neon.red : Neon.cyan, width: 96, height: 96, peak: lit ? 0.42 : 0)
                Circle().fill(Color.white.opacity(0.06)).frame(width: 54, height: 54)
                Circle().strokeBorder(lit ? AnyShapeStyle(Neon.beam) : AnyShapeStyle(Color.white.opacity(0.2)), lineWidth: 1.5)
                    .frame(width: 54, height: 54)
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                    .foregroundStyle(lit ? Color.white : Color.white.opacity(0.4))
            }
            .frame(width: 54, height: 54)
            Text(label).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).frame(width: 130)
        }
    }
}

/// Ring that draws itself, then a check mark.
struct SuccessBurst: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SoftGlow(color: Neon.green, width: 190, height: 190, peak: drawn ? 0.4 : 0)
            Circle().stroke(Neon.green.opacity(0.25), lineWidth: 2).scaleEffect(drawn ? 1.6 : 0.6).opacity(drawn ? 0 : 1)
            Circle().trim(from: 0, to: drawn ? 1 : 0).stroke(Neon.beam, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(Neon.green)
                .scaleEffect(drawn ? 1 : 0.2).opacity(drawn ? 1 : 0)
        }
        .frame(width: 76, height: 76)
        .onAppear {
            if reduceMotion { drawn = true } else { withAnimation(.spring(response: 0.7, dampingFraction: 0.65)) { drawn = true } }
        }
        .accessibilityHidden(true)
    }
}
