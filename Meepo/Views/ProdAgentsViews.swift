import SwiftUI

/// Home's production agents (2026-11-28): one card each — up or not, restarts, today's errors — and INVESTIGATE,
/// a Claude Code session in its code with what the server said. Checked when Home opens and every 5 minutes on it.
struct ProdAgentsSection: View {
    @Environment(AppStore.self) private var store
    let isRussian: Bool
    @State private var isAdding = false
    @State private var statsFor: ProdAgent?

    private func t(_ en: String, _ ru: String) -> String { isRussian ? ru : en }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("AGENTS IN PRODUCTION", "АГЕНТЫ НА ПРОДЕ")).font(Fonts.ui(11, weight: .bold)).tracking(1.4).foregroundStyle(Tokens.textDim)
                Spacer()
                Button(t("+ ADD", "+ ДОБАВИТЬ")) { isAdding = true }.buttonStyle(PixelButtonStyle(compact: true))
                    .help(t("An agent of yours running in a container on a project's server", "Твой агент в контейнере на сервере проекта"))
            }
            if store.workspaceProdAgents.isEmpty {
                Text(t("None yet. Meepo only reads: is it up, restarts, the day's errors.",
                       "Пока нет. Meepo только читает: жив ли, рестарты, ошибки за день."))
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
            ForEach(store.workspaceProdAgents) { agent in card(agent) }
        }
        .sheet(isPresented: $isAdding) { AddProdAgentSheet(isRussian: isRussian) }
        .sheet(item: $statsFor) { ProdAgentStatsSheet(agent: $0, isRussian: isRussian) }
        .task {
            while !Task.isCancelled {
                await store.checkProdAgents()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func card(_ agent: ProdAgent) -> some View {
        let health = agent.id.flatMap { store.prodAgentHealth[$0] }
        let project = store.projects.first { $0.id == agent.projectId }?.name ?? "?"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(health == nil ? Tokens.idle : health!.isUp ? Tokens.added : Tokens.need).frame(width: 8, height: 8)
                Text(agent.name).font(Fonts.ui(14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(t("INVESTIGATE", "РАЗОБРАТЬСЯ")) { store.investigate(agent) }
                    .buttonStyle(PixelButtonStyle(compact: true, isPrimary: health.map { !$0.isUp || !$0.errors.isEmpty } ?? false))
                    .help(t("A Claude Code session in its code with today's errors; the server isn't touched from it",
                            "Сессия Claude Code в его коде с ошибками за день; сервер из неё не трогается"))
            }
            Text("\(project) · \(agent.container)").font(.caption).foregroundStyle(Tokens.textDim)
            if let health {
                if let problem = health.problem {
                    Text(problem).font(.caption).foregroundStyle(Tokens.need)
                } else {
                    Text(status(health)).font(Fonts.ui(12)).foregroundStyle(health.isUp ? Tokens.text : Tokens.need)
                    if let last = health.errors.last {
                        Text(last).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(2).truncationMode(.middle)
                    }
                }
            } else {
                Text(t("Checking…", "Проверяю…")).font(.caption).foregroundStyle(Tokens.textDim)
            }
            if let id = agent.id, let stats = store.prodAgentStats[id] {
                Text(day(stats)).font(Fonts.ui(12, weight: .semibold))
                    .foregroundStyle(stats.unanswered > 0 || stats.failed > 0 ? Tokens.need : Tokens.text)
            } else if let id = agent.id, let problem = store.prodAgentStatsProblem[id] {
                Text(t("Day's numbers: ", "Цифры дня: ") + problem).font(.caption).foregroundStyle(Tokens.need).lineLimit(2)
            } else if agent.statsScript == nil {
                Button(t("Add the day's numbers…", "Добавить цифры дня…")) { statsFor = agent }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Tokens.work)
            } else if ProdAgents.statsCommand(for: agent) == nil {
                Button(t("The day's numbers wait for your approval…", "Цифры дня ждут твоего подтверждения…")) { statsFor = agent }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Tokens.need)
            }
        }
        .padding(12)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(health.map { $0.isUp ? Tokens.line : Tokens.need } ?? Tokens.line))
        .contextMenu {
            Button(t("The Day's Numbers…", "Цифры дня…")) { statsFor = agent }
            Button(t("Remove from meepo", "Убрать из meepo")) { if let id = agent.id { store.removeProdAgent(id) } }
        }
    }

    private func day(_ s: ProdAgents.Stats) -> String {
        let period = s.period == "today" ? t("today", "сегодня") : t("24 h", "за 24 ч")
        return isRussian
            ? "\(period): диалогов \(s.dialogs) · без ответа \(s.unanswered) · сбоев \(s.failed) · ждут человека \(s.handoffs) · $\(String(format: "%.2f", s.costUSD))"
            : "\(period): \(s.dialogs) dialogs · \(s.unanswered) unanswered · \(s.failed) failed · \(s.handoffs) wait for a person · $\(String(format: "%.2f", s.costUSD))"
    }

    private func status(_ health: ProdAgents.Health) -> String {
        let state = switch health.state {
        case "running": t("running", "работает")
        case "restarting": t("restarting", "перезапускается")
        case "exited", "dead": t("stopped", "остановлен")
        case "missing": t("no such container on the server", "такого контейнера на сервере нет")
        default: health.state
        }
        var parts = [state]
        if health.restarts > 0 { parts.append(t("\(health.restarts) restarts", "рестартов: \(health.restarts)")) }
        parts.append(t("\(health.errors.count) errors in 24 h", "ошибок за 24 ч: \(health.errors.count)"))
        return parts.joined(separator: " · ")
    }
}

