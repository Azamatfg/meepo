import SwiftUI

// Paper components (Meepo 2.0). They keep their v1 names so every view switched look at once.

/// Hairline edge. `raised` draws nothing (Paper lifts with fill, not bevels); sunken is a thin inset outline —
/// the pressed stage, a well around a field.
struct Bevel: View {
    var raised = true
    var width: CGFloat = 1

    var body: some View {
        if !raised {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.line, lineWidth: width)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// A panel: surface fill, rounded, hairline border.
    func pixelFrame(_ padding: CGFloat = 6) -> some View {
        self.padding(padding)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
    }

    /// A well, e.g. around a text field.
    func sunken() -> some View {
        overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.line))
    }
}

/// Quiet pill button; `large` for the main action of a screen.
/// Never squeezed: a narrow row overflows or scrolls instead of truncating labels.
struct PixelButtonStyle: ButtonStyle {
    var large = false
    /// Tight padding for dense rows.
    var compact = false
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.ui(large ? 15 : 13, weight: .semibold))
            .foregroundStyle(isPrimary ? Tokens.surface : Tokens.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, large ? 18 : compact ? 9 : 12)
            .padding(.vertical, large ? 9 : compact ? 4 : 6)
            .background(isPrimary ? Tokens.text : Tokens.ghost, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A session's state as a dot. `kind` is what the session is doing; selection is drawn by the row.
struct SelectionRing: View {
    enum Kind { case idle, working, waiting, sync, error }

    let kind: Kind?
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(Self.color(kind)).frame(width: size, height: size)
    }

    static func color(_ kind: Kind?) -> Color {
        switch kind {
        case nil, .idle: Tokens.idle
        case .working: Tokens.work
        case .waiting: Tokens.need
        case .sync: Tokens.warn
        case .error: Tokens.danger
        }
    }
}

/// Thin context bar: up to 50% ink blue, up to 70% amber, beyond that vermilion.
struct ContextBar: View {
    /// nil = no response yet.
    let fraction: Double?

    var body: some View {
        Canvas(renderer: Self.renderer(fraction: fraction))
            .frame(height: 4)
            .help(fraction.map { "Context \(Int(($0 * 100).rounded()))%" } ?? "Context: no reply yet")
    }

    /// Built outside the main actor: on macOS 15 SwiftUI calls Canvas renderers from its DisplayLink thread
    /// during animations, and a main-actor closure there traps (Rustem's crash, 2026-09-24).
    nonisolated static func renderer(fraction: Double?) -> (inout GraphicsContext, CGSize) -> Void {
        { context, size in
            // A frame mid-animation can bring a size that isn't a real one; skip it rather than draw nonsense.
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.width < 100_000, size.height > 0 else { return }
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(Tokens.line))
            let filled = min(max(fraction ?? 0, 0), 1)
            guard filled.isFinite, filled > 0 else { return }
            let color = filled <= 0.5 ? Tokens.work : filled <= 0.7 ? Tokens.warn : Tokens.need
            let bar = CGRect(x: 0, y: 0, width: max(size.height, size.width * filled), height: size.height)
            context.fill(Path(roundedRect: bar, cornerRadius: size.height / 2), with: .color(color))
        }
    }
}

/// Small plate with a number, e.g. tokens today.
struct NumberPlate: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Fonts.mono(11))
            .foregroundStyle(Tokens.textDim)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Tokens.ghost, in: Capsule())
    }
}

/// A pending yes/no question for `pixelConfirm` — Meepo's own stand-in for `confirmationDialog`.
struct PixelConfirmation {
    let title: String
    var message: String?
    let action: String
    /// A second choice between CANCEL and the main action (e.g. "Run QA first").
    var alternative: (title: String, perform: () -> Void)?
    /// nil = no cancel button: a notice with just OK.
    var cancel: String? = "Cancel"
    /// Red for destructive actions; a plain notice isn't.
    var isDestructive = true
    /// Called when the box goes away without a choice (Cancel, Esc, a click outside).
    var onCancel: (() -> Void)?
    let perform: () -> Void
}

extension View {
    /// Shows `confirmation` as a card over this view. Attach at the window root so it covers the whole window.
    func pixelConfirm(_ confirmation: Binding<PixelConfirmation?>) -> some View {
        overlay {
            if let pending = confirmation.wrappedValue {
                ZStack {
                    Tokens.text.opacity(0.18)
                        .onTapGesture { confirmation.wrappedValue = nil; pending.onCancel?() }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(pending.title.capitalizedSentence).font(Fonts.ui(20, weight: .bold)).foregroundStyle(Tokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let message = pending.message {
                            Text(message).font(Fonts.ui(14)).foregroundStyle(Tokens.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            Spacer()
                            if let cancel = pending.cancel {
                                Button(cancel.capitalizedSentence) { confirmation.wrappedValue = nil; pending.onCancel?() }
                                    .keyboardShortcut(.cancelAction)
                                    .buttonStyle(PixelButtonStyle())
                            }
                            if let alternative = pending.alternative {
                                Button(alternative.title.capitalizedSentence) {
                                    confirmation.wrappedValue = nil
                                    alternative.perform()
                                }
                                .buttonStyle(PixelButtonStyle())
                            }
                            Button {
                                confirmation.wrappedValue = nil
                                pending.perform()
                            } label: {
                                Text(pending.action.capitalizedSentence)
                            }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(DestructiveAwareStyle(isDestructive: pending.isDestructive))
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: 460)
                    .background(Tokens.raised, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.line))
                    .shadow(color: .black.opacity(0.12), radius: 30, y: 12)
                    .padding(12)
                }
            }
        }
    }
}

/// The confirming button: ink, or red when it destroys something.
private struct DestructiveAwareStyle: ButtonStyle {
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.ui(13, weight: .semibold))
            .foregroundStyle(Tokens.raised)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isDestructive ? Tokens.danger : Tokens.text, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension String {
    /// "REMOVE WORKTREE X?" → "Remove worktree x?" — v1 wrote dialog titles in caps for the pixel font.
    /// Leaves mixed-case text alone.
    var capitalizedSentence: String {
        guard self == uppercased(), contains(where: \.isLetter) else { return self }
        let lower = lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
