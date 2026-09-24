import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Namespace private var selectionSpace

    var body: some View {
        // Custom list instead of `List`: the system sidebar greys out selection whenever the
        // terminal has focus and highlights section headers on hover, so two things looked selected.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if store.projects.isEmpty {
                    Text("No projects yet — use “+ Project” above")
                        .foregroundStyle(Tokens.textDim)
                        .padding(.top, 8)
                }
                ForEach(store.projects) { project in
                    ProjectHeader(project: project, isActive: store.selectedSession?.projectId == project.id) {
                        store.presentNewSession(projectId: project.id)
                    }
                    .padding(.top, 10)
                    ForEach(store.sessions.filter { $0.projectId == project.id }) { session in
                        UnitCard(session: session, isSelected: session.id == store.selectedSessionId,
                                 selectionSpace: selectionSpace)
                    }
                }
            }
            .padding(.horizontal, 8)
            // The selection ring "jumps" to the next unit (design §8), no fades.
            .animation(.linear(duration: 0.12), value: store.selectedSessionId)
        }
        .background(Tokens.grass)
        // Plain Tab / Shift+Tab switch sessions while the list (not the terminal) has focus.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.tab]) { press in
            store.selectSession(offset: press.modifiers.contains(.shift) ? -1 : 1)
            return .handled
        }
        .safeAreaInset(edge: .bottom) {
            if !store.isBridgeInstalled || store.bridgeError != nil || !store.notificationsAllowed {
                BridgeBanner()
            }
        }
    }
}

/// What a session looks like: ring under the unit (nil = closed, no ring) and a short status.
extension AppStore {
    func look(of session: Session) -> (ring: SelectionRing.Kind?, text: String) {
        guard let id = session.id else { return (nil, "") }
        if exitedSessionIds.contains(id) { return (nil, "Exited") }
        guard runningSessionIds.contains(id) else { return (nil, "Not running") }
        if relayingSessionIds.contains(id) { return (.sync, "Relaying…") }
        let full = (contextFraction(for: id) ?? 0) >= relayThreshold
        if full, session.status == .idle || session.status == .thinking { return (.sync, "Time to sync") }
        return switch session.status {
        case .thinking: (.working, "Working")
        case .waitingPermission: (.waiting, "Needs permission")
        case .waitingInput: (.waiting, "Waiting for you")
        case .needsSync: (.sync, "Time to sync")
        case .error: (.error, "Error")
        case .idle: (.idle, "Running")
        }
    }
}

/// A session as an RTS unit (design §5): portrait over its ring, "!" when it waits for you.
private struct UnitCard: View {
    @Environment(AppStore.self) private var store
    @AppStorage("feedShown") private var isFeedShown = true
    let session: Session
    let isSelected: Bool
    let selectionSpace: Namespace.ID

    var body: some View {
        let look = store.look(of: session)
        HStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                ZStack {
                    if let ring = look.ring { SelectionRing(kind: ring) }
                    if isSelected { SelectedRing().matchedGeometryEffect(id: "selected", in: selectionSpace) }
                }
                .frame(width: 54, height: 16)
                Image("Portrait")
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 48, height: 48)
                    .saturation(look.ring == nil ? 0.2 : 1)
                    .padding(.bottom, 7)
            }
            .overlay(alignment: .topTrailing) {
                if look.ring == .waiting { Exclamation() }
            }
            .frame(width: 58, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.branch ?? "no branch")
                    .font(Fonts.mono(13))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                Text([look.text, session.stage?.uppercased(), session.model].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(look.ring == .waiting ? Tokens.alert : Tokens.textDim)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ContextBar(fraction: session.id.flatMap(store.contextFraction(for:)))
                    NumberPlate(text: TokenFormat.short(session.id.flatMap { store.sessionUsage[$0]?.tokensToday } ?? 0))
                        .help("Tokens today (input + output + cache)")
                    if let run = store.ciState(for: session) {
                        Button {
                            store.selectedSessionId = session.id
                            isFeedShown = true // the inspector shows this session's CI
                        } label: {
                            Text(run.isInfraFailure ? "CI !" : run.failed ? "CI ✗" : run.isRunning ? "CI …" : "CI ✓")
                                .font(Fonts.mono(11))
                                .foregroundStyle(run.isInfraFailure || run.isRunning ? Tokens.warn
                                                 : run.failed ? Tokens.danger : Tokens.selectionSoft)
                        }
                        .buttonStyle(.plain)
                        .help(run.isInfraFailure
                              ? "\(run.workflowName): \(run.failureReason ?? "") — CI didn't run the code, not a code failure. Click for CI"
                              : "\(run.workflowName): \(run.conclusion ?? run.status). Click for CI")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(isSelected ? Tokens.dirt : .clear)
        .overlay { if isSelected { Bevel(raised: false) } }
        .contentShape(Rectangle())
        .onTapGesture { store.selectedSessionId = session.id }
        .contextMenu {
            Button("New Session Instead") { try? store.replaceSession(session.id!) }
            Button("Restart") { store.restartSession(session.id!) }
            Button("Close Session", role: .destructive) { store.closeSession(session.id!) }
        }
        .help(look.text)
    }
}

