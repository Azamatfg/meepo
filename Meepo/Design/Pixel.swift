import SwiftUI

/// Win95-style 2 px bevel (design §5): raised = light top/left, dark bottom/right; sunken is the reverse.
struct Bevel: View {
    var raised = true
    var width: CGFloat = 2

    var body: some View {
        Canvas(renderer: Self.renderer(raised: raised, width: width))
            .allowsHitTesting(false)
    }

    /// Built outside the main actor: on macOS 15 SwiftUI calls Canvas renderers from its DisplayLink thread
    /// during animations, and a main-actor closure there traps (Rustem's crash, 2026-09-24).
    nonisolated static func renderer(raised: Bool, width: CGFloat) -> (inout GraphicsContext, CGSize) -> Void {
        { context, size in
            let (lead, trail) = raised ? (Tokens.frameLight, Tokens.frameDark) : (Tokens.frameDark, Tokens.frameLight)
            context.fill(Path(CGRect(x: 0, y: size.height - width, width: size.width, height: width)), with: .color(trail))
            context.fill(Path(CGRect(x: size.width - width, y: 0, width: width, height: size.height)), with: .color(trail))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: width)), with: .color(lead))
            context.fill(Path(CGRect(x: 0, y: 0, width: width, height: size.height)), with: .color(lead))
        }
    }
}

extension View {
    /// Window-style frame: raised outer edge, `frameMid` body, sunken inner edge. No rounding, no shadows.
    func pixelFrame(_ thickness: CGFloat = 6) -> some View {
        padding(thickness)
            .background(Tokens.frameMid)
            .overlay(Bevel(raised: true))
            .overlay(Bevel(raised: false).padding(thickness - 2))
    }

    /// Pressed-in well, e.g. around the terminal.
    func sunken() -> some View {
        overlay(Bevel(raised: false))
    }
}

/// Raised grey button that sinks when pressed.
/// Never squeezed: a narrow row overflows or scrolls instead of truncating labels into empty boxes.
struct PixelButtonStyle: ButtonStyle {
    var large = false
    /// Tight padding for tab rows.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.title(16))
            .foregroundStyle(Tokens.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, large ? 16 : compact ? 4 : 8)
            .padding(.vertical, large ? 8 : 3)
            .background(Tokens.frameMid)
            .overlay(Bevel(raised: !configuration.isPressed))
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

/// The ring under a unit (design §5). `kind` is what the session is doing; selection is drawn separately.
struct SelectionRing: View {
    enum Kind { case idle, working, waiting, sync, error }

    let kind: Kind
    @State private var pulsing = false

    var body: some View {
        Ellipse()
            .stroke(color, lineWidth: kind == .waiting ? 3 : 2)
            .opacity(pulsing ? 0.35 : 1)
            .onAppear { startPulse() }
            .onChange(of: kind) { startPulse() }
    }

    private var color: Color {
        switch kind {
        case .idle, .working: Tokens.selectionSoft
        case .waiting: Tokens.alert
        case .sync: Tokens.warn
        case .error: Tokens.danger
        }
    }

    /// Working pulses slowly, waiting fast; the rest is steady.
    private func startPulse() {
        pulsing = false
        let period: Double? = switch kind {
        case .working: 1.2
        case .waiting: 0.45
        default: nil
        }
        guard let period else { return }
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) { pulsing = true }
    }
}

/// Thick glowing ring of the selected unit; one per list, it jumps between cards on Tab (§8: 120 ms).
struct SelectedRing: View {
    var body: some View {
        Ellipse()
            .stroke(Tokens.selection, lineWidth: 4)
            .shadow(color: Tokens.selection.opacity(0.7), radius: 3)
    }
}

/// Pixel context bar (design §5): 4 px segments with 1 px gaps in a sunken well.
/// Up to 50% `selection`, up to 70% `warn`, beyond that `alert`.
struct ContextBar: View {
    /// nil = no response yet.
    let fraction: Double?

    var body: some View {
        Canvas(renderer: Self.renderer(fraction: fraction))
        .frame(height: 10)
        .background(Tokens.terminalBg)
        .sunken()
        .help(fraction.map { "Context \(Int(($0 * 100).rounded()))%" } ?? "Context: no reply yet")
    }

    /// Off the main actor for the same reason as `Bevel.renderer`.
    nonisolated static func renderer(fraction: Double?) -> (inout GraphicsContext, CGSize) -> Void {
        { context, size in
            let count = Int((size.width - 4) / 5)
            guard count > 0 else { return }
            let lit = Int((min(max(fraction ?? 0, 0), 1) * Double(count)).rounded(.up))
            for i in 0..<count {
                let rect = CGRect(x: 2 + CGFloat(i) * 5, y: 2, width: 4, height: size.height - 4)
                let share = Double(i + 1) / Double(count)
                let color = i >= lit ? Tokens.grassDeep : share <= 0.5 ? Tokens.selection : share <= 0.7 ? Tokens.warn : Tokens.alert
                context.fill(Path(rect), with: .color(color))
            }
        }
    }
}

/// Small dark plate with a number, e.g. tokens today.
struct NumberPlate: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Fonts.mono(11))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Tokens.frameDark)
            .sunken()
    }
}

/// A pending yes/no question for `pixelConfirm` — the Meepo-styled stand-in for `confirmationDialog`.
struct PixelConfirmation {
    let title: String
    var message: String?
    let action: String
    /// A second choice between CANCEL and the main action (e.g. "Run QA first").
    var alternative: (title: String, perform: () -> Void)?
    /// nil = no cancel button: a notice with just OK.
    var cancel: String? = "CANCEL"
    /// Red for destructive actions; a plain notice isn't.
    var isDestructive = true
    let perform: () -> Void
}

extension View {
    /// Shows `confirmation` as a framed box over this view. Attach at the window root so it covers the whole window.
    func pixelConfirm(_ confirmation: Binding<PixelConfirmation?>) -> some View {
        overlay {
            if let pending = confirmation.wrappedValue {
                ZStack {
                    Tokens.terminalBg.opacity(0.6)
                        .onTapGesture { confirmation.wrappedValue = nil }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(pending.title).font(Fonts.title(16)).foregroundStyle(Tokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let message = pending.message {
                            Text(message).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Spacer()
                            if let cancel = pending.cancel {
                                Button(cancel) { confirmation.wrappedValue = nil }
                                    .keyboardShortcut(.cancelAction)
                            }
                            if let alternative = pending.alternative {
                                Button(alternative.title) {
                                    confirmation.wrappedValue = nil
                                    alternative.perform()
                                }
                            }
                            Button {
                                confirmation.wrappedValue = nil
                                pending.perform()
                            } label: {
                                Text(pending.action).foregroundStyle(pending.isDestructive ? Tokens.danger : Tokens.text)
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        .buttonStyle(PixelButtonStyle())
                    }
                    .padding(16)
                    .frame(maxWidth: 460)
                    .background(Tokens.grass)
                    .pixelFrame(6)
                    .padding(12)
                }
            }
        }
    }
}
