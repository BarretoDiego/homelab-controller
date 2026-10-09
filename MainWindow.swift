import AppKit
import SwiftUI

// The main window: a borderless panel on a transparent canvas, one vivid colour per section.
// Along its bottom edge sit a Liquid Glass dock (left) and the action sphere (right), both half
// outside the panel; the section's 3D object leans out of the top-right corner.

enum MainSection: String, CaseIterable, Identifiable {
    case dashboard, connect, files, security, services, network, setup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Visão geral"
        case .connect: return "Conectar"
        case .files: return "Arquivos"
        case .security: return "Segurança"
        case .services: return "Serviços"
        case .network: return "Rede"
        case .setup: return "Novo ambiente"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .connect: return "display"
        case .files: return "folder.fill"
        case .security: return "lock.shield.fill"
        case .services: return "square.stack.3d.up.fill"
        case .network: return "point.3.connected.trianglepath.dotted"
        case .setup: return "plus.circle.fill"
        }
    }
    var theme: Theme {
        switch self {
        case .dashboard: return Theme(top: 0x2B2552, bottom: 0x131129, glow: 0x5B4BD6, accent: 0x5CE1FF)
        case .connect: return Theme(top: 0x0C2F8A, bottom: 0x06143F, glow: 0x2F7BFF, accent: 0x7FD8FF)
        case .files: return Theme(top: 0x075560, bottom: 0x03242D, glow: 0x18B8B0, accent: 0x8FF5E6)
        case .security: return Theme(top: 0x8A2A12, bottom: 0x3C0F08, glow: 0xF0732A, accent: 0xFFC98A)
        case .services: return Theme(top: 0x0D5527, bottom: 0x052313, glow: 0x2FBF5B, accent: 0xA6F7B8)
        case .network: return Theme(top: 0x8A1040, bottom: 0x38071C, glow: 0xF0336A, accent: 0xFFB0C8)
        case .setup: return Theme(top: 0x521670, bottom: 0x1D0A36, glow: 0xC04BFF, accent: 0xF2B0FF)
        }
    }
    /// Sections whose 3D object stands in the window's top-right corner.
    var hasHero: Bool { self == .connect || self == .security || self == .setup }
}

struct Theme {
    var top: Color, bottom: Color, glow: Color, accent: Color
    init(top: UInt32, bottom: UInt32, glow: UInt32, accent: UInt32) {
        func color(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        self.top = color(top); self.bottom = color(bottom); self.glow = color(glow); self.accent = color(accent)
    }
}

enum Assets {
    /// Artwork ships in the bundle; the development snapshot build reads it from HOMELAB_ASSETS.
    static func image(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        if let folder = ProcessInfo.processInfo.environment["HOMELAB_ASSETS"] {
            return NSImage(contentsOfFile: folder + "/" + name + ".png")
        }
        return nil
    }
    static func template(_ name: String) -> NSImage? {
        guard let image = Bundle.main.image(forResource: name) ?? image(name) else { return nil }
        image.isTemplate = true
        return image
    }
}

final class Navigator: ObservableObject {
    @Published var section: MainSection = .dashboard
}

final class GlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    static let canvas = CGSize(width: 1210, height: 860)
    let navigator = Navigator()
    private var window: NSWindow?

    func show(model: Model, section: MainSection? = nil) {
        if let section { navigator.section = section }
        if window == nil {
            let created = GlassWindow(contentRect: NSRect(origin: .zero, size: MainWindowController.canvas),
                                      styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = false              // the panel draws its own, inside the transparent canvas
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.title = "Home Lab"
            created.contentView = NSHostingView(rootView: MainView(model: model, navigator: navigator))
            created.center()
            created.delegate = self
            window = created
        }
        // A window deserves a Dock icon; the menu bar extra alone does not.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
    func miniaturize() { window?.miniaturize(nil) }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// A stretch of window the user can grab to move it. Borderless windows have no title bar,
/// and SwiftUI content swallows the clicks AppKit would use to drag by the background.
struct WindowDragArea: NSViewRepresentable {
    final class Handle: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ nsView: Handle, context: Context) {}
}

/// The drag handle: two rows of dots in a glass pill. Dragging it moves the window.
struct Grip: View {
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 4) {
                    ForEach(0..<6, id: \.self) { _ in Circle().frame(width: 4, height: 4) }
                }
            }
        }
        .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.7))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .liquidGlass(Capsule())
        // On top of the glass, so the pill itself is what gets grabbed.
        .overlay(WindowDragArea())
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .help("Arraste para mover")
        .accessibilityLabel("Arrastar a janela")
    }
}

func confirmAlert(_ title: String, _ text: String, button: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancelar")
    NSApplication.shared.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
}

// MARK: - Building blocks

enum Glass26 {
    /// Development renders cannot capture Liquid Glass, so they ask for the drawn stand-in.
    static let enabled = ProcessInfo.processInfo.environment["HOMELAB_NO_GLASS"] == nil
}

extension View {
    /// Liquid Glass where the system has it; a drawn sheet of glass elsewhere.
    @ViewBuilder func liquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *), Glass26.enabled {
            glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            background(shape.fill(tint ?? Color.white.opacity(0.085)))
                .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }
}

struct Pane: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func pane(_ padding: CGFloat = 16) -> some View { modifier(Pane(padding: padding)) }
}

/// Falloff for anything that glows: eased, so the light thins out to nothing with no visible rim.
/// (Two-stop gradients show their edge, and fading to `.clear` drags the colour through grey.)
func glowGradient(_ color: Color, peak: Double) -> Gradient {
    Gradient(stops: [.init(color: color.opacity(peak), location: 0),
                     .init(color: color.opacity(peak * 0.62), location: 0.22),
                     .init(color: color.opacity(peak * 0.30), location: 0.48),
                     .init(color: color.opacity(peak * 0.09), location: 0.76),
                     .init(color: color.opacity(0), location: 1)])
}

/// A pool of light. It is drawn round and then squashed, so an oval glow still reaches zero
/// exactly at its edge instead of being cut off by its own outline.
struct SoftGlow: View {
    var color: Color
    var width: CGFloat
    var height: CGFloat
    var peak = 0.5

