import SwiftUI

/// Win95-style 2 px bevel (design §5): raised = light top/left, dark bottom/right; sunken is the reverse.
struct Bevel: View {
    var raised = true
    var width: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let (lead, trail) = raised ? (Tokens.frameLight, Tokens.frameDark) : (Tokens.frameDark, Tokens.frameLight)
            context.fill(Path(CGRect(x: 0, y: size.height - width, width: size.width, height: width)), with: .color(trail))
            context.fill(Path(CGRect(x: size.width - width, y: 0, width: width, height: size.height)), with: .color(trail))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: width)), with: .color(lead))
            context.fill(Path(CGRect(x: 0, y: 0, width: width, height: size.height)), with: .color(lead))
        }
        .allowsHitTesting(false)
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
struct PixelButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.title(16))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, large ? 16 : 8)
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
