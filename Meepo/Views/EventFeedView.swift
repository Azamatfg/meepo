import SwiftUI

/// Right panel: hook events of the selected session, newest first; refusals and failures highlighted.
struct EventFeedView: View {
    @Environment(AppStore.self) private var store

    @State private var tab = Tab.events

    enum Tab: String, CaseIterable { case events = "EVENTS", tasks = "TASKS", ports = "PORTS" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(item.rawValue) { tab = item }
                        .buttonStyle(PixelButtonStyle())
                        .overlay { if tab == item { Bevel(raised: false) } }
                }
            }
            .padding(8)
            Rectangle().fill(Tokens.grassDeep).frame(height: 2)
            switch tab {
            case .events: feed
            case .tasks: TasksView()
            case .ports: PortsView()
            }
        }
        .background(Tokens.dirt)
    }

    @ViewBuilder
    private var feed: some View {
        Group {
            if store.selectedEvents.isEmpty {
                Text(store.isBridgeInstalled ? "No events yet" : "Install the bridge to see events")
                    .foregroundStyle(Tokens.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.selectedEvents) { event in
                    EventRow(event: event)
                        .listRowBackground(Tokens.dirt)
                        .listRowSeparatorTint(Tokens.grassDeep)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Tokens.dirt)
    }
}

private struct EventRow: View {
    let event: HookEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Self.title(for: event.name))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(event.isFailure ? Tokens.danger : Tokens.text)
                Spacer()
                Text(event.createdAt, format: .dateTime.hour().minute().second())
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.textDim)
            }
            if let summary = event.summary, !summary.isEmpty {
                Text(Notifier.plainText(summary, limit: 300))
                    .font(.caption)
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private static func title(for name: String) -> String {
        switch name {
        case "SessionStart": "Session started"
        case "SessionEnd": "Session ended"
        case "UserPromptSubmit": "Prompt"
        case "PreToolUse": "Tool"
        case "PostToolUse": "Tool done"
        case "PostToolUseFailure": "Tool failed"
        case "PermissionRequest": "Permission request"
        case "PermissionDenied": "Denied"
        case "Notification": "Notification"
        case "Stop": "Reply ready"
        case "StopFailure": "Reply failed"
        case "PreCompact": "Compacting context"
        case "UserPromptExpansion": "Command"
        default: name
        }
    }
}

/// Who listens on which port (SPEC module 5), with the Meepo session or project it belongs to.
private struct PortsView: View {
    @Environment(AppStore.self) private var store
    @State private var ports: [ListeningPort] = []

    var body: some View {
        List(ports) { port in
            HStack(alignment: .firstTextBaseline) {
                Text(String(port.port)).font(Fonts.mono(13)).foregroundStyle(owner(of: port) == nil ? Tokens.textDim : Tokens.screen)
                    .frame(width: 54, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(port.process).foregroundStyle(Tokens.text).lineLimit(1)
                    Text(owner(of: port) ?? port.cwd ?? "pid \(port.pid)")
                        .font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.head)
                }
            }
            .listRowBackground(Tokens.dirt)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task {
            while !Task.isCancelled {
                ports = await Task.detached { Ports.listening() }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Deepest matching folder wins, so a worktree beats its main checkout.
    private func owner(of port: ListeningPort) -> String? {
        guard let cwd = port.cwd else { return nil }
        let candidates = store.sessions.compactMap { session -> (String, String)? in
            guard let dir = store.workdir(of: session), let project = store.project(for: session) else { return nil }
            return (dir, "\(project.name) · \(session.branch ?? "")")
        }
        return candidates.filter { cwd == $0.0 || cwd.hasPrefix($0.0 + "/") }.max { $0.0.count < $1.0.count }?.1
    }
}
