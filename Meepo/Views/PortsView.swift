import SwiftUI

/// TOOLS → PORTS (SPEC module 5): what listens on this Mac, grouped by whose it is. Open for a session's own
/// ports, Stop… for your own programs and containers, always asked first; apps and macOS are folded and never
/// stopped. lsof and docker run in a detached task, never in body.
struct PortsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Binding var confirmation: PixelConfirmation?
    @State private var ports: [ListeningPort] = []
    @State private var containers: [Docker.Container] = []
    @State private var isLoaded = false
    @State private var showsApps = false
    @State private var note: String?
    @State private var stopping: String?
    @State private var reload = 0

    var body: some View {
        let groups = PortGroups.groups(listening: ports, containers: containers, projects: store.projects,
                                       sessions: sessions, home: NSHomeDirectory())
        VStack(alignment: .leading, spacing: 8) {
            Text(Explain.ports).font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            if let note { Text(note).font(Fonts.ui(13, weight: .semibold)).foregroundStyle(Tokens.text) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !isLoaded {
                        Text("Looking at ports…").foregroundStyle(Tokens.textDim)
                    } else if groups.isEmpty {
                        Text("Nothing listens on a port right now.").foregroundStyle(Tokens.textDim)
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            if group.kind == .apps {
                                Button { showsApps.toggle() } label: {
                                    Text("\(showsApps ? "▾" : "▸") \(group.title.uppercased()) (\(group.rows.count))")
                                        .font(Fonts.title(14)).foregroundStyle(Tokens.textDim)
                                }
                                .buttonStyle(.plain)
                                .help("Apps, parts of macOS and services that start by themselves (like Homebrew's) listen here too. meepo shows them so you know what holds a port, and never stops them: a service would start again, an app could break.")
                            } else {
                                Text(group.title.uppercased()).font(Fonts.title(14))
                                    .foregroundStyle(group.kind == .project ? Tokens.text : Tokens.textDim)
                            }
                            if group.kind != .apps || showsApps {
                                ForEach(group.rows) { row in rowView(row, in: group) }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Tokens.dirt)
            .sunken()
        }
        .task(id: reload) {
            while !Task.isCancelled {
                let docker = store.toolPath("docker")
                let (listening, running) = await Task.detached {
                    (Ports.listening(), docker.flatMap { Docker.run($0, ["ps", "--format", "{{json .}}"]) }.map(Docker.parseContainers) ?? [])
                }.value
                ports = listening
                containers = running
                isLoaded = true
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var sessions: [PortGroups.Session] {
        store.sessions.compactMap { session in
            guard let project = store.project(for: session) else { return nil }
            return PortGroups.Session(base: session.portBase, project: project.name, name: store.displayName(of: session),
                                      worktree: session.worktreeName == nil ? nil : store.workdir(of: session))
        }
    }

    private func rowView(_ row: PortGroups.Row, in group: PortGroups.Group) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.ports.map(String.init).joined(separator: " · ")).font(Fonts.mono(12))
                .foregroundStyle(row.openPort == nil ? Tokens.text : Tokens.screen)
                .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).foregroundStyle(Tokens.text).lineLimit(1)
                Text(row.detail).font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let port = row.openPort, let url = URL(string: "http://localhost:\(port)") {
                Button("Open") { openURL(url) }.help("\(url.absoluteString) in your browser — this session's own port")
            }
            if row.canStop {
                Button(stopping == row.id ? "Stopping…" : "Stop…") { confirmStop(row, in: group) }
                    .disabled(stopping != nil)
            }
        }
        .buttonStyle(PixelButtonStyle(compact: true))
        .padding(.leading, 4)
    }

    private func confirmStop(_ row: PortGroups.Row, in group: PortGroups.Group) {
        let ports = row.ports.map(String.init).joined(separator: ", ")
        switch row.owner {
        case .process(let pid):
            confirmation = PixelConfirmation(
                title: "Stop \(row.name)?",
                message: "It listens on \(ports) (\(group.title), pid \(pid)). meepo asks it to quit, like closing it yourself: the port is free again, and anything it hasn't saved is lost. Start it again the way you started it.",
                action: "Stop"
            ) { stop(row) { await Ports.stop(pid: pid, port: row.ports[0], name: row.name) } }
        case .container(let id):
            confirmation = PixelConfirmation(
                title: "Stop container \(row.name)?",
                message: "It listens on \(ports) (\(group.title)). Its saved data stays in its volumes; docker compose up or Docker Desktop starts it again.",
                action: "Stop"
            ) {
                let docker = store.toolPath("docker")
                stop(row) {
                    docker.flatMap { Docker.run($0, ["stop", id]) } == nil
                        ? "Docker couldn't stop \(row.name)." : "Stopped container \(row.name)."
                }
            }
        }
    }

    private func stop(_ row: PortGroups.Row, _ work: @escaping @Sendable () async -> String) {
        stopping = row.id
        note = nil
        Task {
            note = await Task.detached { await work() }.value
            stopping = nil
            reload += 1
        }
    }
}