/// Orange "!" over a waiting unit; hops 2 px when it appears (design §8).
private struct Exclamation: View {
    @State private var hop = false

    var body: some View {
        Text("!")
            .font(Fonts.title(18))
            .foregroundStyle(Tokens.alert)
            .shadow(color: .black, radius: 0, x: 1, y: 1)
            .offset(y: hop ? -2 : 0)
            .onAppear {
                withAnimation(.linear(duration: 0.08)) { hop = true } completion: {
                    withAnimation(.linear(duration: 0.08)) { hop = false }
                }
            }
    }
}

/// Compact session line for the menu bar panel.
struct SessionLabel: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let projectName: String?

    var body: some View {
        let look = store.look(of: session)
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor(look.ring))
                .frame(width: 8, height: 8)
            if let projectName {
                Text(projectName).foregroundStyle(Tokens.text)
            }
            Text(session.branch ?? "no branch")
                .font(Fonts.mono(12))
                .foregroundStyle(Tokens.textDim)
            Spacer(minLength: 0)
            Text(look.text)
                .font(.caption)
                .foregroundStyle(look.ring == .waiting ? Tokens.alert : Tokens.textDim)
        }
    }

    private func dotColor(_ ring: SelectionRing.Kind?) -> Color {
        switch ring {
        case nil: Tokens.frameMid
        case .idle, .working: Tokens.selectionSoft
        case .waiting: Tokens.alert
        case .sync: Tokens.warn
        case .error: Tokens.danger
        }
    }
}

private struct ProjectHeader: View {
    let project: Project
    let isActive: Bool
    let onNewSession: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(Fonts.title(16))
                    .foregroundStyle(isActive ? Tokens.text : Tokens.textDim)
                    .lineLimit(1)
                Text(project.remote ?? "no remote")
                    .font(.caption)
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Menu {
                ForEach(Editors.installed, id: \.self) { ide in
                    Button("Open in \(ide.name)") { open(app: ide.app) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: project.path)]) }
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(PixelButtonStyle())
            .fixedSize()
            .help("Open \(project.name) in an editor (Meepo has none)")
            Button(action: onNewSession) {
                Image(systemName: "plus")
            }
            .buttonStyle(PixelButtonStyle())
            .help("New session in \(project.name)")
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.dirt).frame(height: 2) }
        .help(project.path)
    }

    private func open(app: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-a", app, project.path]
        try? process.run()
    }
}

/// Shown until the hook bridge is installed, or when it/the event server has a problem.
private struct BridgeBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.bridgeError {
                Text(error)
                    .foregroundStyle(Tokens.danger)
            }
            if !store.notificationsAllowed {
                Text("Meepo notifications are turned off in macOS settings.")
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(PixelButtonStyle())
            }
            if !store.isBridgeInstalled {
                Text("Hook bridge not installed: no statuses or notifications.")
                Button("Install Bridge") { store.installBridge() }
                    .buttonStyle(PixelButtonStyle())
                    .help("Adds meepo-bridge.sh to ~/.claude/settings.json next to your hooks; your own Notification hooks stay quiet in Meepo sessions. Backups go to ~/.meepo/backups")
            }
        }
        .font(.caption)
        .foregroundStyle(Tokens.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelFrame(4)
        .padding(8)
    }
}