    var body: some View {
        Circle()
            .fill(RadialGradient(gradient: glowGradient(color, peak: peak), center: .center, startRadius: 0, endRadius: width / 2))
            .frame(width: width, height: width)
            .scaleEffect(x: 1, y: height / width)
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The section's 3D glass object: it floats, and leans toward the pointer.
struct HeroObject: View {
    var name: String
    var symbol: String
    var theme: Theme
    var size: CGFloat = 340
    /// The pool of light under the object. Off when the object hangs outside the panel: light needs a surface.
    var pooled = true
    @State private var lean = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                if size >= 200 && pooled {
                    SoftGlow(color: theme.accent, width: size * 1.1, height: size * 0.4, peak: 0.5).offset(y: size * 0.37)
                }
                // The pointer pushes the object around a little; with its slow bob that is enough depth.
                artwork
                    .scaleEffect(1 + abs(lean.width * lean.height) * 0.03)
                    .rotationEffect(.degrees(Double(lean.width) * 3 + sin(t * 0.7) * 1.2))
                    .offset(x: lean.width * 12, y: lean.height * 10 + CGFloat(sin(t * 1.1)) * 7)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                switch phase {
                case .active(let point): lean = CGSize(width: point.x / size * 2 - 1, height: point.y / size * 2 - 1)
                case .ended: lean = .zero
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var artwork: some View {
        if let image = Assets.image(name) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .shadow(color: .black.opacity(0.35), radius: 24, y: 22)
        } else {
            // Stand-in when the artwork is missing: a glass disc with the section's symbol.
            ZStack {
                Circle().fill(LinearGradient(colors: [theme.accent.opacity(0.55), theme.glow.opacity(0.35)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 2)
                Image(systemName: symbol).font(.system(size: size * 0.3, weight: .medium)).foregroundStyle(.white.opacity(0.92))
            }
            .padding(size * 0.14)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 22)
        }
    }
}

/// A glass ball lit from above: vivid body, specular cap, light bouncing back from below, bright rim.
struct GlassSphere<Content: View>: View {
    var theme: Theme
    var diameter: CGFloat
    var bright = false
    var breathing = false
    @ViewBuilder var content: Content

    var body: some View {
        let k = diameter / 96
        ZStack {
            Circle().fill(LinearGradient(colors: [theme.accent, theme.glow, theme.top], startPoint: .top, endPoint: .bottom))
            Circle().fill(RadialGradient(colors: [.black.opacity(0), .black.opacity(0.4)], center: .init(x: 0.5, y: 0.3),
                                         startRadius: 18 * k, endRadius: 64 * k))
            Ellipse().fill(LinearGradient(colors: [.white.opacity(bright ? 0.78 : 0.6), .white.opacity(0)],
                                          startPoint: .top, endPoint: .bottom))
                .frame(width: 64 * k, height: 34 * k).offset(y: -26 * k)
            SoftGlow(color: theme.accent, width: 72 * k, height: 34 * k, peak: breathing ? 0.75 : 0.45).offset(y: 32 * k)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.25), .white.opacity(0.55)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: max(1, 1.5 * k))
            content
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

/// The section's main action: a glass sphere on the panel's bottom edge, at its right end.
struct ActionOrb: View {
    var title: String
    var icon: String
    var busy = false
    var enabled = true
    var theme: Theme
    var action: () -> Void
    @State private var hovering = false
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let diameter: CGFloat = 96
    /// The menu bar panel uses a smaller one.
    var size: CGFloat = ActionOrb.diameter

    var body: some View {
        let k = size / ActionOrb.diameter
        return Button(action: action) {
            GlassSphere(theme: theme, diameter: size, bright: hovering, breathing: breathing) {
                if busy { OrbSpinner().padding(7 * k) }
                VStack(spacing: 3 * k) {
                    Image(systemName: icon).font(.system(size: 15 * k, weight: .bold))
                    Text(title).font(.system(size: max(10, 12.5 * k), weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center).minimumScaleFactor(0.75).lineLimit(1)
                }
                .foregroundStyle(.white).shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .padding(.horizontal, 8 * k).opacity(busy ? 0.7 : 1)
            }
            // Neutral shadow only: half the sphere hangs over the desktop, where coloured light has nothing to land on.
            .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
            .scaleEffect(hovering && enabled && !busy ? 1.06 : 1)
            .opacity(enabled ? 1 : 0.55)
            .saturation(enabled ? 1 : 0.4)
            .contentShape(Circle())
        }
        .buttonStyle(OrbPressStyle())
        .disabled(!enabled || busy)
        .keyboardShortcut(.defaultAction)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .animation(.easeInOut(duration: 0.25), value: enabled)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityLabel(busy ? "\(title), em andamento" : title)
    }
}

struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A turning arc for work in progress.
struct OrbSpinner: View {
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().trim(from: 0, to: 0.28)
            .stroke(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityHidden(true)
    }
}

struct FeatureRow<Trailing: View>: View {
    var icon: String
    var title: String
    var detail: String = ""
    var theme: Theme
    var warn = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [(warn ? Neon.amber : theme.accent).opacity(0.9), theme.glow.opacity(0.8)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(warn ? Neon.amber : Color.white.opacity(0.65)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

struct GlassButtonStyle: ButtonStyle {
    /// Corner radius; nil draws a capsule.
    var shape: CGFloat?
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let outline = RoundedRectangle(cornerRadius: shape ?? 100, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(outline.fill(Color.white.opacity(configuration.isPressed ? 0.3 : 0.15)))
            .overlay(outline.strokeBorder(Color.white.opacity(0.25)))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct RingGauge: View {
    var fraction: Double
    var theme: Theme
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 9)
            Circle().trim(from: 0, to: min(max(fraction, 0.02), 1))
                .stroke(theme.accent.opacity(0.22), style: StrokeStyle(lineWidth: 19, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().trim(from: 0, to: min(max(fraction, 0.02), 1))
                .stroke(AngularGradient(colors: [theme.accent, theme.glow, theme.accent], center: .center),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.spring(response: 0.8, dampingFraction: 0.8), value: fraction)
        .accessibilityHidden(true)
    }
}

struct DockItem: View {
    var item: MainSection
    var selected: Bool
    var warn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if selected {
                    GlassSphere(theme: item.theme, diameter: 50, bright: hovering) {
                        Image(systemName: item.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
                    Text(item.title).font(.system(size: 14, weight: .semibold, design: .rounded)).fixedSize().padding(.trailing, 12)
                } else {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: item.icon).font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.78))
                            .frame(width: 50, height: 50)
                            .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0)))
                        if warn { Circle().fill(Neon.amber).frame(width: 7, height: 7).offset(x: -11, y: 11) }
                    }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(OrbPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Main view

struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var navigator: Navigator
    @StateObject private var wizard = WizardModel()
    @StateObject private var services = ServiceCenter()
    @StateObject private var network = NetworkCenter()
    @ObservedObject private var updater = Updater.shared
    @State private var wizardRevealed = 0

    private var section: MainSection { navigator.section }
    private var theme: Theme { section.theme }
    static let panel = CGSize(width: 1100, height: 650)
    /// Room above and to the right for the 3D object, and below for the dock and the sphere.
    static let origin = CGPoint(x: 30, y: 110)
    /// Content, dock and sphere share this inset, so everything lines up on the same two edges.
    static let inset: CGFloat = 34
    private var panel: CGSize { MainView.panel }
    private var origin: CGPoint { MainView.origin }
    private var blocked: Bool { model.passwordRequest != nil || model.credentialRequest != nil || model.editor != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                background
                // Anything not covered by a control or a card moves the window.
                WindowDragArea()
                content
                topBar
                Grip().frame(width: panel.width, alignment: .center).padding(.top, 12)
                if blocked { modal }
            }
            .frame(width: panel.width, height: panel.height)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.08), theme.accent.opacity(0.3)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 28, y: 16)
            .offset(x: origin.x, y: origin.y)
            if section.hasHero && !blocked {
                // A good third of it stands outside the panel, above and to the right.
                HeroObject(name: "hero-" + section.rawValue, symbol: section.icon, theme: theme, size: 310, pooled: false)
                    .position(x: origin.x + panel.width - 118, y: origin.y + 52)
                    .id(section)
                    .transition(.asymmetric(insertion: .scale(scale: 0.7).combined(with: .opacity), removal: .opacity))
            }
            // Dock and sphere ride the bottom edge together: one on each end, centred on the same line.
            HStack(alignment: .center) {
                dock
                Spacer()
                if let spec = actionSpec {
                    ActionOrb(title: spec.title, icon: spec.icon, busy: spec.busy, enabled: spec.enabled, theme: theme, action: spec.action)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: panel.width - MainView.inset * 2, height: ActionOrb.diameter)
            .position(x: origin.x + panel.width / 2, y: origin.y + panel.height)
        }
        .frame(width: MainWindowController.canvas.width, height: MainWindowController.canvas.height, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .tint(theme.accent)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: section)
        .onAppear {
            model.viewers += 1
            // Nothing configured yet: start at the assistant.
            if model.environments.isEmpty { navigator.section = .setup }
        }
        .onDisappear { model.viewers -= 1 }
    }

    /// Each section floods the panel with its own colour; they are stacked and cross-faded.
    private var background: some View {
        ZStack {
            ForEach(MainSection.allCases) { item in
                ZStack {
                    LinearGradient(colors: [item.theme.top, item.theme.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(gradient: glowGradient(item.theme.glow, peak: 0.95),
                                   center: .init(x: 0.74, y: 0.22), startRadius: 0, endRadius: 640)
                    SoftGlow(color: item.theme.accent, width: 760, height: 520, peak: 0.2)
                        .position(x: 130, y: panel.height - 20)
                }
                .opacity(item == section ? 1 : 0)
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                trafficLight(Color(red: 1, green: 0.37, blue: 0.34), "Fechar") { MainWindowController.shared.close() }
                trafficLight(Color(red: 1, green: 0.74, blue: 0.18), "Minimizar") { MainWindowController.shared.miniaturize() }
            }
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
            environmentMenu
            updatePill
            if let notice = model.notice, section != .setup {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(notice.isError ? Neon.amber : Color.white.opacity(0.9))
                    .lineLimit(1).truncationMode(.tail).help(notice.text)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.3)))
                    .frame(maxWidth: 430, alignment: .leading)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.notice)
        .padding(.leading, 24).padding(.top, 18)
    }

    /// Shows up only when there is something to say about updates.
    @ViewBuilder private var updatePill: some View {
        switch updater.state {
        case .available(let release):
            Button { confirmUpdate(release, updater) } label: {
                Label("Atualizar para \(release.version)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(LinearGradient(colors: [theme.accent.opacity(0.9), theme.glow], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain).help("Há uma versão nova publicada no GitHub")
        case .installing(let version):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Instalando \(version)…").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(Color.black.opacity(0.3)))
        case .failed(let reason):
            Label("Atualização: " + reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Neon.amber).lineLimit(1).help(reason)
                .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(Color.black.opacity(0.3)))
                .frame(maxWidth: 380, alignment: .leading)
        default:
            EmptyView()
        }
    }

    private func trafficLight(_ color: Color, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Circle().fill(color).frame(width: 12, height: 12) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var environmentMenu: some View {
        Menu {
            ForEach(model.environments) { environment in
                Button { model.select(environment.id) } label: {
                    Label(environment.name, systemImage: environment.id == model.environmentID ? "checkmark" : "server.rack")
                }
            }
            Divider()
            Button("Novo ambiente…") { navigator.section = .setup }
            Button("Remover \(model.env.name)…") {
                if confirmAlert("Remover o ambiente \(model.env.name)?",
                                "O app esquece este ambiente e apaga as credenciais dele do Keychain. Nada é alterado no host.",
                                button: "Remover") { model.removeCurrentEnvironment() }
            }
            .disabled(model.environments.isEmpty || model.phase != .idle)
        } label: {
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
            .padding(.horizontal, 12).padding(.vertical, 6)
            .liquidGlass(Capsule(), interactive: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Trocar de ambiente")
    }

    // MARK: Content routing

    private var content: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                switch section {
                case .dashboard:
                    DashboardSection(model: model, theme: theme) { target, tab, byMemory in
                        if let tab { services.tab = tab; services.sortByMemory = byMemory }
                        navigator.section = target
                    }
                case .connect: ConnectSection(model: model, theme: theme)
                case .files: FilesSection(model: model, theme: theme)
                case .security: SecuritySection(model: model, theme: theme)
                case .services: ServicesSection(model: model, center: services, theme: theme)
                case .network: NetworkSection(model: model, center: network, theme: theme)
                case .setup: SetupSection(wizard: wizard, model: model, theme: theme, revealed: $wizardRevealed)
                }
            }
            .padding(.top, 62).padding(.horizontal, MainView.inset).padding(.bottom, 58)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(section)
            .transition(.opacity.combined(with: .offset(y: 10)))
        }
        .frame(width: panel.width, height: panel.height)
    }

    // MARK: Dock

    private struct ActionSpec {
        var title: String
        var icon: String
        var busy = false
        var enabled = true
        var action: () -> Void
    }

    /// The sections, in a Liquid Glass tray on the panel's bottom-left edge. The current one is a
    /// lit sphere with its name; the others are icons resting in the glass.
    private var dock: some View {
        HStack(spacing: 4) {
            ForEach(MainSection.allCases) { item in DockItem(item: item, selected: item == section, warn: warns(item)) { navigator.section = item } }
        }
        .padding(6)
        .liquidGlass(Capsule())
        .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
        .fixedSize()
    }

    private func warns(_ item: MainSection) -> Bool {
        item == .security && model.status?.lockedKeyrings.isEmpty == false
    }

    private var actionSpec: ActionSpec? {
        switch section {
        case .dashboard:
            return ActionSpec(title: "Atualizar", icon: "arrow.clockwise", busy: model.refreshing) { Task { await model.refresh() } }
        case .connect:
            if model.clientRunning { return ActionSpec(title: "Encerrar", icon: "stop.fill") { Task { await model.disconnect() } } }
            return ActionSpec(title: "Conectar", icon: "play.fill", busy: model.phase == .preparing,
                              enabled: model.ports[model.effectiveTarget.rawValue] == true) { Task { await model.connect() } }
        case .security:
            guard model.status?.lockedKeyrings.isEmpty == false else { return nil }
            return ActionSpec(title: "Destrancar", icon: "key.fill", busy: model.busyAction != nil) { Task { await model.unlockKeyrings() } }
        case .setup:
            return setupAction
        case .files, .services, .network:
            return nil
        }
    }

    private var setupAction: ActionSpec {
        let busy = wizard.busy != nil || wizard.sshState == .testing
        switch wizard.step {
        case .connection:
            if wizard.sshState == .ok {
                return ActionSpec(title: "Escanear", icon: "dot.radiowaves.left.and.right", busy: busy) {
                    Task { await wizard.runDetect(); if wizard.detect != nil { advance(.check) } }
                }
            }
            return ActionSpec(title: "Testar", icon: "bolt.horizontal.fill", busy: busy, enabled: wizard.connectionReady) {
                Task { await wizard.testSSH() }
            }
        case .check:
            return ActionSpec(title: "Continuar", icon: "arrow.right", enabled: wizard.detect?.supported == true) { advance(.prepare) }
        case .prepare:
            if wizard.prepared { return ActionSpec(title: "Continuar", icon: "arrow.right", busy: busy) { advance(.done) } }
            return ActionSpec(title: "Preparar", icon: "wrench.and.screwdriver.fill", busy: busy, enabled: wizard.canPrepare) {
                Task { await wizard.prepare() }
            }
        case .done:
            return ActionSpec(title: "Adicionar", icon: "plus", busy: busy, enabled: wizard.environment(taken: []) != nil) {
                Task {
                    if await wizard.finish(into: model) {
                        wizard.reset()
                        navigator.section = .dashboard
                    }
                }
            }
        }
    }

    private func advance(_ step: WizardModel.Step) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { wizard.step = step }
        guard step == .check else { return }
        wizardRevealed = 0
        Task {
            for i in 1...9 {
                try? await Task.sleep(nanoseconds: 110_000_000)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { wizardRevealed = i }
            }
        }
    }

    // MARK: Modal (secrets)

    private var modal: some View {
        ZStack {
            Color.black.opacity(0.5)
            // A password asked while the editor is open (saving a root-owned file) goes on top of it.
            if let request = model.editor {
                RemoteEditor(model: model, request: request).opacity(model.passwordRequest == nil ? 1 : 0.25)
            }
            if model.passwordRequest != nil || model.credentialRequest != nil { secretCard }
        }
        .frame(width: panel.width, height: panel.height)
        .transition(.opacity)
    }

    private var secretCard: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                if let request = model.passwordRequest {
                    SecretPrompt(title: request.title, message: request.message, fields: [("Senha do Linux", true)],
                                 saveLabel: "Guardar no Keychain deste Mac", confirm: "Continuar") { values, save in
                        request.answer(values.first, save)
                    } onCancel: { request.answer(nil, false) }
                } else if let target = model.credentialRequest {
                    SecretPrompt(title: "Credencial RDP · " + target.title,
                                 message: "Digite a credencial RDP já existente deste destino. Ela fica só no Keychain deste Mac, com acesso limitado a este app.",
                                 fields: [("Usuário RDP", false), ("Senha RDP", true)], saveLabel: nil, confirm: "Guardar e conectar") { values, _ in
                        Task { await model.saveCredential(Credential(username: values[0], password: values[1]), for: target) }
                    } onCancel: { model.credentialRequest = nil }
                }
            }
            .padding(22)
            .frame(width: 420)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
    }
}

/// Edits a text file of the host in place. Saving keeps the first original as <name>.homelab-bak.
struct RemoteEditor: View {
    @ObservedObject var model: Model
    var request: Model.EditorRequest
    @State private var text = ""
    @State private var original = ""
    @State private var info: FileContent?
    @State private var working = true
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(request.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            if let error = info?.error, info?.ok == false {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Neon.amber).font(.system(size: 13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.45)))
                    .disabled(working || info == nil)
            }
            HStack(spacing: 10) {
                Text(message ?? footnote).font(.system(size: 11)).foregroundStyle(message == nil ? Color.white.opacity(0.55) : Neon.amber)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Fechar") { model.editor = nil }.buttonStyle(NeonButtonStyle(primary: false)).keyboardShortcut(.cancelAction)
                Button("Desfazer") { text = original }.buttonStyle(NeonButtonStyle(primary: false)).disabled(text == original || working)
                Button("Salvar") { Task { await save() } }.buttonStyle(NeonButtonStyle())
                    .disabled(text == original || working || info?.ok != true).keyboardShortcut("s")
            }
        }
        .padding(20)
        .frame(width: 820, height: 500)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .task(id: request.path) { await load() }
    }

    private var footnote: String {
        var parts: [String] = []
        if info?.writable == false { parts.append("Arquivo de outro dono: salvar usa sudo.") }
        parts.append(info?.backup == true ? "O original está guardado em .homelab-bak." : "O primeiro salvamento guarda o original em .homelab-bak.")
        if request.reload != nil { parts.append("Depois de salvar, o systemd relê as unidades; reinicie o serviço para valer.") }
        return parts.joined(separator: " ")
    }

    private func load() async {
        working = true
        let result: FileContent? = await model.privileged("Ler \((request.path as NSString).lastPathComponent)", command: "file-read",
                                                          parameters: ["path": request.path], timeout: 30) { $0.auth != false }
        info = result ?? FileContent(ok: false, path: request.path, error: "o host não respondeu")
        text = result?.content ?? ""
        original = text
        working = false
    }

    private func save() async {
        working = true
        message = nil
        var params: [String: Any] = ["path": request.path, "content": text]
        if let reload = request.reload { params["reload"] = reload }
        let result: ActionResult? = await model.privileged("Salvar \((request.path as NSString).lastPathComponent)", command: "file-write",
                                                           parameters: params, timeout: 40) { $0.auth }
        working = false
        if result?.ok == true {
            original = text
            info?.backup = true
            message = "Salvo."
        } else if result != nil {
            message = "Não foi possível salvar" + ((result?.output).map { $0.isEmpty ? "." : ": " + $0 } ?? ".")
        }
    }
}

