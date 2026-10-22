import Foundation
import os

/// MORNING's brief: what happened since Claude's last answer and what waits for the person now, per project.
/// Read from what meepo already has (CI, pipelines, sessions) plus one `git log` per folder — no model, no tokens.
enum Brief {
    struct Item: Equatable, Identifiable {
        enum Kind: Equatable { case ciFailed, waitsForYou, teammates, session }
        let kind: Kind
        /// The project it's shown under.
        let project: String
        let text: String
        /// Teammates' commits, "Rustem: fix …".
        var lines: [String] = []
        var url: String? = nil
        var sessionId: Int64? = nil
        var id: String { "\(kind)|\(project)|\(text)|\(url ?? "")|\(sessionId ?? 0)" }
    }

    /// Runs that ended failed after `since`; one that started before but ended after counts too.
    static func failedRuns(_ runs: [CIRun], since: Date) -> [CIRun] {
        runs.filter { $0.failed && ($0.updatedAt ?? $0.createdAt) > since }
    }

    /// Manual steps (a deploy) that may start now.
    static func waitingSteps(_ pipeline: Pipeline?) -> [Pipeline.Step] {
        pipeline.map { p in p.steps.filter { $0.state == .manual && p.canStart($0) } } ?? []
    }

    /// What a session waits on the person for, nil when it doesn't: after a Stop it's only done (also
    /// `.waitingInput`); a question Claude asked comes as a PermissionRequest.
    static func ask(_ status: SessionStatus, lastEvent: String?) -> String? {
        switch status {
        case .waitingPermission: "asks for permission"
        case .waitingInput where lastEvent == "PermissionRequest": "asks you a question"
        default: nil
        }
    }

    /// Lines of `git log --format=%ae%x09%an: %s` without the person's own: "Rustem: fix …".
    static func othersCommits(_ log: String, me: String) -> [String] {
        log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() != me.lowercased() else { return nil }
            return String(parts[1])
        }
    }

    /// Others' commits on the folder's upstream since `since`, newest first, as last fetched.
    static func teammateCommits(in path: String, since: Date) -> [String] {
        let me = GitService.output(["config", "user.email"], in: path) ?? ""
        let log = GitService.output(["log", "@{u}", "--since=\(since.ISO8601Format())", "--format=%ae%x09%an: %s", "-n", "30"], in: path)
        return othersCommits(log ?? "", me: me)
    }

    /// Every folder fetched and read side by side (each waits on the network): path → others' commits.
    static func teammateCommits(in paths: [String], since: Date) -> [String: [String]] {
        let found = OSAllocatedUnfairLock(initialState: [String: [String]]())
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            GitPanel.fetch(in: paths[index])
            let lines = teammateCommits(in: paths[index], since: since)
            found.withLock { $0[paths[index]] = lines }
        }
        return found.withLock { $0 }
    }
}

extension AppStore {
    /// Empty before Claude's first answer: there's no "since" yet. Fetches every project folder first.
    func brief() async -> [Brief.Item] {
        guard let since = lastAnswerAt() else { return [] }
        let paths = Array(Set(projects.flatMap { [$0.path] + (nestedRepos[$0.path] ?? []).map(\.path) }))
        let commits = await Task.detached { Brief.teammateCommits(in: paths, since: since) }.value
        var items: [Brief.Item] = []
        for project in projects {
            guard let id = project.id else { continue }
            let repos = nestedRepos[project.path] ?? []
            let ci = [(nil as String?, ciRuns[id] ?? [], pipelines[id])] + repos.map { ($0.name, repoCI[$0.path]?.runs ?? [], repoCI[$0.path]?.pipeline) }
            for (repo, runs, pipeline) in ci {
                let prefix = repo.map { "\($0) · " } ?? ""
                items += Brief.failedRuns(runs, since: since).map {
                    Brief.Item(kind: .ciFailed, project: project.name, text: "\(prefix)\($0.workflowName) failed on \($0.headBranch)", url: $0.url)
                }
                if let pipeline {
                    items += Brief.waitingSteps(pipeline).map {
                        Brief.Item(kind: .waitsForYou, project: project.name,
                                   text: "\(prefix)\($0.name) waits for you — \(Pipeline.commitLabel(title: pipeline.title, sha: pipeline.sha))", url: $0.url)
                    }
                }
            }
            for (repo, path) in [(nil as String?, project.path)] + repos.map({ ($0.name, $0.path) }) {
                guard let lines = commits[path], !lines.isEmpty else { continue }
                let prefix = repo.map { "\($0) · " } ?? ""
                items.append(Brief.Item(kind: .teammates, project: project.name,
                                        text: "\(prefix)\(lines.count) new commit\(lines.count == 1 ? "" : "s") from teammates", lines: lines))
            }
            for session in sessions where session.projectId == id {
                if let ask = Brief.ask(session.status, lastEvent: session.id.flatMap { lastTurnEvents[$0] }) {
                    items.append(Brief.Item(kind: .session, project: project.name, text: "\(displayName(of: session)) \(ask)", sessionId: session.id))
                }
            }
        }
        for agent in elsewhere where agent.needsYou {
            items.append(Brief.Item(kind: .session, project: agent.folderName, text: "\(agent.title) (background) waits for you"))
        }
        return items
    }
}
