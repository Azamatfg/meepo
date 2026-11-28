import Foundation
import GRDB

/// A production AI agent of the user's (a support bot on the Claude API), running in a container on one of the
/// project's servers. Meepo only reads: is it up, did it restart, what errors it logged today.
struct ProdAgent: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "prodAgent"
    var id: Int64?
    var projectId: Int64
    var serverId: Int64
    var name: String
    var container: String
    /// Where its code is, for "Investigate" (nil = the project's folder).
    var folder: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

enum ProdAgents {
    /// One container's state and its last day of error lines.
    struct Health: Equatable {
        var state: String
        var startedAt: String = ""
        var restarts = 0
        var errors: [String] = []
        var checkedAt: Date
        /// Why the check itself failed (ssh, a dead host), in plain words.
        var problem: String?

        var isUp: Bool { state == "running" && problem == nil }
    }

    /// The only command that runs on the server for an agent: a read-only template around a name ServerLogs
    /// accepts (letters, digits, . _ -), quoted whole. nil for any other name.
    static func statusCommand(container: String) -> String? {
        guard ServerLogs.isValid(LogSource(kind: .docker, name: container)) else { return nil }
        let name = "'\(container)'"
        return "docker inspect -f '{{.State.Status}}|{{.State.StartedAt}}|{{.RestartCount}}' \(name); echo '---'; "
            + "docker logs --since 24h \(name) 2>&1 | grep -iE 'error|exception|traceback|panic' | tail -n 20"
    }

    static func health(from output: String, checkedAt: Date) -> Health {
        let parts = output.components(separatedBy: "\n---\n")
        let head = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fields = head.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let errors = parts.dropFirst().joined(separator: "\n").split(separator: "\n").map(String.init)
            .map { ServerLogs.trim($0, lines: 1, limit: 300) }.filter { !$0.isEmpty }
        guard fields.count == 3, let restarts = Int(fields[2]) else {
            return Health(state: "missing", errors: errors, checkedAt: checkedAt) // "No such object": not on this server
        }
        return Health(state: fields[0], startedAt: fields[1], restarts: restarts, errors: errors, checkedAt: checkedAt)
    }
}

extension AppStore {
    func reloadProdAgents() {
        prodAgents = (try? db.read { try ProdAgent.order(Column("name")).fetchAll($0) }) ?? []
    }

    @discardableResult
    func addProdAgent(name: String, projectId: Int64, serverId: Int64, container: String, folder: String? = nil) -> ProdAgent? {
        guard ProdAgents.statusCommand(container: container) != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var agent = ProdAgent(projectId: projectId, serverId: serverId, name: name.trimmingCharacters(in: .whitespaces),
                              container: container, folder: folder)
        try? db.write { try agent.insert($0) }
        reloadProdAgents()
        return agent
    }

    func removeProdAgent(_ id: Int64) {
        _ = try? db.write { try ProdAgent.deleteOne($0, id: id) }
        prodAgentHealth[id] = nil
        reloadProdAgents()
    }

    /// The agents of the workspace shown.
    var workspaceProdAgents: [ProdAgent] {
        let ids = Set(workspaceProjects.compactMap(\.id))
        return prodAgents.filter { ids.contains($0.projectId) }
    }

    /// Each agent's status template over ssh, side by side, off the main thread.
    func checkProdAgents() async {
        let runner = sshRunner
        let hosts = Dictionary(uniqueKeysWithValues: servers.compactMap { s in s.id.map { ($0, s.host) } })
        let jobs = prodAgents.compactMap { agent -> (Int64, String, String)? in
            guard let id = agent.id, let host = hosts[agent.serverId], let command = ProdAgents.statusCommand(container: agent.container)
            else { return nil }
            return (id, host, command)
        }
        let results = await withTaskGroup(of: (Int64, ProdAgents.Health).self) { group in
            for (id, host, command) in jobs {
                group.addTask {
                    let now = Date.now
                    guard let args = ServerLogs.sshArguments(host: host, command: command) else {
                        return (id, ProdAgents.Health(state: "unknown", checkedAt: now, problem: "“\(host)” isn't an ssh address."))
                    }
                    let result = runner(ServerLogs.ssh, args, ServerLogs.timeout)
                    if result.timedOut || result.status == 255 {
                        return (id, ProdAgents.Health(state: "unknown", checkedAt: now,
                                                      problem: result.timedOut ? "\(host) didn't answer." : "ssh couldn't log in to \(host)."))
                    }
                    return (id, ProdAgents.health(from: result.output, checkedAt: now))
                }
            }
            var all: [(Int64, ProdAgents.Health)] = []
            for await item in group { all.append(item) }
            return all
        }
        for (id, health) in results { prodAgentHealth[id] = health }
    }

    /// INVESTIGATE: a Claude Code session in the agent's code with what the server said; it reads and reasons, the
    /// server is not touched from it.
    func investigate(_ agent: ProdAgent) {
        let health = agent.id.flatMap { prodAgentHealth[$0] }
        let host = servers.first { $0.id == agent.serverId }?.host ?? "?"
        var prompt = "Разберись, что с продакшн-агентом «\(agent.name)» (контейнер \(agent.container) на \(host)). "
        if let health {
            prompt += "Состояние: \(health.state), рестартов: \(health.restarts), запущен: \(health.startedAt). "
            if !health.errors.isEmpty { prompt += "Ошибки за 24 часа:\n" + health.errors.joined(separator: "\n") + "\n" }
        }
        prompt += "Найди причину по коду\(agent.folder.map { " в \($0)" } ?? ""), предложи исправление. На сервере ничего не меняй."
        do { try createSession(projectId: agent.projectId, model: nil, prompt: prompt) } catch { bridgeError = error.localizedDescription }
    }
}