struct SecretPrompt: View {
    var title: String
    var message: String
    var fields: [(label: String, secure: Bool)]
    var saveLabel: String?
    var confirm: String
    var onConfirm: ([String], Bool) -> Void
    var onCancel: () -> Void
    @State private var values: [String] = ["", ""]
    @State private var save = true

    private var valid: Bool {
        fields.indices.allSatisfy { !values[$0].isEmpty && values[$0].utf8.count < 512 && !values[$0].contains { $0.isNewline } }
    }

    var body: some View {
        Label(title, systemImage: "lock.shield.fill").font(.system(size: 16, weight: .semibold))
        Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
        ForEach(fields.indices, id: \.self) { index in
            NeonField(label: fields[index].label, prompt: "", text: $values[index], secure: fields[index].secure,
                      icon: fields[index].secure ? "lock" : "person")
        }
        if let saveLabel { Toggle(saveLabel, isOn: $save).toggleStyle(.switch).font(.system(size: 12)) }
        HStack {
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(NeonButtonStyle(primary: false)).keyboardShortcut(.cancelAction)
            Button(confirm) { onConfirm(Array(values.prefix(fields.count)), save) }
                .buttonStyle(NeonButtonStyle()).disabled(!valid)
        }
    }
}

struct SectionHeader: View {
    var kicker = ""
    var title: String
    var subtitle = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !kicker.isEmpty {
                Text(kicker.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(1.8).foregroundStyle(.tint)
            }
            Text(title).font(.system(size: 31, weight: .bold, design: .rounded))
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Dashboard

/// One of the overview's shortcuts: a small glass sphere with a verb and what it will act on.
struct QuickOrb: View {
    var icon: String
    var title: String
    var detail: String
    var theme: Theme
    var enabled = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { QuickOrbLabel(icon: icon, title: title, detail: detail, theme: theme, hovering: hovering && enabled) }
            .buttonStyle(OrbPressStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            .saturation(enabled ? 1 : 0.25)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .accessibilityLabel(title + ", " + detail)
    }
}

struct QuickOrbLabel: View {
    var icon: String
    var title: String
    var detail: String
    var theme: Theme
    var hovering: Bool

    var body: some View {
        VStack(spacing: 5) {
            GlassSphere(theme: theme, diameter: 46, bright: hovering) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
            .scaleEffect(hovering ? 1.1 : 1)
            VStack(spacing: 0) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct DashboardSection: View {
    @ObservedObject var model: Model
    var theme: Theme
    /// Jumps to another section; for Services, optionally to a tab and a sort order.
    var open: (MainSection, ServiceCenter.Tab?, Bool) -> Void
    private let slow = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    private var metrics: HostMetrics? { model.status?.metrics }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                SectionHeader(kicker: model.env.name, title: "Visão geral")
                Spacer()
                Text(model.lastUpdate.map { "Atualizado " + $0.formatted(date: .omitted, time: .standard) } ?? "Verificando…")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
            }
            HStack(spacing: 14) {
                health.frame(width: 310)
                VStack(spacing: 12) {
                    HStack(spacing: 12) { cpu; memory }
                    HStack(spacing: 12) { gpu; network }
                }
            }
            .frame(height: 168)
            quickActions.frame(height: 92)
            HStack(spacing: 14) {
                access.frame(width: 296)
                disksCard
                systemCard.frame(width: 268)
                services.frame(width: 172)
            }
            .frame(height: 156)
        }
        .task { await model.refreshSystem() }
        .onReceive(slow) { _ in Task { await model.refreshSystem() } }
    }

    private var concerns: [String] {
        guard model.online else { return ["Host fora de alcance"] }
        var list: [String] = []
        for disk in metrics?.disks ?? [] where disk.percent >= 90 {
            list.append("Disco \(disk.mount) em \(Int(disk.percent))%")
        }
        let failed = (metrics?.services ?? []).filter { $0.active == "failed" }.count
        if failed > 0 { list.append("\(failed) serviço(s) com falha") }
        if let temp = metrics?.cpuTemp, temp >= 85 { list.append(String(format: "CPU a %.0f °C", temp)) }
        if model.status?.lockedKeyrings.isEmpty == false { list.append("Cofre trancado") }
        if model.status?.remoteDesktopActive == false { list.append("Compartilhamento parado") }
        if model.system?.rebootRequired == true { list.append("Reinício pendente") }
        return list
    }

    // MARK: Health and metrics

    private var health: some View {
        let issues = concerns
        let state: (String, Color) = !model.checkedOnce ? ("…", .white) : (!model.online ? ("Offline", Neon.red)
            : (issues.isEmpty ? ("Boa", theme.accent) : ("Atenção", Neon.amber)))
        let disk = model.selectedDisk
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saúde do host").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    Text(state.0).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(state.1)
                    Text(model.status.map { "\($0.hostname) · há \(formatUptime($0.uptimeSeconds))" } ?? model.env.name)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    ForEach(issues.prefix(2), id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Neon.amber).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                ZStack {
                    RingGauge(fraction: (metrics?.cpuPercent ?? 0) / 100, theme: theme)
                    HeroObject(name: "hero-dashboard", symbol: "server.rack", theme: theme, size: 60)
                }
                .frame(width: 84, height: 84)
            }
            Spacer(minLength: 0)
            if let disk {
                HStack(spacing: 6) {
                    Text("Disco " + disk.mount).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.head)
                    if model.disks.count > 1 {
                        Button { model.cycleDisk() } label: { Image(systemName: "arrow.left.arrow.right.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75)).help("Trocar de disco")
                    }
                    Spacer()
                    Text(String(format: "%.0f de %.0f GB", disk.usedGB, disk.totalGB)).font(.system(size: 11, weight: .medium))
                        .monospacedDigit().foregroundStyle(.white.opacity(0.75))
                }
                MeterBar(fraction: disk.percent / 100, color: loadColor(disk.percent, calm: theme.accent))
            }
        }
        .pane(16)
    }

    /// A metric with its recent history; a click opens the place where it can be acted on.
    private func tile(_ title: String, _ value: String, _ note: String, history: [Double], ceiling: Double?,
                      help: String, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(note).font(.system(size: 11)).foregroundStyle(theme.accent).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)
            Sparkline(values: history, ceiling: ceiling, color: theme.accent).frame(width: 124, height: 44)
            if action != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4)) }
        }
        .pane(13)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }

    private var cpu: some View {
        let notes = [metrics?.cpuTemp.map { String(format: "%.0f °C", $0) },
                     metrics?.loads?.first.map { String(format: "carga %.2f", $0) }].compactMap { $0 }
        return tile("CPU", String(format: "%.0f%%", metrics?.cpuPercent ?? 0), notes.joined(separator: " · "),
                    history: model.history.cpu, ceiling: 100, help: "Ver os processos que mais usam CPU") { open(.services, .processes, false) }
    }

    private var memory: some View {
        let used = metrics?.memUsedMB ?? 0, total = metrics?.memTotalMB ?? 0
        return tile("Memória", "\(formatGB(used)) GB", "de \(formatGB(total)) GB", history: model.history.memory, ceiling: 100,
                    help: "Ver os processos que mais usam memória") { open(.services, .processes, true) }
    }

    private var gpu: some View {
        let gpu = metrics?.gpu
        let note = gpu.map { "VRAM \(formatGB($0.memUsedMB)) / \(formatGB($0.memTotalMB)) GB" + ($0.temp.map { String(format: " · %.0f °C", $0) } ?? "") }
        return tile(gpu.map { "GPU · " + $0.name } ?? "GPU", gpu.map { String(format: "%.0f%%", $0.util) } ?? "—", note ?? "indisponível",
                    history: model.history.gpu, ceiling: 100, help: "Uso da placa de vídeo")
    }

    private var network: some View {
        tile("Rede", "↓ " + formatRate(metrics?.rxKbps ?? 0), "↑ " + formatRate(metrics?.txKbps ?? 0)
             + (model.link.map { " · \($0.direct ? "direto" : "relay") \($0.milliseconds) ms" } ?? ""),
             history: model.history.download, ceiling: nil, help: "Tráfego das interfaces físicas do host")
    }

    // MARK: Quick actions

    private var quickActions: some View {
        let locked = model.status?.lockedKeyrings.count ?? 0
        let failed = model.system?.failedUnits ?? 0
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
            QuickOrb(icon: "memorychip.fill", title: "Cache",
                        detail: model.system?.cacheMB.map { "liberar " + formatGB($0) + " GB" } ?? "liberar", theme: theme, enabled: !busy) {
                Task { await model.systemAction("drop-caches", label: "Liberar cache") }
            }
            QuickOrb(icon: "eraser.fill", title: "Falhas", detail: failed > 0 ? "limpar \(failed)" : "nenhuma", theme: theme,
                        enabled: failed > 0 && !busy) { Task { await model.systemAction("reset-failed", label: "Limpar falhas") } }
            QuickOrb(icon: "shippingbox.fill", title: "Docker", detail: "limpar sobras", theme: theme, enabled: !busy) {
                if confirmAlert("Limpar o Docker em \(model.env.name)?",
                                "Remove imagens sem etiqueta e o cache de build. Containers, volumes e imagens em uso ficam.", button: "Limpar") {
                    Task { await model.systemAction("docker-prune", label: "Limpar Docker") }
                }
            }
            QuickOrb(icon: "arrow.triangle.2.circlepath", title: "RDP", detail: "reiniciar", theme: theme, enabled: !busy) {
                if confirmAlert("Reiniciar o compartilhamento de tela?",
                                "A sessão RDP aberta cai e pode ser reconectada em seguida.", button: "Reiniciar") {
                    Task { await model.systemAction("restart-sharing", label: "Reiniciar compartilhamento") }
                }
            }
            Menu {
                Button("Suspender…") {
                    if confirmAlert("Suspender \(model.env.name)?", "O host dorme e some da rede até alguém acordá-lo nele mesmo.", button: "Suspender") {
                        Task { await model.systemAction("suspend", label: "Suspender") }
                    }
                }
                ForEach(AdminAction.presets.filter { $0.id == "reboot" || $0.id == "poweroff" }) { action in
                    Button(action.title + "…") {
                        if confirmAlert(action.title, action.confirm ?? "", button: "Executar") { Task { await model.runAdmin(action) } }
                    }
                }
            } label: {
                QuickOrbLabel(icon: "power", title: "Energia", detail: "desligar…", theme: MainSection.security.theme, hovering: false)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(busy)
        }
        .padding(.horizontal, 6)
    }

    // MARK: Lower row

    private var access: some View {
        let status = model.status
        var monitors = status?.physicalMonitors.map { "\($0.name) \($0.width)×\($0.height)" } ?? []
        if monitors.isEmpty { monitors.append("sem monitor físico") }
        monitors += (status?.monitors.filter(\.virtual) ?? []).map { "virtual \($0.width)×\($0.height)" }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Acesso remoto").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            FlowLayout(spacing: 5) {
                Chip(text: "Sessão \(model.env.sessionPort)", state: model.ports["session"])
                if let login = model.env.loginPort { Chip(text: "Login \(login)", state: model.ports["login"]) }
                Chip(text: "SSH", state: model.checkedOnce ? model.sshAlias != nil : nil)
                if model.env.lanHost != nil { Chip(text: "SMB", state: model.ports["smb"]) }
            }
            Label(monitors.joined(separator: " · "), systemImage: "display").lineLimit(1)
            Label(status.map { $0.rdpClients == 0 ? "nenhum cliente RDP" : "\($0.rdpClients) cliente(s) RDP" } ?? "—", systemImage: "person.2")
            Label([metrics?.lanIP, metrics?.tailscaleIP].compactMap { $0 }.joined(separator: " · "), systemImage: "network")
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).textSelection(.enabled)
        }
        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
        .pane(14)
    }

    /// Every disk of the host. A click makes it the one the health card and the menu bar follow;
    /// the folder opens it in Arquivos.
    private var disksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discos").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            ForEach(model.disks.prefix(3)) { disk in
                let selected = disk.mount == model.selectedDisk?.mount
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(disk.mount).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f%% · %.0f GB livres", disk.percent, disk.totalGB - disk.usedGB))
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Button {
                            model.setFileRoot(disk.mount)
                            open(.files, nil, false)
                        } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Abrir em Arquivos")
                    }
                    MeterBar(fraction: disk.percent / 100, color: loadColor(disk.percent, calm: theme.accent))
                }
                .contentShape(Rectangle())
                .onTapGesture { model.diskMount = disk.mount }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if model.disks.isEmpty { Text("—").foregroundStyle(.white.opacity(0.5)) }
        }
        .pane(14)
    }

    private var systemCard: some View {
        let system = model.system
        return VStack(alignment: .leading, spacing: 9) {
            Text("Sistema").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Atualizações").font(.system(size: 12, weight: .semibold))
                    Text(system?.updatesText ?? "verificando…").font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle((system?.securityUpdates ?? 0) > 0 ? Neon.amber : Color.white.opacity(0.65))
                }
                Spacer(minLength: 4)
                Button("Instalar") {
                    if let action = AdminAction.presets.first(where: { $0.id == "apt-upgrade" }),
                       confirmAlert(action.title, action.confirm ?? "", button: "Instalar") { Task { await model.runAdmin(action); await model.refreshSystem() } }
                }
                .buttonStyle(GlassButtonStyle()).disabled((system?.updates ?? 0) == 0 || model.busyAction != nil)
            }
            if let profiles = system?.powerProfiles, !profiles.isEmpty {
                HStack {
                    Text("Energia").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Picker("Perfil de energia", selection: Binding(
                        get: { system?.powerProfile ?? "" },
                        set: { profile in Task { await model.systemAction("power-profile", label: "Perfil \(powerProfileTitle(profile).lowercased())", extra: ["profile": profile]) } })) {
                        ForEach(profiles, id: \.self) { Text(powerProfileTitle($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize().disabled(model.busyAction != nil)
                }
            }
            if system?.rebootRequired == true {
                Label("Reinício pendente", systemImage: "arrow.clockwise.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Neon.amber)
            } else if let sessions = system?.sessions {
                Label("\(sessions) sessão(ões) de login abertas", systemImage: "person.crop.circle").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }
            if let busy = model.busyAction {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(busy + "…").font(.system(size: 10.5)).lineLimit(1) }
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .pane(14)
    }

    private var services: some View {
        let list = metrics?.services ?? []
        let running = list.filter { $0.active == "active" }.count, failed = list.filter { $0.active == "failed" }.count
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Serviços").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            }
            Text("\(running) ativos").font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(failed > 0 ? "\(failed) com falha" : "nenhuma falha").font(.system(size: 11, weight: .medium))
                .foregroundStyle(failed > 0 ? Neon.amber : theme.accent)
            if let containers = metrics?.containers {
                Label("\(containers) containers", systemImage: "shippingbox").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            }
            if let busiest = metrics?.top?.first {
                Label(String(format: "%@ %.0f%%", busiest.name, busiest.cpu), systemImage: "flame")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
        }
        .pane(14)
        .contentShape(Rectangle())
        .onTapGesture { open(.services, .units, false) }
        .help("Abrir Serviços")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Connect

struct ConnectSection: View {
    @ObservedObject var model: Model
    var theme: Theme
    private let presets = ["1280x720", "1600x900", "1920x1080", "2560x1080", "2560x1440", "3440x1440"]

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(kicker: model.env.name, title: "Área de trabalho remota", subtitle: subtitle)
                VStack(spacing: 14) {
                    FeatureRow(icon: "arrow.left.arrow.right", title: "Destino", theme: theme) {
                        Picker("Destino", selection: Binding(get: { model.effectiveTarget }, set: { model.target = $0 })) {
                            ForEach(model.env.targets) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                    if model.effectiveTarget == .session {
                        FeatureRow(icon: "rectangle.on.rectangle", title: "Tela", theme: theme) {
                            Picker("Tela", selection: $model.mode) {
                                Text("Tela virtual").tag(ScreenMode.virtual)
                                if let monitor = model.mirrorSource {
                                    Text(verbatim: "Espelhar \(monitor.name) · \(monitor.width)×\(monitor.height)").tag(ScreenMode.mirror)
                                } else if model.mode == .mirror {
                                    Text("Espelhar (indisponível)").tag(ScreenMode.mirror)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    FeatureRow(icon: "macwindow", title: "Abrir em", theme: theme) {
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
                        .labelsHidden().fixedSize()
                    }
                    FeatureRow(icon: "aspectratio", title: "Resolução", theme: theme) {
                        HStack {
                            if model.sizeTag == "custom" && model.effectiveMode == .virtual && !model.usesAllDisplays {
                                TextField("1920x1080", text: $model.customSize).textFieldStyle(.roundedBorder).frame(width: 96)
                            }
                            Picker("Resolução", selection: $model.sizeTag) {
                                Text(fitLabel).tag("fit")
                                Text("Tela cheia").tag("full")
                                if model.effectiveMode == .virtual {
                                    Divider()
                                    ForEach(presets, id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                                    Text("Outra…").tag("custom")
                                }
                            }
                            .labelsHidden().fixedSize().disabled(model.usesAllDisplays)
                        }
                    }
                    FeatureRow(icon: "doc.on.clipboard", title: "Área de transferência", theme: theme) {
                        Toggle("Área de transferência", isOn: $model.clipboard).toggleStyle(.switch).labelsHidden()
                    }
                }
                .pane(18).fixedSize(horizontal: false, vertical: true)
                .disabled(model.phase != .idle)
                if model.phase == .connected {
                    Label("Sessão aberta", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Neon.green)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 580)
            VStack(spacing: 0) {
                Spacer().frame(height: 158)
                preview
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onChange(of: model.effectiveMode) { newMode in
            if newMode == .mirror && model.sizeTag != "full" { model.sizeTag = "fit" }
        }
    }

    /// The screens the host will show, drawn to scale.
    private var plannedScreens: [(size: PixelSize, label: String)] {
        if model.effectiveMode == .mirror, let monitor = model.mirrorSource { return [(monitor.size, monitor.name)] }
        if model.usesAllDisplays { return model.displays.map { ($0.size, $0.name) } }
        guard let display = model.selectedDisplay else { return [] }
        switch model.sizeChoice {
        case .fullscreen: return [(display.size, display.name)]
        case .fixed(let size): return [(size.even, "tela virtual")]
        default: return [(display.usable.even, display.name)]
        }
    }

    private var preview: some View {
        let screens = plannedScreens
        let total = max(1, screens.reduce(0) { $0 + $1.size.width })
        let tallest = max(1, screens.map(\.size.height).max() ?? 1)
        let scale = min(300.0 / Double(total), 120.0 / Double(tallest))
        return VStack(alignment: .leading, spacing: 10) {
            Text(model.effectiveMode == .mirror ? "ESPELHO DO MONITOR DO HOST" : (screens.count > 1 ? "TELAS VIRTUAIS NO HOST" : "TELA VIRTUAL NO HOST"))
                .font(.system(size: 10, weight: .semibold)).kerning(1.2).foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(screens.enumerated()), id: \.offset) { _, screen in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [theme.accent.opacity(0.35), theme.glow.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.accent.opacity(0.8), lineWidth: 1))
                        .overlay(Text(verbatim: "\(screen.size.width)×\(screen.size.height)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .minimumScaleFactor(0.6).lineLimit(1).padding(4))
                        .frame(width: max(40, Double(screen.size.width) * scale), height: max(26, Double(screen.size.height) * scale))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: screens.map(\.size))
            Text(screens.map(\.label).joined(separator: " + ")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .pane(16)
        .frame(width: 340, height: 214)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if model.effectiveTarget == .login { return "Abre o login do GNOME em uma sessão separada, com credencial RDP própria." }
        if model.effectiveMode == .mirror { return "Mostra o que está no monitor físico do host, na resolução dele." }
        if model.usesAllDisplays { return "Tela cheia em todos os monitores do Mac: o host cria uma tela virtual para cada um." }
        return "O host cria uma tela virtual na resolução escolhida. Funciona com ou sem monitor ligado nele."
    }

    private var fitLabel: String {
        if model.effectiveMode == .mirror, let monitor = model.mirrorSource {
            return "Tamanho do host · \(monitor.width)×\(monitor.height)"
        }
        guard let display = model.selectedDisplay else { return "Ajustar ao monitor" }
        return "Ajustar ao monitor · \(display.usable.even.width)×\(display.usable.even.height)"
    }
}

// MARK: - Files

struct FilesSection: View {
    @ObservedObject var model: Model
    var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                SectionHeader(kicker: model.env.name, title: "Arquivos")
                Spacer()
                if let share = model.env.smbURL.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(share) } label: { Label("Abrir no Finder", systemImage: "folder") }
                        .buttonStyle(GlassButtonStyle()).disabled(model.ports["smb"] != true)
                }
                Button {
                    if let url = model.sshAlias.flatMap({ URL(string: "ssh://" + $0) }) { NSWorkspace.shared.open(url) }
                } label: { Label("Terminal", systemImage: "terminal") }
                .buttonStyle(GlassButtonStyle()).disabled(model.sshAlias == nil)
            }
            HStack(spacing: 10) {
                Button { model.fileRootUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(model.fileRoot == "/" || model.fileRoot.isEmpty).help("Pasta acima")
                Button { if let home = model.status?.home { model.setFileRoot(home) } } label: { Image(systemName: "house") }.help("Pasta pessoal")
                Button { model.setFileRoot("/") } label: { Image(systemName: "externaldrive") }.help("Raiz do sistema")
                Text(model.fileRoot.isEmpty ? "—" : model.fileRoot).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                    .truncationMode(.head).textSelection(.enabled)
                Spacer()
                if !model.loadingFolders.isEmpty { ProgressView().controlSize(.small) }
                Toggle(isOn: $model.showHidden) { Image(systemName: "eye") }.toggleStyle(.button).help("Mostrar arquivos ocultos")
                Button { model.reloadFiles() } label: { Image(systemName: "arrow.clockwise") }.help("Recarregar")
            }
            .buttonStyle(GlassButtonStyle())
            tree.pane(8)
        }
        .onAppear { if model.listings[model.fileRoot] == nil { model.setFileRoot(model.fileRoot) } }
        .onChange(of: model.fileRoot) { root in if model.listings[root] == nil { model.setFileRoot(root) } }
    }

    private var tree: some View {
        let rows = model.visibleFileRows, root = model.listings[model.fileRoot]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = root?.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Neon.amber).padding(10)
                } else if root != nil && rows.isEmpty {
                    Text("Pasta vazia").foregroundStyle(.white.opacity(0.6)).padding(10)
                } else if root == nil {
                    Text(model.sshAlias == nil ? "Sem SSH: a árvore precisa do host online." : "Carregando…")
                        .foregroundStyle(.white.opacity(0.6)).padding(10)
                }
                ForEach(rows) { row in fileRow(row) }
                if root?.truncated == true {
                    Text("Lista cortada: pasta com muitos itens.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(10)
                }
            }
        }
        .font(.system(size: 13))
    }

    private func fileRow(_ row: FileRow) -> some View {
        let open = model.expandedFolders.contains(row.path)
        let failed = open ? model.listings[row.path]?.error : nil
        return HStack(spacing: 7) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                .rotationEffect(.degrees(open ? 90 : 0)).opacity(row.entry.dir ? 1 : 0).frame(width: 12)
            Image(systemName: row.entry.dir ? "folder.fill" : (row.entry.link ? "arrow.up.right.square" : "doc"))
                .foregroundStyle(row.entry.dir ? theme.accent : Color.white.opacity(0.7)).frame(width: 20)
            Text(row.entry.name).lineLimit(1).truncationMode(.middle)
            if let failed { Text(failed).font(.system(size: 11)).foregroundStyle(Neon.amber).lineLimit(1) }
            Spacer(minLength: 8)
            if model.loadingFolders.contains(row.path) {
                ProgressView().controlSize(.mini)
            } else if !row.entry.dir {
                Text(formatBytes(row.entry.size)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                Button { Task { await model.download(row) } } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Baixar para Downloads")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 18 + 8).padding(.trailing, 10).padding(.vertical, 5)
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
}

// MARK: - Security

struct SecuritySection: View {
    @ObservedObject var model: Model
    var theme: Theme
    @State private var command = ""

    var body: some View {
        let status = model.status
        let locked = status?.lockedKeyrings ?? []
        return HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(kicker: model.env.name, title: "Segurança", subtitle: status?.sudoNeedsPassword == false
                              ? "Autentique o host daqui, sem tocar na tela dele. Este host não pede senha para sudo."
                              : "Autentique o host daqui, sem tocar na tela dele. A senha do Linux é pedida uma vez e pode ficar no Keychain.")
                VStack(spacing: 13) {
                    FeatureRow(icon: status?.locked == true ? "lock.fill" : "lock.open.fill", title: "Tela",
                               detail: status?.locked == true ? "bloqueada" : "desbloqueada", theme: theme, warn: status?.locked == true) {
                        Button("Desbloquear") { Task { await model.unlockScreen() } }.disabled(status?.locked != true)
                    }
                    FeatureRow(icon: "key.fill", title: "Cofres do GNOME",
                               detail: locked.isEmpty ? "todos abertos" : locked.map(\.label).joined(separator: ", ") + " trancado",
                               theme: theme, warn: !locked.isEmpty) {
                        Button("Destrancar") { Task { await model.unlockKeyrings() } }.disabled(locked.isEmpty)
                    }
                    FeatureRow(icon: "person.badge.shield.checkmark.fill", title: "Diálogos de administrador",
                               detail: status?.polkitOpen == true ? "liberados sem senha" : "pedem senha na tela do host", theme: theme) {
                        if status?.polkitOpen == true {
                            Button("Voltar a pedir") { Task { await model.setPolkit(false) } }
                        } else {
                            Button("Liberar…") {
                                if confirmAlert("Liberar diálogos de administrador em \(model.env.name)?",
                                                "Instala uma regra polkit no host: pedidos de administrador feitos pelo seu usuário passam sem diálogo de senha. Qualquer programa rodando como você ganha esse poder. Dá para desfazer aqui mesmo.",
                                                button: "Liberar") { Task { await model.setPolkit(true) } }
                            }
                        }
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .pane(16).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("COMO ADMINISTRADOR").font(.system(size: 10, weight: .semibold)).kerning(1.2).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        if let busy = model.busyAction {
                            ProgressView().controlSize(.mini)
                            Text(busy + "…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(AdminAction.presets) { action in
                            Button {
                                if let question = action.confirm, !confirmAlert(action.title, question, button: "Executar") { return }
                                Task { await model.runAdmin(action) }
                            } label: {
                                Text(action.title).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .help("sudo " + action.argv.joined(separator: " "))
                        }
                    }
                    .buttonStyle(GlassButtonStyle(shape: 11))
                    HStack(spacing: 8) {
                        TextField("sudo: comando personalizado", text: $command).textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.3)))
                            .onSubmit(runCommand)
                        Button("Executar", action: runCommand).buttonStyle(GlassButtonStyle())
                            .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .pane(16).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(width: 620)
            .disabled(model.busyAction != nil && model.passwordRequest == nil)
            VStack(spacing: 12) {
                Spacer().frame(height: 146)
                VStack(alignment: .leading, spacing: 8) {
                    Text("COMO O HOST AUTENTICA").font(.system(size: 10, weight: .semibold)).kerning(1.2).foregroundStyle(.white.opacity(0.5))
                    Label(status?.sudoNeedsPassword == false ? "sudo não pede senha" : "sudo pede a senha do Linux", systemImage: "terminal")
                    Label(status?.polkitOpen == true ? "diálogos de admin liberados" : "diálogos de admin pedem senha", systemImage: "person.badge.shield.checkmark")
                    Label("\(status?.keyrings?.count ?? 0) cofre(s), \(locked.count) trancado(s)", systemImage: "key")
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                .pane(14).frame(width: 340).fixedSize(horizontal: false, vertical: true)
                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        Text(model.actionOutput ?? "A saída dos comandos de administrador aparece aqui.")
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(.white.opacity(model.actionOutput == nil ? 0.45 : 0.9))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    if model.actionOutput != nil {
                        Button { model.actionOutput = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).padding(6).help("Limpar saída")
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35)))
                .frame(width: 340)
                .padding(.bottom, 50)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func runCommand() {
        let text = command
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
              confirmAlert("Executar como administrador?", "sudo sh -c '\(text)' em \(model.env.name).", button: "Executar") else { return }
        command = ""
        Task { await model.runAdminShell(text) }
    }
}

// MARK: - Setup (new environment)

struct SetupSection: View {
    @ObservedObject var wizard: WizardModel
    @ObservedObject var model: Model
    var theme: Theme
    @Binding var revealed: Int

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(WizardModel.Step.allCases, id: \.rawValue) { step in
                        Capsule().fill(step.rawValue <= wizard.step.rawValue ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.white.opacity(0.18)))
                            .frame(width: step == wizard.step ? 44 : 18, height: 5)
                    }
                    Spacer()
                    if wizard.step != .connection {
                        Button("Voltar") {
                            withAnimation { wizard.step = WizardModel.Step(rawValue: wizard.step.rawValue - 1) ?? .connection }
                        }
                        .buttonStyle(GlassButtonStyle()).disabled(wizard.busy != nil)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: wizard.step)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Etapa \(wizard.step.rawValue + 1) de 4: \(wizard.step.title)")
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        switch wizard.step {
                        case .connection: connection
                        case .check: check
                        case .prepare: prepare
                        case .done: done
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(wizard.step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                }
                if let busy = wizard.busy {
                    Text(busy + "…").font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.accent)
                }
            }
            .frame(width: 600)
            VStack(spacing: 0) {
                Spacer().frame(height: 158)
                VStack(spacing: 12) {
                    Text("LIGAÇÃO").font(.system(size: 10, weight: .semibold)).kerning(1.2).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LinkDiagram(state: linkState, hostName: hostLabel)
                    if wizard.step == .done { SuccessBurst().scaleEffect(0.6).frame(height: 48) }
                }
                .pane(16).frame(width: 340, height: wizard.step == .done ? 210 : 150)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var linkState: LinkDiagram.State {
        if case .failed = wizard.sshState { return .failed }
        if wizard.sshState == .testing || wizard.busy != nil { return .linking }
        return wizard.sshState == .ok ? .linked : .idle
    }

    private var hostLabel: String {
        wizard.detect?.hostname ?? (wizard.target.isEmpty ? "novo host" : (wizard.target.split(separator: "@").last.map(String.init) ?? wizard.target))
    }

    private func status(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var connection: some View {
        Group {
            SectionHeader(title: "Novo ambiente", subtitle: "O app fala com o host por SSH, com a chave deste Mac. Use usuario@endereço ou um alias do seu ~/.ssh/config.")
            NeonField(label: "Nome do ambiente", prompt: "Estúdio, Escritório…", text: $wizard.name, icon: "tag")
            NeonField(label: "Destino SSH", prompt: "usuario@host.tailnet.ts.net", text: $wizard.sshTarget, icon: "terminal")
                .onChange(of: wizard.sshTarget) { _ in wizard.sshState = .idle }
            if !wizard.target.isEmpty && !validSSHTarget(wizard.target) {
                status("Destino inválido: use só usuario@host, um IP ou um alias.", "exclamationmark.triangle.fill", Neon.amber)
            } else {
                switch wizard.sshState {
                case .idle: EmptyView()
                case .testing: status("Abrindo canal SSH…", "dot.radiowaves.left.and.right", theme.accent)
                case .ok: status("Ligado com a chave deste Mac. Pronto para escanear.", "checkmark.circle.fill", Neon.green)
                case .failed(let reason): status(reason, "exclamationmark.triangle.fill", Neon.amber)
                }
            }
            if case .failed = wizard.sshState {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Instalar a chave SSH deste Mac no host", systemImage: "key.horizontal.fill").font(.system(size: 13, weight: .semibold))
                    Text("Digite uma vez a senha do seu usuário no Linux. O app cria a chave se ela não existir e a acrescenta ao authorized_keys do host.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .bottom, spacing: 10) {
                        NeonField(label: "Senha do Linux", prompt: "usada só agora", text: $wizard.linuxPassword, secure: true, icon: "lock")
                        Button("Instalar chave") { Task { await wizard.installKey() } }.buttonStyle(GlassButtonStyle())
                            .disabled(wizard.linuxPassword.isEmpty || !wizard.connectionReady || wizard.busy != nil)
                    }
                }
                .pane(14)
            }
            Text("Na primeira conexão a chave do host é registrada no known_hosts. Nada é alterado no host antes da etapa Preparação.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finding(_ index: Int, _ ok: Bool?, _ title: String, _ detail: String) -> some View {
        let color = ok == nil ? Color.white.opacity(0.45) : (ok == true ? Neon.green : Neon.amber)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok == nil ? "circle.dotted" : (ok == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(color).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .semibold)).frame(width: 150, alignment: .leading)
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .opacity(revealed >= index ? 1 : 0).offset(x: revealed >= index ? 0 : -14)
        .accessibilityElement(children: .combine)
    }

    private var check: some View {
        Group {
            SectionHeader(title: "Raio-x do host", subtitle: "Leitura feita por SSH. Nada foi alterado.")
            if let d = wizard.detect {
                VStack(alignment: .leading, spacing: 9) {
                    finding(1, true, "Máquina", "\(d.user)@\(d.hostname)" + (d.osName.map { " · " + $0 } ?? ""))
                    finding(2, d.supported, "Ambiente gráfico", d.supported ? (d.desktop ?? "") : "GNOME não encontrado")
                    finding(3, d.graphicalSession, "Sessão aberta", d.graphicalSession == true ? "há uma sessão para compartilhar" : "nenhuma agora; ative o login automático")
                    finding(4, d.hasGrd, "Remote Desktop", d.hasGrd == true ? "instalado" : "falta instalar (o assistente instala)")
                    finding(5, d.rdp?.enabled == true && d.rdp?.hasCredentials == true, "Compartilhamento",
                            d.rdp?.enabled == true ? "ligado na porta \(d.rdp?.port ?? 0)" + (d.rdp?.hasCredentials == true ? "" : ", sem credencial") : "desligado (o assistente liga)")
                    finding(6, d.loginRdp != nil ? true : nil, "Login remoto", d.loginRdp.map { "ligado na porta \($0.port ?? 0)" } ?? "não configurado; só a sessão atual")
                    finding(7, d.tailscaleName != nil ? true : nil, "Tailscale", d.tailscaleName ?? "ausente; usará \(d.lanIP ?? "o endereço local"), só na mesma rede")
                    finding(8, true, "sudo", d.sudoNeedsPassword == true ? "pede senha" : "não pede senha")
                    finding(9, d.packageInstalled == true ? true : nil, "Pacote homelab-host", d.packageInstalled == true ? "instalado" : "não instalado (opcional)")
                }
                .pane(14)
                if !d.supported {
                    status("Este host não usa GNOME. O compartilhamento de tela depende do GNOME Remote Desktop, então não dá para continuar aqui.", "xmark.octagon.fill", Neon.red)
                }
            }
        }
        .onAppear { if revealed == 0 { revealed = 99 } }
    }

    private var prepare: some View {
        Group {
            SectionHeader(title: "Preparar o host", subtitle: wizard.ready && wizard.log.isEmpty
                          ? "O host já está pronto. Você pode continuar sem mudar nada."
                          : "Liga o compartilhamento de tela com tela virtual e fixa o certificado. O que já existir é mantido.")
            if let d = wizard.detect {
                Toggle(isOn: $wizard.installPackage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instalar o pacote homelab-host (.deb)").font(.system(size: 13, weight: .semibold))
                        Text(d.needsPackages ? "Necessário: traz " + d.missing.joined(separator: ", ") + "."
                                             : "Opcional: deixa o comando homelab-host no host. Usa sudo.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    }
                }
                .toggleStyle(.switch).disabled(d.needsPackages || d.hasApt != true)
                if (d.needsPackages || wizard.installPackage) && d.sudoNeedsPassword == true {
                    NeonField(label: "Senha do Linux (sudo)", prompt: "para instalar o pacote", text: $wizard.linuxPassword, secure: true, icon: "lock")
                    Toggle("Guardar no Keychain deste Mac", isOn: $wizard.saveLinuxPassword).toggleStyle(.switch).font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(wizard.needsNewCredentials ? "Credencial RDP nova" : "Credencial RDP existente (opcional)", systemImage: "person.badge.key.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(wizard.needsNewCredentials
                         ? "Escolha um usuário e uma senha só para o acesso remoto. Ficam no host e no Keychain deste Mac."
                         : "O host já tem uma credencial. Digite-a para guardá-la no Keychain agora, ou deixe em branco: o app pede na primeira conexão.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        NeonField(label: "Usuário RDP", prompt: "usuario", text: $wizard.rdpUser, icon: "person")
                        NeonField(label: "Senha RDP", prompt: "senha", text: $wizard.rdpPassword, secure: true, icon: "lock")
                    }
                }
                .pane(14)
                if wizard.prepared && wizard.busy == nil {
                    HStack {
                        status("Host pronto.", "checkmark.seal.fill", Neon.green)
                        Spacer()
                        Button("Aplicar de novo") { Task { await wizard.prepare() } }.buttonStyle(GlassButtonStyle()).disabled(!wizard.canPrepare)
                    }
                }
                ForEach(wizard.log) { line in
                    HStack(spacing: 8) {
                        Image(systemName: line.ok ? "checkmark" : "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(line.ok ? Neon.green : Neon.red)
                        Text(line.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(line.ok ? Color.white.opacity(0.85) : Neon.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func summary(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(theme.accent).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .semibold)).frame(width: 140, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var done: some View {
        Group {
            if let environment = wizard.environment(taken: Set(model.environments.map(\.id))) {
                SectionHeader(title: "Tudo certo", subtitle: "\(environment.name) está pronto para entrar no painel. O certificado fica fixado: outro certificado, conexão recusada.")
                VStack(alignment: .leading, spacing: 10) {
                    summary("Endereço RDP", "\(environment.rdpHost):\(environment.sessionPort)", "network")
                    summary("Certificado", String(environment.sessionFingerprint.prefix(16)) + "…" + String(environment.sessionFingerprint.suffix(8)), "lock.shield")
                    summary("Login remoto", environment.loginPort.map { "porta \($0)" } ?? "não disponível neste host", "person.crop.rectangle")
                    summary("SSH", environment.sshTargets.joined(separator: ", "), "terminal")
                    summary("Finder", environment.smbURL ?? "sem compartilhamento SMB", "folder")
                    summary("Credencial RDP", wizard.credentialsTyped ? "será guardada no Keychain" : "será pedida na primeira conexão", "key")
                }
                .pane(14)
            } else {
                SectionHeader(title: "Falta o certificado", subtitle: "O host não informou um certificado RDP válido. Volte e rode a preparação.")
            }
        }
    }
}
