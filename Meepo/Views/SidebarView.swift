import SwiftUI

/// Projects and their sessions as a panel: a click opens the session, Tab / Shift+Tab step through them
/// while the list has focus.
struct SessionsPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.projects.isEmpty {
                Text("No projects yet — add one with + above").font(.caption).foregroundStyle(Tokens.textDim)
            }
            ForEach(store.projects) { project in
                ProjectHeader(project: project, isActive: store.selectedSession?.projectId == project.id) {
                    store.presentNewSession(projectId: project.id)
                }
                .padding(.top, 8)
                ForEach(store.sessions.filter { $0.projectId == project.id }) { session in
                    SessionRow(session: session, isSelected: session.id == store.selectedSessionId && !store.isHomeShown)
                }
            }
            if !store.elsewhere.isEmpty {
                HStack(spacing: 4) {
                    Text("ELSEWHERE").font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim)
                    InfoButton(title: "Elsewhere", text: Explain.elsewhere)
                }
                .padding(.horizontal, 4)
                .padding(.top, 14)
                ForEach(store.elsewhere) { ElsewhereRow(agent: $0) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.tab]) { press in
            store.selectSession(offset: press.modifiers.contains(.shift) ? -1 : 1)
            return .handled
        }
    }
}

/// What a session looks like: ring under the unit (nil = closed, no ring) and a short status.
extension AppStore {
    func look(of session: Session) -> (ring: SelectionRing.Kind?, text: String) {
        guard let id = session.id else { return (nil, "") }
        if exitedSessionIds.contains(id) { return (nil, session.isServerShell ? "Disconnected" : "Exited") }
        guard runningSessionIds.contains(id) else { return (nil, session.isServerShell ? "Not connected" : "Not running") }
        if session.sshHost != nil { return (.idle, session.isServerShell ? "Connected" : "Terminal") } // a shell sends no hook events
        if interruptedSessionIds.contains(id) { return (.sync, "Turn interrupted") }
        if relayingSessionIds.contains(id) { return (.sync, "Relaying…") }
        let full = (contextFraction(for: id) ?? 0) >= relayThreshold
        if full, session.status == .idle || session.status == .thinking { return (.sync, "Time to sync") }
        return switch session.status {
        case .thinking: (.working, "Working")
        case .waitingPermission: (.waiting, "Needs permission")
        case .waitingInput: (.waiting, "Waiting for you")
        case .needsSync: (.sync, "Time to sync")
        case .error: (.error, "Error")
        case .idle: (.idle, "Ready")
        }
    }
}

