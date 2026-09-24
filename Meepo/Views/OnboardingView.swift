import SwiftUI

/// First launch (SPEC module 13): what Meepo needs on this Mac, the hook bridge, and projects.
/// Shown once; everything here is also reachable later (Settings, + Project).
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// (tool, what Meepo uses it for, how to install). Only claude and git are required.
    private static let tools = [
        ("claude", "sessions — required", "curl -fsSL https://claude.ai/install.sh | bash"),
        ("git", "projects, worktrees — required", "xcode-select --install"),
        ("gh", "GitHub CI and PRs", "brew install gh && gh auth login"),
        ("glab", "GitLab CI", "brew install glab && glab auth login"),
        ("docker", "Docker cleanup in Tools", "brew install --cask docker"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WELCOME TO MEEPO").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Skip") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(PixelButtonStyle())

            Text("1 · TOOLS").font(Fonts.title(16)).foregroundStyle(Tokens.text)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Self.tools, id: \.0) { name, use, install in
                    let found = store.toolPath(name) != nil
                    GridRow {
                        Text(found ? "✓" : "✗").font(Fonts.mono(13)).foregroundStyle(found ? Tokens.selectionSoft : Tokens.warn)
                        Text(name).font(Fonts.mono(13)).foregroundStyle(Tokens.text)
                        Text(use).font(.caption).foregroundStyle(Tokens.textDim)
                        if found {
                            Text("")
                        } else {
                            Text(install).font(Fonts.mono(11)).foregroundStyle(Tokens.screen).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Tokens.dirt).sunken()

            Text("2 · HOOK BRIDGE").font(Fonts.title(16)).foregroundStyle(Tokens.text)
            HStack {
                Text(store.isBridgeInstalled
                     ? "Installed: statuses, questions and notifications reach Meepo."
                     : "Adds meepo-bridge.sh to ~/.claude/settings.json next to your own hooks (backup in ~/.meepo/backups).")
                    .font(.caption).foregroundStyle(store.isBridgeInstalled ? Tokens.selectionSoft : Tokens.textDim)
                Spacer()
                if !store.isBridgeInstalled {
                    Button("INSTALL") { store.installBridge() }.buttonStyle(PixelButtonStyle())
                }
            }

            Text("3 · PROJECTS FROM YOUR IDE").font(Fonts.title(16)).foregroundStyle(Tokens.text)
            ImportList { dismiss() }
        }
        .padding(16)
        .frame(width: 760, height: 680)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
    }
}
