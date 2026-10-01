import AppKit
import SwiftUI

/// TOOLS → DATABASES: each project's Postgres as Claude reads it — through a role that can only read.
struct DatabasesView: View {
    @Environment(AppStore.self) private var store
    @State private var settingUp: Project?
    @State private var schemaOf: ProjectDatabase?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Explain.databases).font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.projects.isEmpty { Text("Add a project first — a database belongs to a project.").foregroundStyle(Tokens.textDim) }
                    ForEach(store.projects) { project in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(project.name.uppercased()).font(Fonts.title(14))
                                    .foregroundStyle(store.databases(of: project.id).isEmpty ? Tokens.textDim : Tokens.text)
                                Spacer()
                                Button("Add database…") { settingUp = project }
                            }
                            ForEach(store.databases(of: project.id)) { database in
                                HStack(spacing: 8) {
                                    Text(database.label).font(Fonts.ui(13, weight: .semibold))
                                    Text(Postgres.masked(database.url)).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button(database.asksEachQuery ? "ASKS FIRST" : "NO ASKING") { store.setAsksEachQuery(database, !database.asksEachQuery) }
                                        .help(database.asksEachQuery
                                              ? "Every query Claude makes shows its SQL and waits for Allow. Click to stop asking (sessions started from now on)."
                                              : "Claude runs its read-only queries without asking. Click to see and allow each one first — for production.")
                                    Button("Schema") { schemaOf = database }
                                    Button("Remove") {
                                        store.confirmation = PixelConfirmation(
                                            title: "Remove \(database.label)?",
                                            message: "meepo forgets it and closes its tunnel\(database.mcpName.map { ", and \($0) leaves this project's .mcp.json (a backup is kept) — restart the project's sessions after" } ?? ""). The read-only user stays in the database.",
                                            action: "Remove"
                                        ) { if let id = database.id { store.deleteDatabase(id) } }
                                    }
                                }
                                .padding(6)
                                .background(Tokens.grass)
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
        .buttonStyle(PixelButtonStyle(compact: true))
        .sheet(item: $settingUp) { DatabaseSetupSheet(projectId: $0.id!) }
        .onAppear { // from a session's menu: straight to the wizard or the schema
            switch store.databaseRequest {
            case let .add(projectId)?: settingUp = store.projects.first { $0.id == projectId }
            case let .schema(databaseId)?: schemaOf = store.databases.first { $0.id == databaseId }
            case nil: break
            }
            store.databaseRequest = nil
        }
        .sheet(item: $schemaOf) { SchemaSheet(database: $0) }
    }
}