/// Picks a project's server, one of its running containers, and a name.
struct AddProdAgentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let isRussian: Bool
    @State private var serverId: Int64?
    @State private var containers: [String] = []
    @State private var container = ""
    @State private var name = ""
    @State private var problem: String?

    private func t(_ en: String, _ ru: String) -> String { isRussian ? ru : en }
    private var servers: [Server] {
        let ids = Set(store.workspaceProjects.compactMap(\.id))
        return store.servers.filter { ids.contains($0.projectId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Add an agent", "Добавить агента")).font(Fonts.ui(20, weight: .bold))
            Text(t("Meepo reads its container over ssh: state, restarts, error lines of the last day. Nothing else runs there.",
                   "Meepo читает его контейнер по ssh: состояние, рестарты, строки ошибок за сутки. Больше там ничего не запускается."))
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            if servers.isEmpty {
                Text(t("No servers in this workspace's projects yet — add one in the project's Servers.",
                       "В проектах этого workspace нет серверов — добавь сервер в проекте."))
                    .foregroundStyle(Tokens.need)
            }
            Picker(t("Server", "Сервер"), selection: $serverId) {
                Text("—").tag(Int64?.none)
                ForEach(servers) { server in
                    Text("\(store.projects.first { $0.id == server.projectId }?.name ?? "?") · \(server.title)").tag(Int64?.some(server.id!))
                }
            }
            .onChange(of: serverId) { load() }
            Picker(t("Container", "Контейнер"), selection: $container) {
                Text("—").tag("")
                ForEach(containers, id: \.self) { Text($0).tag($0) }
            }
            .disabled(containers.isEmpty)
            TextField(t("Name, e.g. Support", "Имя, например Техподдержка"), text: $name).textFieldStyle(.roundedBorder)
            if let problem { Text(problem).font(.caption).foregroundStyle(Tokens.need) }
            HStack {
                Spacer()
                Button(t("Cancel", "Отмена")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button(t("Add", "Добавить")) {
                    guard let serverId, let server = servers.first(where: { $0.id == serverId }) else { return }
                    if store.addProdAgent(name: name.isEmpty ? container : name, projectId: server.projectId, serverId: serverId, container: container) != nil {
                        Task { await store.checkProdAgents() }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PixelButtonStyle(isPrimary: true))
                .disabled(serverId == nil || container.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .paperSheet()
    }

    private func load() {
        containers = []
        container = ""
        problem = nil
        guard let host = servers.first(where: { $0.id == serverId })?.host else { return }
        Task {
            switch await store.listContainers(on: host) {
            case let .success(list): containers = list
            case let .failure(error): problem = error.text
            }
        }
    }
}

/// The day's numbers for one agent: the script that counts them inside its container, approved as written.
/// Meepo runs exactly what was approved; any change waits for approval again.
struct ProdAgentStatsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: ProdAgent
    let isRussian: Bool
    @State private var runner = ProdAgents.runners[0]
    @State private var script = ""
    @State private var isRunning = false

    private func t(_ en: String, _ ru: String) -> String { isRussian ? ru : en }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("The day's numbers · \(agent.name)", "Цифры дня · \(agent.name)")).font(Fonts.ui(20, weight: .bold))
            Text(t("A script that runs inside \(agent.container) and prints one JSON line: period (today or 24h), dialogs, unanswered, failed, handoffs, costUSD. It should only read. Meepo runs exactly what you approve here, every 5 minutes while Home is open.",
                   "Скрипт выполняется внутри \(agent.container) и печатает одну строку JSON: period (today или 24h), dialogs, unanswered, failed, handoffs, costUSD. Он должен только читать. Meepo запускает ровно то, что ты здесь подтвердишь, раз в 5 минут, пока открыт Home."))
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            Picker(t("Runs as", "Запуск"), selection: $runner) {
                ForEach(ProdAgents.runners, id: \.self) { Text("docker exec -i \(agent.container) \($0)").tag($0) }
            }
            TextEditor(text: $script)
                .font(Fonts.mono(12))
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tokens.line))
            if let id = agent.id {
                if let stats = store.prodAgentStats[id] {
                    Text(t("Last run: ", "Последний запуск: ") + "\(stats.dialogs) / \(stats.unanswered) / \(stats.failed) / \(stats.handoffs) / $\(String(format: "%.2f", stats.costUSD))")
                        .font(.caption).foregroundStyle(Tokens.added)
                } else if let problem = store.prodAgentStatsProblem[id] {
                    Text(problem).font(Fonts.mono(11)).foregroundStyle(Tokens.need).lineLimit(4)
                }
            }
            HStack {
                if ProdAgents.statsCommand(for: agent) != nil, agent.statsScript == script, agent.statsRunner == runner {
                    Text(t("Approved as written.", "Подтверждено в этом виде.")).font(.caption).foregroundStyle(Tokens.textDim)
                }
                Spacer()
                Button(t("Close", "Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button(isRunning ? t("Running…", "Запускаю…") : t("Approve and run", "Подтвердить и запустить")) {
                    guard let id = agent.id else { return }
                    isRunning = true
                    Task { await store.approveStats(id, runner: runner, script: script); isRunning = false }
                }
                .buttonStyle(PixelButtonStyle(isPrimary: true))
                .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
                .help(t("Saves this script as approved and runs it once now", "Сохраняет скрипт как подтверждённый и сразу запускает один раз"))
            }
        }
        .padding(22)
        .frame(width: 720)
        .paperSheet()
        .onAppear {
            runner = agent.statsRunner ?? ProdAgents.runners[0]
            script = agent.statsScript ?? ""
        }
    }
}
