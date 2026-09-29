import SwiftUI

/// TOOLS → SERVERS (SPEC module 10): each project's servers and their log sources; Get logs reads one through its
/// read-only template and hands it to Claude. ssh runs in a detached task, never in body.
struct ServersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var confirmation: PixelConfirmation?
    @State private var sshHosts: [String] = []
    @State private var addingTo: Int64?
    @State private var host = ""
    @State private var label = ""
    @State private var sourceFor: Int64?
    @State private var kind = LogSource.Kind.journal
    @State private var name = ""
    @State private var containers: [Int64: [String]] = [:]
    @State private var busy: String?
    @State private var note: String?
    @State private var logs: Logs?
    /// Came from "Add a server…": the shell opens once the server is added.
    @State private var opensShell = false
    @FocusState private var isHostFocused: Bool

    /// What Get logs brought back, for the project it belongs to.
    struct Logs {
        let projectId: Int64
        let fetched: [ServerLogs.Fetched]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Explain.servers).font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            if let note { Text(note).font(Fonts.ui(13, weight: .semibold)).foregroundStyle(Tokens.text).fixedSize(horizontal: false, vertical: true) }
            if let logs { logsView(logs) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.projects.isEmpty { Text("Add a project first — servers belong to a project.").foregroundStyle(Tokens.textDim) }
                        ForEach(store.projects) { project in projectView(project).id(project.id) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    guard let id = store.addServerProjectId else { return }
                    store.addServerProjectId = nil
                    (addingTo, host, label, opensShell) = (id, "", "", true)
                    proxy.scrollTo(id, anchor: .top)
                    isHostFocused = true
                }
            }
            .background(Tokens.dirt)
            .sunken()
        }
        .buttonStyle(PixelButtonStyle(compact: true))
        .task {
            let url = SSHConfig.userConfig
            sshHosts = await Task.detached { SSHConfig.hosts((try? String(contentsOf: url, encoding: .utf8)) ?? "") }.value
        }
    }

    @ViewBuilder
    private func projectView(_ project: Project) -> some View {
        let servers = store.servers(of: project.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name.uppercased()).font(Fonts.title(14)).foregroundStyle(servers.isEmpty ? Tokens.textDim : Tokens.text)
                Spacer()
                Button("Add server…") { addingTo = project.id; host = ""; label = "" }
            }
            ForEach(servers) { server in serverView(server) }
            if addingTo == project.id, let projectId = project.id { addServerForm(projectId) }
        }
    }

    private func serverView(_ server: Server) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(server.title).font(Fonts.mono(12)).foregroundStyle(Tokens.text).lineLimit(1)
                Spacer()
                Button("Open shell") {
                    do { try store.openShell(on: server); dismiss() } catch { note = error.localizedDescription }
                }
                .help("ssh \(server.host) in a meepo tab, like a terminal in VS Code")
                Button("Add logs…") { sourceFor = server.id; kind = .journal; name = "" }
                    .help("Where this server's logs are: a service, a container or a file")
                Button(busy == "c\(server.id ?? 0)" ? "Looking…" : "Containers") { listContainers(server) }
                    .disabled(busy != nil)
                    .help("Lists the containers running on \(server.host) (docker ps) — click one to add its logs")
                Button("Remove…") { confirmRemove(server) }
            }
            if server.sources.isEmpty {
                Text("No logs yet — Add logs… or Containers.").font(.caption).foregroundStyle(Tokens.textDim)
            }
            ForEach(server.sources) { source in
                HStack(spacing: 8) {
                    Text(ServerLogs.command(for: source) ?? source.name).font(Fonts.mono(11)).foregroundStyle(Tokens.screen)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("×") { remove(source, from: server) }.help("Forget this log source")
                    Button(busy == "\(server.id ?? 0)\(source.id)" ? "Reading…" : "Get logs") { getLogs(source, of: server) }
                        .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                        .disabled(busy != nil)
                        .help("Runs only this on \(server.host) over ssh and shows the last \(ServerLogs.lines) lines")
                }
                .padding(.leading, 12)
            }
            if let names = server.id.flatMap({ containers[$0] }) {
                HStack(spacing: 6) {
                    Text(names.isEmpty ? "No containers running." : "Running:").font(.caption).foregroundStyle(Tokens.textDim)
                    ForEach(names, id: \.self) { container in
                        Button(container) { add(LogSource(kind: .docker, name: container), to: server) }
                            .disabled(server.sources.contains(LogSource(kind: .docker, name: container)))
                    }
                }
                .padding(.leading, 12)
            }
            if sourceFor == server.id { addSourceForm(server) }
        }
        .padding(6)
        .background(Tokens.grass)
    }

    private func addServerForm(_ projectId: Int64) -> some View {
        HStack(spacing: 6) {
            if !sshHosts.isEmpty {
                Menu("~/.ssh/config") { ForEach(sshHosts, id: \.self) { item in Button(item) { host = item } } }
                    .fixedSize()
                    .help("Hosts from your ssh config")
            }
            TextField("ssh root@1.2.3.4", text: $host).textFieldStyle(.roundedBorder).frame(width: 240)
                .focused($isHostFocused)
                .help("As you'd type it in Terminal: ssh user@host, ssh -p 2222 user@host, or an alias from ~/.ssh/config")
            TextField("label: prod, stage", text: $label).textFieldStyle(.roundedBorder).frame(width: 130)
            Button(opensShell ? "Add and open shell" : "Add") {
                let typed = host.trimmingCharacters(in: .whitespaces)
                let server = Server(projectId: projectId, host: ServerLogs.destination(from: typed) ?? typed,
                                    label: label.trimmingCharacters(in: .whitespaces))
                save(server) {
                    addingTo = nil
                    guard opensShell, let saved = store.servers(of: projectId).last(where: { $0.host == server.host }) else { return }
                    do { try store.openShell(on: saved); dismiss() } catch { note = error.localizedDescription }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { addingTo = nil }
        }
    }

    private func addSourceForm(_ server: Server) -> some View {
        let source = LogSource(kind: kind, name: name.trimmingCharacters(in: .whitespaces))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: $kind) { ForEach(LogSource.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().fixedSize()
                TextField(kind == .journal ? "nginx" : kind == .docker ? "web" : "/var/log/app.log", text: $name)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Add") { add(source, to: server); sourceFor = nil }.disabled(!ServerLogs.isValid(source))
                Button("Cancel") { sourceFor = nil }
            }
            Text(source.name.isEmpty ? "Only the name goes in — meepo builds the command." :
                    ServerLogs.command(for: source).map { "Runs: \($0)" } ?? "Letters, digits and . _ - @ : only; a file path starts with /. No spaces.")
                .font(.caption).foregroundStyle(Tokens.textDim)
        }
        .padding(.leading, 12)
    }

    private func logsView(_ logs: Logs) -> some View {
        let target = store.logsTarget(in: logs.projectId)
        let ok = logs.fetched.filter { $0.error == nil }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(logs.fetched.enumerated()), id: \.offset) { _, fetched in
                Text("\(fetched.host) — \(fetched.command)").font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(1)
                if let error = fetched.error {
                    Text(error).font(.caption).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    Text(fetched.log.isEmpty ? "(empty)" : fetched.log).font(Fonts.mono(11)).foregroundStyle(Tokens.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .background(Tokens.terminalBg)
            }
            HStack(spacing: 6) {
                if let target, let id = target.id {
                    Button("Paste into \(store.displayName(of: target))") { store.pasteLogs(ok, into: id); dismiss() }
                        .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                        .disabled(ok.isEmpty)
                        .help("Pastes the logs into the session's prompt — add your question and press Enter")
                }
                Button("New session") {
                    do { try store.investigateLogs(ok, in: logs.projectId); dismiss() } catch { note = error.localizedDescription }
                }
                .disabled(ok.isEmpty)
                .help("A new session in this project that starts by looking into these logs")
                Spacer()
                Button("Close") { self.logs = nil }
            }
        }
        .padding(8)
        .background(Tokens.grass)
        .sunken()
    }

    private func save(_ server: Server, then done: () -> Void) {
        do {
            try store.saveServer(server)
            note = nil
            done()
        } catch {
            note = error.localizedDescription
        }
    }

    private func add(_ source: LogSource, to server: Server) {
        guard !server.sources.contains(source) else { return }
        var updated = server
        updated.sources.append(source)
        save(updated) {}
    }

    private func remove(_ source: LogSource, from server: Server) {
        var updated = server
        updated.sources.removeAll { $0 == source }
        save(updated) {}
    }

    private func confirmRemove(_ server: Server) {
        confirmation = PixelConfirmation(
            title: "Remove \(server.title)?",
            message: "meepo forgets this server and its log sources. Nothing changes on the server or in your ssh config.",
            action: "Remove"
        ) { if let id = server.id { store.deleteServer(id) } }
    }

    private func getLogs(_ source: LogSource, of server: Server) {
        busy = "\(server.id ?? 0)\(source.id)"
        note = nil
        Task {
            let fetched = await store.fetchLogs([(host: server.host, source: source)])
            logs = Logs(projectId: server.projectId, fetched: fetched)
            busy = nil
        }
    }

    private func listContainers(_ server: Server) {
        guard let id = server.id else { return }
        busy = "c\(id)"
        note = nil
        Task {
            switch await store.listContainers(on: server.host) {
            case .success(let names): containers[id] = names
            case .failure(let error): note = error.text
            }
            busy = nil
        }
    }
}