/// Add database: four steps, each saying what happens and what's next. Only step 2 writes anything to the
/// database — the role — and only when the user runs it.
struct DatabaseSetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectId: Int64
    @State private var step = 1
    @State private var found: [String] = []
    @State private var ownerURL = ""
    @State private var owner: Postgres.Identity?
    @State private var password = Postgres.newPassword()
    @State private var roleChecked = false
    @State private var busy = false
    @State private var error: String?
    @State private var restarted = false
    /// The server the database runs on; nil = this Mac. Picked: meepo reaches it through an ssh tunnel.
    @State private var serverId: Int64?
    @State private var tunnel: AppStore.Tunnel?
    /// Postgres containers found on the chosen server (Find on server).
    @State private var onServer: [String] = []
    /// Where the sheet is: the choice (found databases), the one-button setup for a server's, or the manual steps.
    @State private var mode = Mode.choose
    /// What each project server has, looked up when the sheet opens.
    @State private var serverFinds: [Int64: Result<[Postgres.Found], Postgres.Failure>] = [:]
    @State private var progress: String?
    @State private var showsCommand = false
    @State private var added: ProjectDatabase?
    /// Every query Claude makes asks first — on for anything that isn't this Mac's own database.
    @State private var asksEachQuery: Bool?
    /// The address typed can only read already: Claude gets it as it is, no role of meepo's.
    @State private var usesAsItIs = false
    @State private var schemaOf: ProjectDatabase?

    enum Mode: Equatable {
        case choose
        case onServer(serverId: Int64, found: Postgres.Found)
        case manual
    }

    private var database: String { Postgres.parts(of: ownerURL)?.database ?? "" }
    private var sql: String { Postgres.roleSQL(database: database, password: password) }
    /// The address meepo connects to: the one typed, or the same through the tunnel's local port.
    private var connectURL: String { tunnel.flatMap { SSHTunnel.throughTunnel(ownerURL, localPort: $0.localPort)?.url } ?? ownerURL }
    private var roleURL: String? { Postgres.roleURL(from: connectURL, password: password) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(mode == .manual && step < 4 ? "ADD DATABASE · STEP \(step) OF 4" : "ADD DATABASE").font(Fonts.title(16))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if step == 4 {
                done
            } else {
                switch mode {
                case .choose: choose
                case let .onServer(serverId, found): setUp(serverId, found)
                case .manual:
                    switch step {
                    case 1: where_
                    case 2: role
                    default: claude
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .background(Tokens.grass)
        .buttonStyle(PixelButtonStyle(compact: true))
        .onDisappear { store.closeTunnel(AppStore.wizardTunnel) } // kept only once the database is added
        .task {
            guard let path = store.projects.first(where: { $0.id == projectId })?.path else { return }
            found = await Task.detached { Postgres.foundURLs(in: path) }.value
            if ownerURL.isEmpty, let first = found.first { ownerURL = first }
        }
        .task { // every project server asked at once: which Postgres runs there
            for server in store.servers(of: projectId) {
                guard let id = server.id else { continue }
                Task { serverFinds[id] = await store.findDatabases(on: id) }
            }
        }
        .sheet(item: $schemaOf) { SchemaSheet(database: $0) }
    }

    // The choice: databases meepo found — on the project's servers (one button), or in its files on this Mac.
    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Give Claude read-only access to a database").font(Fonts.ui(18, weight: .bold))
            explain("Claude can then look at data to answer and debug — and can never change it: the database itself refuses.")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.servers(of: projectId)) { server in
                        Text("On \(server.title)").font(Fonts.ui(12, weight: .semibold))
                        switch server.id.flatMap({ serverFinds[$0] }) {
                        case nil:
                            Text("Looking for Postgres…").font(.caption).foregroundStyle(Tokens.textDim)
                        case let .failure(failure)?:
                            Text(failure.localizedDescription).font(.caption).foregroundStyle(Tokens.danger)
                        case let .success(list)? where list.isEmpty:
                            Text("No Postgres running in Docker here.").font(.caption).foregroundStyle(Tokens.textDim)
                        case let .success(list)?:
                            ForEach(list) { item in
                                card(item.database, "Postgres in Docker · \(item.container)", action: "Set up") {
                                    if let id = server.id { mode = .onServer(serverId: id, found: item); error = nil }
                                }
                            }
                        }
                    }
                    if !found.isEmpty {
                        Text("On this Mac — from the project's files").font(Fonts.ui(12, weight: .semibold))
                        ForEach(found, id: \.self) { url in
                            card(Postgres.parts(of: url)?.database ?? "database", Postgres.masked(url), action: "Set up…") {
                                ownerURL = url; serverId = nil; mode = .manual; step = 1; error = nil
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Do it by hand — an address, your own SQL") { mode = .manual; step = 1; error = nil }
                    .help("For another database, or to run the SQL yourself (DBeaver, psql)")
            }
        }
    }

    /// The switch, with what it means; production gets it on unless turned off here.
    private func asksToggle(default isProduction: Bool) -> some View {
        Toggle(isOn: Binding(get: { asksEachQuery ?? isProduction }, set: { asksEachQuery = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask me before every query").font(Fonts.ui(13, weight: .semibold))
                Text("Claude shows the SQL and waits for Allow — even in auto mode. Recommended for production.")
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
        }
        .toggleStyle(.switch)
    }

    private func card(_ title: String, _ detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Fonts.ui(15, weight: .semibold))
                Text(detail).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(action, action: perform).buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
        }
        .padding(10)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // One button for a database in Docker on a server: what happens, plainly, and — for whoever wants it — exactly
    // what runs there.
    private func setUp(_ serverId: Int64, _ item: Postgres.Found) -> some View {
        let server = store.servers.first { $0.id == serverId }?.title ?? "the server"
        let preview = Postgres.createRoleCommand(in: item, sql: "…")?.replacingOccurrences(of: "echo \(Data("…".utf8).base64EncodedString())", with: "echo <the SQL below, base64>") ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(item.database) on \(server)").font(Fonts.ui(18, weight: .bold))
            explain("meepo will:")
            VStack(alignment: .leading, spacing: 6) {
                explain("1. Create a login \(Postgres.role) inside \(item.container) — as \(item.user), over the container's own socket, so no password is needed. It can only read (SELECT): every transaction is read only, a query stops after 15 s.")
                explain("2. Open an ssh tunnel from this Mac to it, kept open while meepo runs. The database port stays closed to the internet.")
                explain("3. Check that \(Postgres.role) can't change anything — and stop right there if it can.")
                explain("4. Add it to this project's .mcp.json as a server of its own (a backup is kept); your other servers stay as they are.")
            }
            DisclosureGroup("Exactly what runs on the server", isExpanded: $showsCommand) {
                ScrollView {
                    Text(preview + "\n\n" + Postgres.roleSQL(database: item.database, password: "<a new random password>"))
                        .font(Fonts.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 150)
                .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 8))
            }
            .font(Fonts.ui(12, weight: .semibold))
            asksToggle(default: true)
            if let progress {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.caption).foregroundStyle(Tokens.textDim) }
            }
            HStack {
                Button("← Back") { mode = .choose; error = nil }.disabled(busy)
                Spacer()
                Button(busy ? "Setting up…" : "Set it up") { setUpOnServer(serverId, item) }
                    .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                    .disabled(busy)
            }
        }
    }

    private func explain(_ text: String) -> some View {
        Text(text).font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
    }

    // 1. Where it is, and who that address logs in as.
    private var where_: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where is the database?").font(Fonts.ui(18, weight: .bold))
            explain("Pick the address Claude uses now, or paste one (postgresql://user:password@host:port/name). meepo connects read only to see who that user is — nothing in the database changes.")
            if !store.servers(of: projectId).isEmpty {
                HStack(spacing: 8) {
                    Text("It runs on").font(Fonts.ui(12, weight: .semibold))
                    PixelMenu(selection: store.servers(of: projectId).first { $0.id == serverId }?.title ?? "this Mac") {
                        Button("This Mac") { serverId = nil; owner = nil; onServer = [] }
                        ForEach(store.servers(of: projectId)) { server in
                            Button(server.title) { serverId = server.id; owner = nil; onServer = []; if let id = server.id { find(on: id) } }
                        }
                    }
                }
                if let serverId {
                    explain("The address as the server sees it — Find on server looks for Postgres containers there. meepo reaches it through an ssh tunnel it keeps open while it runs; the database port stays closed to the internet.")
                    VStack(alignment: .leading, spacing: 4) {
                        Button(busy ? "Looking…" : "Find on server") { find(on: serverId) }.disabled(busy)
                        ForEach(onServer, id: \.self) { url in
                            Button(url) { ownerURL = url; owner = nil }.buttonStyle(.plain).font(Fonts.mono(12))
                                .foregroundStyle(url == ownerURL ? Tokens.text : Tokens.textDim)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            if !found.isEmpty {
                Text("Found in this project").font(Fonts.ui(12, weight: .semibold))
                ForEach(found, id: \.self) { url in
                    Button(Postgres.masked(url)) { ownerURL = url; owner = nil }
                        .buttonStyle(.plain).font(Fonts.mono(12))
                        .foregroundStyle(url == ownerURL ? Tokens.text : Tokens.textDim)
                }
            }
            TextField("postgresql://user:password@127.0.0.1:5432/app", text: $ownerURL).textFieldStyle(.roundedBorder)
                .onChange(of: ownerURL) { owner = nil }
            HStack {
                Button(busy ? "Checking…" : "Check") { check() }.disabled(busy || Postgres.parts(of: ownerURL) == nil)
                if owner == nil {
                    Button("Skip — I'll run the SQL myself") { skipCheck() }
                        .disabled(busy || Postgres.parts(of: ownerURL)?.database == nil)
                        .help("No owner password needed: the next step shows the SQL to run yourself, e.g. with docker exec … psql on the server")
                }
                if let owner {
                    Text(owner.canWrite
                         ? "Connected as \(owner.user) — this user can change data. Claude shouldn't use it: the next step makes one that can't."
                         : "Connected as \(owner.user) — it can only read already.")
                        .font(.caption).foregroundStyle(owner.canWrite ? Tokens.warn : Tokens.added).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let owner {
                HStack {
                    Spacer()
                    if !owner.canWrite {
                        Button("Make a separate role anyway") { usesAsItIs = false; step = 2; error = nil }
                        // A user that can only read already (made by hand, in DBeaver): Claude gets it as it is.
                        Button("Next: Claude uses \(owner.user)") { usesAsItIs = true; step = 3; error = nil }
                            .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                    } else {
                        Button("Next: a read-only role") { usesAsItIs = false; step = 2; error = nil }
                            .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                    }
                }
            }
        }
    }

    // 2. The role, explained, run by the owner once.
    private var role: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A role that can only read").font(Fonts.ui(18, weight: .bold))
            explain("This makes \(Postgres.role): it can log in and read (SELECT) every table in \(database), now and later ones. Every transaction is read only and a query stops after 15 s. It can't change data or tables — the database itself refuses. Creating it needs the owner (\(owner?.user ?? "that user")), once.")
            ScrollView {
                Text(sql).font(Fonts.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 180)
            .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 8))
            explain("Either run it here as \(owner?.user ?? "the owner"), or copy it into DBeaver and run it there — then check.")
            HStack {
                Button("Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                }
                Button("Run it as \(owner?.user ?? "owner")") { confirmRun() }.disabled(busy)
                Button(busy ? "Checking…" : "Check the role") { checkRole() }.disabled(busy)
                Spacer()
                Button("← Back") { step = 1 }
            }
            if roleChecked {
                HStack {
                    Text("✓ \(Postgres.role) logs in and can't change anything.").font(.caption).foregroundStyle(Tokens.added)
                    Spacer()
                    Button("Next: Claude uses it") { step = 3; error = nil }.buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                }
            }
        }
    }

    // 3. Claude's postgres server switches to the role.
    private var claude: some View {
        let user = usesAsItIs ? owner?.user ?? "that user" : Postgres.role
        let url = usesAsItIs ? connectURL : roleURL
        return VStack(alignment: .leading, spacing: 10) {
            Text("Claude reads as \(user)").font(Fonts.ui(18, weight: .bold))
            explain(usesAsItIs
                    ? "This project's .mcp.json gets a postgres server for this database, logging in as \(user) — it can only read. Your other servers stay as they are; a backup of the file goes to ~/.meepo/backups (Tools → Changes can undo it). Claude reads .mcp.json when a session starts."
                    : "In this project's .mcp.json, Claude's postgres server switches from \(owner?.user ?? "the old user") to \(Postgres.role). A backup of the file goes to ~/.meepo/backups (Tools → Changes can undo it). Claude reads .mcp.json when a session starts.")
            Text(usesAsItIs ? Postgres.masked(connectURL) : "\(Postgres.masked(ownerURL))  →  \(Postgres.masked(roleURL ?? ""))")
                .font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
            asksToggle(default: tunnel != nil || !Postgres.isLocal(connectURL))
            HStack {
                Spacer()
                Button("← Back") { step = usesAsItIs ? 1 : 2 }
                Button(usesAsItIs ? "Give it to Claude" : "Switch Claude") { if let url { add(url: url, switchingFrom: connectURL) } }
                    .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
            }
        }
    }

    // 4. Done: restart the project's sessions, and the schema.
    private var done: some View {
        let running = store.sessions.filter { $0.projectId == projectId && $0.sshHost == nil && $0.id.map(store.runningSessionIds.contains) == true }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Done").font(Fonts.ui(18, weight: .bold))
            explain("Claude reads \(database) as \(usesAsItIs ? owner?.user ?? "that user" : Postgres.role): it can look at data, never change it. Ask it, for example: “which tables hold payments, and how many rows came in yesterday?”")
            if !running.isEmpty, !restarted {
                explain("\(running.count == 1 ? "1 session" : "\(running.count) sessions") of this project started before the change. A restart continues the same conversation with the new access.")
                Button("Restart \(running.count == 1 ? "it" : "them")") {
                    for session in running { if let id = session.id { store.restartSession(id) } }
                    restarted = true
                }
            }
            HStack {
                if let added { Button("Open the schema") { schemaOf = added } }
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
            }
        }
    }

    // MARK: Actions

    private func setUpOnServer(_ serverId: Int64, _ item: Postgres.Found) {
        busy = true; error = nil
        Task {
            do {
                added = try await store.setUpOnServer(projectId: projectId, serverId: serverId, found: item,
                                                      asksEachQuery: asksEachQuery ?? true) { progress = $0 }
                ownerURL = item.url
                step = 4
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
            busy = false
        }
    }

    private func check() {
        busy = true; error = nil
        Task {
            if let serverId {
                // The tunnel first: a free local port forwarded to the address as the server sees it.
                guard let port = tunnel?.localPort ?? SSHTunnel.freePort(),
                      let target = SSHTunnel.throughTunnel(ownerURL, localPort: port) else {
                    error = "No free local port for the tunnel, or that isn't a postgres:// address."
                    busy = false
                    return
                }
                let next = AppStore.Tunnel(serverId: serverId, remoteHost: target.remoteHost, remotePort: target.remotePort, localPort: port)
                if next != tunnel { store.closeTunnel(AppStore.wizardTunnel) }
                tunnel = next
                guard store.openTunnel(AppStore.wizardTunnel, next), await store.waitForTunnel(next) else {
                    error = "The ssh tunnel didn't open — check that `ssh` to that server works in Terminal without a password."
                    busy = false
                    return
                }
            } else if tunnel != nil {
                store.closeTunnel(AppStore.wizardTunnel)
                tunnel = nil
            }
            switch await store.identity(at: connectURL) {
            case let .success(identity): owner = identity
            case let .failure(failure):
                // Nothing answering here, and the project has servers: the database is likely on one of them.
                let onServer = serverId == nil && !store.servers(of: projectId).isEmpty
                    && (failure.localizedDescription.contains("Connection refused") || failure.localizedDescription.contains("timeout"))
                error = failure.localizedDescription + (onServer ? " — if the database runs on a server, pick it in “It runs on” and type its address as the server sees it." : "")
            }
            busy = false
        }
    }

    /// Asks the server for its Postgres containers; one found goes straight into the address field.
    private func find(on serverId: Int64) {
        busy = true; error = nil
        Task {
            switch await store.findDatabases(on: serverId) {
            case let .success(found):
                onServer = found.map(\.url)
                if let first = onServer.first, onServer.count == 1 { ownerURL = first }
                if found.isEmpty { error = "No Postgres container runs on that server." }
            case let .failure(failure):
                error = failure.localizedDescription
            }
            busy = false
        }
    }

    /// On to the SQL without logging in as the owner — the role is made elsewhere; a server still gets its tunnel.
    private func skipCheck() {
        busy = true; error = nil
        Task {
            if let serverId {
                guard let port = tunnel?.localPort ?? SSHTunnel.freePort(),
                      let target = SSHTunnel.throughTunnel(ownerURL, localPort: port) else { busy = false; return }
                let next = AppStore.Tunnel(serverId: serverId, remoteHost: target.remoteHost, remotePort: target.remotePort, localPort: port)
                if next != tunnel { store.closeTunnel(AppStore.wizardTunnel) }
                tunnel = next
                if !store.openTunnel(AppStore.wizardTunnel, next) { error = "The ssh tunnel didn't open." }
            }
            busy = false
            if error == nil { step = 2 }
        }
    }

    private func confirmRun() {
        store.confirmation = PixelConfirmation(
            title: "Create \(Postgres.role) in \(database)?",
            message: "meepo runs the SQL shown as \(owner?.user ?? "the owner") — the only change it makes in the database. It adds a login that can only read; your data and tables aren't touched.",
            action: "Create the role", isDestructive: false
        ) {
            busy = true; error = nil
            Task {
                if case let .failure(failure) = await store.createReadOnlyRole(ownerURL: connectURL, sql: sql) {
                    error = failure.localizedDescription
                    busy = false
                    return
                }
                busy = false
                checkRole()
            }
        }
    }

    private func checkRole() {
        guard let roleURL else { return }
        busy = true; error = nil; roleChecked = false
        Task {
            switch await store.identity(at: roleURL) {
            case let .success(identity) where identity.user == Postgres.role && !identity.canWrite: roleChecked = true
            case let .success(identity): error = "\(identity.user) can still change data — the SQL didn't run as expected."
            case let .failure(failure): error = "\(Postgres.role) can't log in yet (\(failure.localizedDescription)). Run the SQL first."
            }
            busy = false
        }
    }

    /// Saves the database; Claude's .mcp.json switches from `old` when there's one to switch from.
    private func add(url: String, switchingFrom old: String?) {
        do {
            added = try store.addDatabase(projectId: projectId, url: url, switchingFrom: old, tunnel: tunnel,
                                          asksEachQuery: asksEachQuery ?? (tunnel != nil || !Postgres.isLocal(url)))
            step = 4; error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The schema: every table in a searchable list, and the chosen one drawn with its neighbours — read once, in one
/// query, then drawn from memory.
struct SchemaSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let database: ProjectDatabase
    @State private var tables: [Postgres.Table] = []
    @State private var selected: String?
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    @State private var took: Duration?
    /// Built once per load: table → tables pointing at it, so neighbours are a lookup, not a scan.
    @State private var incoming: [String: [String]] = [:]
    /// The chosen table's picture and how many tables link with it — worked out on a pick, never in body.
    @State private var diagram = ""
    @State private var linked = 0

    private var shown: [Postgres.Table] {
        search.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SCHEMA · \(database.label)").font(Fonts.title(16))
                if let took { Text("\(tables.count) tables · \(took.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))").font(.caption).foregroundStyle(Tokens.textDim) }
                Spacer()
                Button("Refresh") { load(refresh: true) }.disabled(loading)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Tokens.danger) }
            HStack(spacing: 10) {
                VStack(spacing: 6) {
                    TextField("Search tables", text: $search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { table in
                                Button { selected = table.name } label: {
                                    HStack {
                                        Text(table.name).font(Fonts.mono(12)).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("\(table.columns.count)").font(.caption2).foregroundStyle(Tokens.textDim)
                                    }
                                    .padding(.vertical, 4).padding(.horizontal, 6)
                                    .background(selected == table.name ? Tokens.workTint : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(width: 240)
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Tokens.surface)
                    // Kept while Refresh reads again: a new web view would load mermaid.js all over.
                    if !diagram.isEmpty {
                        MermaidView(text: diagram).padding(4)
                    } else if !loading {
                        Text("Pick a table: it's drawn with the tables it links to and from.").foregroundStyle(Tokens.textDim)
                    }
                    if loading { ProgressView().controlSize(.small) }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("drag to move · pinch or ⌘-scroll to zoom").font(.caption2).foregroundStyle(Tokens.textDim).padding(8)
                }
                .overlay(alignment: .topLeading) {
                    if linked > Postgres.neighbourLimit {
                        Text("\(Postgres.neighbourLimit) of \(linked) linked tables shown — pick one on the left to put it in the middle")
                            .font(.caption).foregroundStyle(Tokens.textDim).padding(8)
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 980, minHeight: 640)
        .background(Tokens.grass)
        .buttonStyle(PixelButtonStyle(compact: true))
        .task { load(refresh: false) }
        .onChange(of: selected) { draw() }
    }

    private func draw() {
        guard let selected else { diagram = ""; linked = 0; return }
        diagram = Postgres.mermaid(around: selected, in: tables)
        linked = Postgres.neighbours(of: selected, in: tables).count
    }

    private func load(refresh: Bool) {
        loading = true; error = nil
        Task {
            let start = ContinuousClock.now
            switch await store.schema(of: database, refresh: refresh) {
            case let .success(result):
                tables = result
                took = ContinuousClock.now - start
                incoming = Dictionary(grouping: result.flatMap { table in table.fks.map { ($0.table, table.name) } }, by: \.0)
                    .mapValues { $0.map(\.1) }
                // The most connected table first: the middle of the picture.
                if selected == nil {
                    selected = result.max { links($0) < links($1) }?.name
                } else {
                    draw()
                }
            case let .failure(failure):
                error = failure.localizedDescription
            }
            loading = false
        }
    }

    private func links(_ table: Postgres.Table) -> Int {
        table.fks.count + (incoming[table.name]?.count ?? 0)
    }
}