/// A session in the list: state dot, branch, what it does, context and tokens, CI.
private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let isSelected: Bool

    var body: some View {
        let look = store.look(of: session)
        HStack(alignment: .top, spacing: 10) {
            SelectionRing(kind: look.ring).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayName(of: session))
                    .font(Fonts.ui(14, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                Text([look.text, session.worktreeName.map { "worktree \($0)" } ?? session.branch, session.stage?.uppercased()]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(look.ring == .waiting ? Tokens.need : Tokens.textDim)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ContextBar(fraction: session.id.flatMap(store.contextFraction(for:)),
                               help: session.id.map(store.contextHelp(for:)) ?? "")
                    NumberPlate(text: TokenFormat.short(session.id.flatMap { store.sessionUsage[$0]?.tokensToday } ?? 0))
                        .help("Tokens today (input + output + cache)")
                    if let run = store.ciState(for: session) {
                        Button {
                            store.selectedSessionId = session.id
                            store.editShell { if $0.zone(of: .ci) == nil { $0.move(.ci, to: .right) } }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: isSelected ? .black.opacity(0.08) : .clear, radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedSessionId = session.id }
        .contextMenu { SessionMenu(session: session) }
        .help(look.text)
    }
}

/// New Session Instead / Restart / Close — the same confirmations wherever they're offered.
struct SessionMenu: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        let place = session.worktreeName.map { "worktree \($0)" } ?? session.branch ?? "this folder"
        Button("Rename…") { store.renamingSessionId = session.id }
        // Where VS Code users look for a terminal to the server: next to the session they work in.
        Menu("Server Shell") {
            ForEach(store.servers(of: session.projectId)) { server in
                Button(server.title) {
                    do { try store.openShell(on: server) } catch { store.bridgeError = error.localizedDescription }
                }
            }
            if !store.servers(of: session.projectId).isEmpty { Divider() }
            Button("Add a server…") { store.presentAddServer(projectId: session.projectId) }
        }
        // The project's databases, read only for Claude: the schema, or the wizard to add one.
        Menu("Database") {
            ForEach(store.databases(of: session.projectId)) { database in
                Button("Schema of \(database.label)") { if let id = database.id { store.presentDatabases(.schema(databaseId: id)) } }
            }
            if !store.databases(of: session.projectId).isEmpty { Divider() }
            Button("Add database…") { store.presentDatabases(.add(projectId: session.projectId)) }
        }
        // Production projects: anything touching a server or a database asks first.
        let important = store.projects.first { $0.id == session.projectId }?.isImportant ?? false
        Button(important ? "✓ Important — asks before server & database commands" : "Mark Important — ask before server & database commands") {
            store.setImportant(session.projectId, !important)
        }
        // Meepo's method, VERIFY: a turn that changed files ends only once the project's check passes.
        let check = store.projects.first { $0.id == session.projectId }?.checkCommand
        Button(check.map { "✓ Check Before Done — \($0)" } ?? "Check Before Done…") { store.editingCheckProjectId = session.projectId }
        Button("Open Terminal Here") {
            do { try store.openTerminal(projectId: session.projectId) } catch { store.bridgeError = error.localizedDescription }
        }
        if session.sshHost != nil {
            Button(session.isLocalTerminal ? "Restart" : "Reconnect") { store.restartSession(session.id!) }
            Divider()
            Button("Close Shell", role: .destructive) { store.closeSession(session.id!) }
        } else {
            Button("New Session Instead…") {
                store.confirmation = PixelConfirmation(
                    title: "Start a fresh session?",
                    message: "A new claude in \(place), with a clean context. This one is closed; its conversation stays in Claude Code (claude --resume).",
                    action: "New session",
                    isDestructive: false
                ) { try? store.replaceSession(session.id!) }
            }
            Button("Restart") { store.restartSession(session.id!) }
            Divider()
            Button("Close Session…", role: .destructive) {
                store.confirmation = PixelConfirmation(
                    title: "Close this session?",
                    message: session.agentId != nil && store.attachId(for: session) != nil
                        ? "Only the tab closes: the agent keeps running in the background (claude agents)."
                        : "claude stops. Files and commits stay; the conversation stays in Claude Code (claude --resume).",
                    action: "Close"
                ) { store.closeSession(session.id!) }
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
            SelectionRing(kind: look.ring)
            if let projectName {
                Text(projectName).foregroundStyle(Tokens.text)
            }
            Text(session.shellCaption ?? session.branch ?? "no branch")
                .font(Fonts.mono(12))
                .foregroundStyle(Tokens.textDim)
            Spacer(minLength: 0)
            Text(look.text)
                .font(.caption)
                .foregroundStyle(look.ring == .waiting ? Tokens.alert : Tokens.textDim)
        }
    }
}

private struct ProjectHeader: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let isActive: Bool
    let onNewSession: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(Fonts.ui(15, weight: .bold))
                    .foregroundStyle(isActive ? Tokens.text : Tokens.textDim)
                    .lineLimit(1)
                Text(project.remote ?? store.nestedRepos[project.path].flatMap { repos in
                        repos.isEmpty ? nil : "\(repos.count) repos: " + repos.map(\.name).joined(separator: ", ") } ?? "no remote")
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
                Divider()
                Button("Remove from meepo…") {
                    store.confirmation = PixelConfirmation(
                        title: "Remove \(project.name) from meepo?",
                        message: "Its sessions close. The folder, git and Claude's conversations stay — add it again any time.",
                        action: "Remove"
                    ) { store.removeProject(project.id!) }
                }
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(PixelButtonStyle(compact: true))
            .fixedSize()
            .help("Open \(project.name) in an editor (meepo has none)")
            Button(action: onNewSession) {
                Image(systemName: "plus")
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .help("New session in \(project.name)")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .help(project.path)
    }

    private func open(app: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-a", app, project.path]
        try? process.run()
    }
}

/// Bridge/event-server problems for the status bar: shown until the hook bridge is installed, when it or the
/// event server fails, or when macOS blocks notifications.
struct BridgeIssues: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            if let error = store.bridgeError {
                Text(error).foregroundStyle(Tokens.danger).lineLimit(1).truncationMode(.tail).help(error)
                Button("✕") { store.bridgeError = nil }.buttonStyle(.plain).foregroundStyle(Tokens.textDim)
            }
            if !store.notificationsAllowed {
                Button("Notifications off — open settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.warn)
            }
            if !store.isBridgeInstalled {
                Button("No statuses: install the hook bridge") { store.installBridge() }
                    .buttonStyle(.plain).foregroundStyle(Tokens.need)
                    .help("Adds meepo-bridge.sh to ~/.claude/settings.json next to your hooks; your own Notification hooks stay quiet in meepo sessions. Backups go to ~/.meepo/backups")
            }
        }
    }
}
