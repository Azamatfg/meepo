import SwiftUI

/// Open here / Continue here / Output / Stop for a session outside meepo — the same questions wherever offered.
extension AppStore {
    /// The main thing to do with it, if there is one: Open here (background) or Continue here (another window).
    func primaryAction(for agent: ClaudeAgents.Agent) -> (title: String, run: () -> Void)? {
        if agent.isBackground { return ("Open here", { self.askOpenHere(agent) }) }
        if agent.isInteractive { return ("Continue here", { self.askContinueHere(agent) }) }
        return nil
    }

    private func projectNote(_ agent: ClaudeAgents.Agent) -> String {
        isNewProject(agent) ? " \(agent.folderName) isn't in meepo yet — it's added as a project." : ""
    }

    func askOpenHere(_ agent: ClaudeAgents.Agent) {
        confirmation = PixelConfirmation(
            title: "Open “\(agent.title)” here?",
            message: "It opens as a meepo tab, with its stages, changes and notifications. Closing the tab never stops it — the agent keeps running in the background." + projectNote(agent),
            action: "Open here",
            isDestructive: false
        ) { [weak self] in self?.adoptOrSay { try $0.openHere(agent) } }
    }

    func askContinueHere(_ agent: ClaudeAgents.Agent) {
        guard agent.canContinueHere else {
            confirmation = PixelConfirmation(
                title: "It's still open \(agent.place)",
                message: "Close it there first — then it continues here. One conversation can't run in two places at once.",
                action: "OK", cancel: nil, isDestructive: false) {}
            return
        }
        confirmation = PixelConfirmation(
            title: "Continue “\(agent.title)” here?",
            message: "Its conversation goes on in a meepo tab (claude --resume), where it left off \(agent.place)." + projectNote(agent),
            action: "Continue here",
            isDestructive: false
        ) { [weak self] in self?.adoptOrSay { try $0.continueHere(agent) } }
    }

    func askStop(_ agent: ClaudeAgents.Agent) {
        confirmation = PixelConfirmation(
            title: "Stop “\(agent.title)”?",
            message: "The agent stops where it is and leaves this list. Its conversation is kept: “claude attach \(agent.id)” in a terminal starts it again.",
            action: "Stop"
        ) { [weak self] in Task { await self?.stopAgent(agent) } }
    }

    private func adoptOrSay(_ action: (AppStore) throws -> Void) {
        do {
            try action(self)
        } catch {
            confirmation = PixelConfirmation(title: "Couldn't open it here", message: error.localizedDescription,
                                             action: "OK", cancel: nil, isDestructive: false) {}
        }
    }
}

/// The actions as a menu (right-click on a row or a card).
struct ElsewhereMenu: View {
    @Environment(AppStore.self) private var store
    let agent: ClaudeAgents.Agent

    var body: some View {
        if let primary = store.primaryAction(for: agent) { Button(primary.title + "…", action: primary.run) }
        if agent.isBackground {
            Button("Output") { store.outputAgent = agent }
            Divider()
            Button("Stop…", role: .destructive) { store.askStop(agent) }
        }
    }
}

/// A session outside meepo in the Sessions panel: dimmed, a click offers Open here / Continue here.
struct ElsewhereRow: View {
    @Environment(AppStore.self) private var store
    let agent: ClaudeAgents.Agent

    var body: some View {
        let look = agent.look
        HStack(alignment: .top, spacing: 10) {
            SelectionRing(kind: look.ring).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.title)
                    .font(Fonts.ui(14, weight: .semibold))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
                Text([look.text, agent.folderName, agent.place].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(agent.needsYou ? Tokens.need : Tokens.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { store.primaryAction(for: agent)?.run() }
        .contextMenu { ElsewhereMenu(agent: agent) }
        .help(agent.cwd ?? agent.title)
    }
}

/// A session outside meepo on Home's Deck: a dimmed card with what it is and what can be done with it.
struct ElsewhereCard: View {
    @Environment(AppStore.self) private var store
    let agent: ClaudeAgents.Agent

    var body: some View {
        let look = agent.look
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SelectionRing(kind: look.ring, size: 9)
                Text(agent.folderName).font(Fonts.ui(19, weight: .bold)).foregroundStyle(Tokens.text).lineLimit(1)
                Text(agent.title).font(Fonts.ui(14)).foregroundStyle(Tokens.textDim).lineLimit(1)
                Spacer(minLength: 4)
                Text(look.text.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1)
                    .foregroundStyle(agent.needsYou ? Tokens.need : Tokens.textDim)
                    .lineLimit(1)
            }
            Text(line)
                .font(Fonts.ui(14, weight: .semibold)).lineLimit(3)
                .foregroundStyle(Tokens.textDim)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(10)
                .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 6) {
                if let primary = store.primaryAction(for: agent) {
                    Button(primary.title, action: primary.run)
                        .buttonStyle(PixelButtonStyle(compact: true, isPrimary: agent.needsYou || agent.canContinueHere))
                }
                if agent.isBackground {
                    Button("Output") { store.outputAgent = agent }.buttonStyle(PixelButtonStyle(compact: true))
                    Button("Stop…") { store.askStop(agent) }.buttonStyle(PixelButtonStyle(compact: true))
                }
                Spacer(minLength: 0)
                Text(agent.place.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1).foregroundStyle(Tokens.textDim)
            }
        }
        .padding(16)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(agent.needsYou ? Tokens.need : Tokens.line, style: StrokeStyle(lineWidth: agent.needsYou ? 2 : 1, dash: [5, 4])))
        .opacity(agent.needsYou ? 1 : 0.75)
        .contextMenu { ElsewhereMenu(agent: agent) }
    }

    /// Where it runs and what can happen, in plain words.
    private var line: String {
        let started = agent.startedAt.map { " — started " + Work.when($0) } ?? ""
        if let ended = agent.endedAt {
            return "Closed \(agent.place) at \(Work.when(ended)). Continue here picks the conversation up in meepo."
        }
        if agent.needsYou { return "Waits for your answer. Open here to see the question\(started)." }
        if agent.isBackground { return "Runs on its own, with no window\(started)." }
        if agent.isInteractive { return "Open \(agent.place)\(started). Close it there to continue here." }
        return "A \(agent.kind) session\(started)."
    }
}

/// Output: what a background agent printed last (`claude logs`), as plain text.
struct AgentOutputSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: ClaudeAgents.Agent
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(agent.title).font(Fonts.title(22)).lineLimit(1)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            Text("What it printed last — claude logs \(agent.id)").foregroundStyle(Tokens.textDim)
            ScrollView {
                Text(text ?? "Loading…")
                    .font(Fonts.mono(12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .paperSheet()
        .task { text = await store.agentOutput(agent) }
    }
}
