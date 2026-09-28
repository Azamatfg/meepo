import Foundation

/// Units of work, read from git: each push the user made (the upstream's reflog records it as "update by push"),
/// and what isn't sent yet — each with the requests that led to it. A push is a fact about a folder, not a
/// session, so every session working there adds its requests. Without an upstream a commit no remote has is the
/// unit; without git, only the requests are.
enum Work {
    struct Commit: Equatable, Identifiable {
        let sha: String
        let subject: String
        let date: Date
        var id: String { sha }

        /// feat and fix are what users notice. The rest is shown dim but never hidden: "chore(mobile): 1.7.8+91" is a release.
        var isNotable: Bool { subject.range(of: #"^(feat|fix)(\([^)]*\))?!?:"#, options: .regularExpression) != nil }

        /// "feat(loans): импорт графика из Excel" → "Импорт графика из Excel".
        var title: String {
            let bare = subject.replacingOccurrences(of: #"^[a-z]+(\([^)]*\))?!?:\s*"#, with: "", options: .regularExpression)
            return bare.prefix(1).uppercased() + bare.dropFirst()
        }
    }

    /// One push to the upstream: the commits it sent, and since when requests count towards it.
    struct Send: Equatable, Identifiable {
        let at: Date
        /// The compare view's left side: the upstream before the push (after a force push, the common ancestor).
        let from: String
        let to: String
        /// The push before this one; requests between the two led to this one. Nil = none known.
        let after: Date?
        /// Newest first.
        var commits: [Commit]
        var files: Int
        var id: String { "sent:" + to }

        /// Its first feat/fix, else its first commit: "Импорт графика из Excel".
        var title: String { (commits.last(where: \.isNotable) ?? commits.last)?.title ?? "" }
    }

    struct Repo: Equatable, Identifiable {
        let name: String
        let path: String
        var branch = ""
        /// "origin/main"; nil = the branch isn't on a remote.
        var upstream: String?
        /// Where pushes go, as people say it: "GitHub", "GitLab", else the remote's name.
        var host = "the remote"
        /// There is somewhere to push to (a local-only repo has nothing to send).
        var hasRemote = false
        var head: String?
        /// Files not committed yet.
        var uncommitted: [String] = []
        /// Committed, not pushed; newest first.
        var unsent: [Commit] = []
        /// The last week's pushes, oldest first.
        var sends: [Send] = []
        /// Without an upstream: the last week's commits no remote has yet, oldest first — each one a unit.
        var commits: [Commit] = []
        var id: String { path }

        /// The upstream's branch: "origin/main" → "main".
        var upstreamBranch: String { upstream.map { String($0.split(separator: "/", maxSplits: 1).last ?? "") } ?? branch }
    }

    /// What meepo knows about one folder a session works in.
    struct Folder: Equatable {
        /// Its git repos (usually one); empty = not in git — once `isGitRead`.
        var repos: [Repo] = []
        /// Git has been read at least once. Until then the requests are there but nothing is known about pushes,
        /// so views say "Reading git…" rather than "this folder isn't in git".
        var isGitRead = false
        /// Every request made in the folder over the last week, by any session there; oldest first.
        var runs: [Run] = []
        /// Explain for users, by `Unit.key`.
        var summaries: [String: ProductSummary] = [:]
    }

    struct Unit: Identifiable, Equatable {
        enum Kind: Equatable { case now, sent(Send), committed(Commit), requests }
        let kind: Kind
        /// Oldest first.
        var runs: [Run]
        let id: String
        /// What its Explain is kept under; for NOW it changes with what isn't sent, so an old text never shows.
        let key: String
        let date: Date

        /// Commits it holds, newest first (NOW: the ones not sent yet).
        func commits(in repo: Repo?) -> [Commit] {
            switch kind {
            case .sent(let send): send.commits
            case .committed(let commit): [commit]
            case .now: repo?.unsent ?? []
            case .requests: []
            }
        }

        /// A line for lists: the first feat/fix, else the first commit, else the latest request that edited
        /// files, else the latest request.
        func title(in repo: Repo?) -> String {
            let commits = commits(in: repo)
            if let commit = commits.last(where: \.isNotable) ?? commits.last { return commit.title }
            let run = runs.last { !$0.files.isEmpty } ?? runs.last
            return run.map { Notifier.plainText($0.request, limit: 80) } ?? "Changes"
        }
    }

    /// Newest first, NOW on top when anything isn't sent: uncommitted files, commits not pushed, or requests since
    /// the last push. Requests older than the oldest push's predecessor belong to work from before and drop out.
    static func units(_ repo: Repo?, runs: [Run], now: Date = .now) -> [Unit] {
        guard let repo else {
            return runs.isEmpty ? [] : [Unit(kind: .requests, runs: runs, id: "requests",
                                             key: "requests:\(runs.last!.startedAt.timeIntervalSince1970)", date: runs.last!.startedAt)]
        }
        var units: [Unit] = []
        var rest = runs
        func take(until date: Date, after: Date?) -> [Run] {
            let mine = rest.filter { run in run.startedAt <= date && after.map { run.startedAt > $0 } ?? true }
            rest.removeAll { $0.startedAt <= date }
            return mine
        }
        if repo.upstream != nil {
            for send in repo.sends {
                units.append(Unit(kind: .sent(send), runs: take(until: send.at, after: send.after), id: send.id, key: send.id, date: send.at))
            }
        } else {
            for (index, commit) in repo.commits.enumerated() {
                let after = index > 0 ? repo.commits[index - 1].date : nil
                units.append(Unit(kind: .committed(commit), runs: take(until: commit.date, after: after),
                                  id: "commit:" + commit.sha, key: "commit:" + commit.sha, date: commit.date))
            }
        }
        if !repo.uncommitted.isEmpty || !repo.unsent.isEmpty || !rest.isEmpty {
            let state = [repo.head ?? "", repo.uncommitted.joined(separator: ","), "\(rest.last?.startedAt.timeIntervalSince1970 ?? 0)"]
            // Per repo: a folder of several repos has a NOW each, and Today lists them side by side.
            units.append(Unit(kind: .now, runs: rest, id: "now:" + repo.path, key: "now:" + String(state.joined(separator: "|").hashValueStable),
                              date: rest.last?.startedAt ?? now))
        }
        return units.reversed()
    }

    /// In a folder holding several repos, a request belongs to the repo whose files it edited; the rest to the first.
    static func runs(_ runs: [Run], for repo: Repo, in repos: [Repo]) -> [Run] {
        guard repos.count > 1 else { return runs }
        return runs.filter { run in
            let owner = repos.first { repo in run.files.contains { $0.hasPrefix(repo.path + "/") } } ?? repos.first
            return owner?.path == repo.path
        }
    }

    /// What's still to do with NOW, and how.
    static func nextStep(_ repo: Repo) -> String? {
        if !repo.uncommitted.isEmpty {
            return "Next: commit — ask Claude to “commit this”. Until then it's only on this Mac."
        }
        if repo.upstream == nil, repo.hasRemote, repo.head != nil, repo.branch != "HEAD" { // a detached HEAD isn't a branch
            return "Next: publish the branch — Publish in Source Control, or ask Claude to push it."
        }
        if !repo.unsent.isEmpty {
            return "Next: send it — Push in Source Control, or ask Claude to push. Then CI and deploy can pick it up."
        }
        return nil
    }

    // MARK: Home — what a card and Today say

    /// "11:53" today, "Mon 11:53" earlier.
    static func when(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// What isn't sent, as chips: "4 files not committed", "1 commit not sent", "Branch not on GitHub yet".
    static func pending(_ repos: [Repo]) -> [String] {
        let files = repos.reduce(0) { $0 + $1.uncommitted.count }
        let commits = repos.reduce(0) { $0 + $1.unsent.count }
        let unpublished = repos.first { $0.upstream == nil && $0.hasRemote && $0.head != nil && $0.branch != "HEAD" }
        return [files > 0 ? "\(files) file\(files == 1 ? "" : "s") not committed" : nil,
                commits > 0 ? "\(commits) commit\(commits == 1 ? "" : "s") not sent" : nil,
                unpublished.map { "Branch not on \($0.host) yet" }].compactMap { $0 }
    }

    /// What CI waits on: a failed step, or a deploy that waits for the user's click.
    static func ciChips(_ pipeline: Pipeline?) -> [String] {
        guard let pipeline else { return [] }
        if pipeline.steps.contains(where: { $0.state == .failed }) { return ["CI failed"] }
        // "Deploy waits for you", not "Deploy ready": ready could read as done.
        if let ready = pipeline.steps.first(where: { $0.state == .manual && pipeline.canStart($0) }) { return ["\(ready.name) waits for you"] }
        return []
    }

    /// A card's main line from the session's last request: needs permission, asks something, works on a step,
    /// or the request and the gist of the answer. `status` is what the session is doing now — idle when it isn't
    /// running — so a status left over from before doesn't claim it needs you.
    static func cardLine(status: SessionStatus, run: Run?, last: EventStory.Line?) -> (label: String?, text: String, needsYou: Bool) {
        if status == .waitingPermission, let last, last.needsYou { return ("Needs permission", last.detail ?? last.title, true) }
        if status == .waitingInput, let last, last.needsYou, last.title.hasPrefix("Asked you") { return ("Asks", last.detail ?? last.title, true) }
        // Working again (a helper's report woke it up): the question it ended on is no longer the news.
        if status == .thinking, let last { return ("Now", last.title, false) }
        if let question = run?.question { return ("Asks", question, true) }
        guard let run else { return (nil, "Nothing asked this week", false) }
        let asked = "“\(Notifier.plainText(run.request, limit: 90))”"
        return (nil, run.gist.map { "\(asked) → \($0)" } ?? asked, false)
    }

    // MARK: Explain for users — one short `claude -p`, not a fork of the session

    /// The JSON Schema `claude -p --json-schema` checks the answer against.
    static let schema = """
        {"type":"object","properties":{
          "headline":{"type":"string"},
          "changes":{"type":"array","items":{"type":"object","properties":{
            "kind":{"type":"string","enum":["new","changed","fixed","removed"]},
            "what":{"type":"string"},"where":{"type":"string"}},"required":["kind","what","where"]}},
          "check":{"type":"array","items":{"type":"string"}},
          "how_to_try":{"type":"string"}},
         "required":["headline","changes","check","how_to_try"]}
        """

    /// The unit's material — the user's requests, Claude's answers, the commits and (for NOW) the diff — and
    /// what to write from it. A few thousand tokens, where a fork of the session re-read the whole conversation.
    static func prompt(runs: [Run], commits: String, diff: String?, language: String) -> String {
        var parts = ["""
            Below is one piece of work on a software product: what the user asked Claude Code for, what Claude \
            answered, the commits\(diff == nil ? "" : " and the changes not sent yet"). Describe what it changes for \
            the people who use the product — not for developers. Write in the language of the user's requests \
            (\(language) if there are none).
            - headline: one sentence, the change as a user would put it.
            - changes: each change users will see: kind (new/changed/fixed/removed), what they can now do or will \
            notice, and where — the section of the product, then the place ("Leasing → Loan card"); "where" is empty \
            for changes users don't see.
            - check: open questions and risky spots to confirm (money, accounts, data, permissions, anything assumed); \
            empty if none.
            - how_to_try: how the user can see it themselves; empty if there's nothing to try.
            No code, no file names, no invented details — only what the material below shows.
            """]
        let requests = runs.suffix(15).enumerated().map { index, run in
            "\(index + 1). Asked: \(run.request.prefix(1_500))"
                + (run.reply.map { "\n   Claude answered: \($0.prefix(1_500))" } ?? "")
        }
        if !requests.isEmpty { parts.append("<requests>\n" + requests.joined(separator: "\n") + "\n</requests>") }
        if !commits.isEmpty { parts.append("<commits>\n\(commits.prefix(8_000))\n</commits>") }
        if let diff, !diff.isEmpty { parts.append("<diff>\n\(diff.prefix(20_000))\n</diff>") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Reading git (blocking — call off the main thread)

    /// The folder's repos as units of work need them; pushes and commits since `since`.
    static func read(_ repos: [(name: String, path: String)], since: Date) -> [Repo] {
        repos.compactMap { read(name: $0.name, path: $0.path, since: since) }
    }

    static func read(name: String, path: String, since: Date) -> Repo? {
        guard GitService.output(["rev-parse", "--is-inside-work-tree"], in: path) == "true" else { return nil }
        // No optional locks: this runs in the background while Claude may be committing (index.lock).
        let status = GitPanel.parseStatus(GitService.output(["--no-optional-locks", "status", "--porcelain=v1", "-b", "-uall"], in: path) ?? "")
        var repo = Repo(name: name, path: path, branch: status.branch, head: GitService.headCommit(in: path))
        repo.uncommitted = status.changes.map(\.path)
        // Where pushes go: @{push} (a fork pulls from upstream and pushes to its own remote), else @{u}. Nil when
        // neither resolves — an upstream shown as [gone] (deleted after a merge), or a detached HEAD (a rebase too).
        let isBranch = status.branch != "HEAD"
        let ref = status.upstream == nil || !isBranch ? nil
            : GitService.output(["rev-parse", "--symbolic-full-name", "@{push}"], in: path)
                ?? GitService.output(["rev-parse", "--symbolic-full-name", "@{u}"], in: path)
        repo.upstream = ref.map { $0.replacingOccurrences(of: #"^refs/(remotes|heads)/"#, with: "", options: .regularExpression) }
        let names = isBranch ? GitService.output(["for-each-ref", "--format=%(push:remotename)%0a%(upstream:remotename)",
                                                  "refs/heads/" + status.branch], in: path) : nil
        let remote = names?.split(separator: "\n").first.map(String.init) ?? "origin"
        let url = GitService.output(["remote", "get-url", remote], in: path)
        repo.hasRemote = url != nil
        repo.host = host(of: url) ?? remote
        if let ref {
            repo.unsent = commits([ref + "..HEAD"], in: path)
            repo.sends = sends(of: ref, since: since, in: path)
        } else if repo.head != nil {
            // Not what a remote already has: a worktree branch starts from origin/main with no upstream.
            repo.commits = commits(["--since=\(ISO8601DateFormatter().string(from: since))", "HEAD", "--not", "--remotes"],
                                   in: path).reversed()
        }
        return repo
    }

    /// "git@github.com:acme/app.git" → "GitHub".
    static func host(of remote: String?) -> String? {
        guard let remote = remote?.lowercased() else { return nil }
        return [("github", "GitHub"), ("gitlab", "GitLab"), ("bitbucket", "Bitbucket")].first { remote.contains($0.0) }?.1
    }

    /// One reflog record: the ref's value before and after the update, when, and why ("update by push",
    /// "fetch: fast-forward").
    struct ReflogEntry: Equatable {
        let old: String
        let new: String
        let date: Date
        let subject: String
    }

    /// The reflog file as git writes it, oldest first: "<old> <new> Name <email> 1790502357 +0500<TAB>update by push".
    /// Read raw because `git reflog` doesn't show the old value — and after a clone the first record is a push
    /// whose old value is the only trace of where the branch was.
    static func parseReflog(_ text: String) -> [ReflogEntry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let fields = parts[0].split(separator: " ")
            guard fields.count >= 4, let seconds = TimeInterval(fields[fields.count - 2]) else { return nil }
            return ReflogEntry(old: String(fields[0]), new: String(fields[1]), date: Date(timeIntervalSince1970: seconds),
                               subject: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// Pushes to `ref` since `since`, oldest first. A push's commits start where the ref was just before it —
    /// whatever moved it there — so a teammate's commits a fetch brought in stay out; after a force push, at the
    /// common ancestor.
    static func sends(of ref: String, since: Date, in path: String) -> [Send] {
        guard let log = GitService.output(["rev-parse", "--git-path", "logs/" + ref], in: path) else { return [] }
        let file = log.hasPrefix("/") ? URL(filePath: log) : URL(filePath: path).appending(path: log)
        let entries = parseReflog((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        var sends: [Send] = []
        for (index, entry) in entries.enumerated() where entry.subject == "update by push" && entry.date >= since {
            let from: String
            if entry.old.contains(where: { $0 != "0" }) {
                from = GitService.output(["merge-base", entry.old, entry.new], in: path) ?? entry.old
            } else {
                // The branch's first push: what no other remote branch had then. As they are now, a branch merged
                // since (or one a teammate started from it) would hold these commits and the push would vanish.
                let own = GitService.output(["rev-list", "--reverse", "-n", "50", entry.new, "--not"]
                                            + otherRemoteTips(at: entry.date, except: ref, in: path), in: path)
                guard let oldest = own?.split(separator: "\n").first.map(String.init) else { continue }
                from = GitService.output(["rev-parse", "--verify", "-q", oldest + "^"], in: path) ?? GitPanel.emptyTree
            }
            let commits = commits(["\(from)..\(entry.new)"], in: path)
            guard !commits.isEmpty else { continue }
            let files = GitService.output(["diff", "--name-only", from, entry.new], in: path)?.split(separator: "\n").count ?? 0
            sends.append(Send(at: entry.date, from: from, to: entry.new,
                              after: entries[..<index].last { $0.subject == "update by push" }?.date, commits: commits, files: files))
        }
        return sends
    }

    /// Every other remote branch as it was at `date`, by its reflog: the value it had then, the value its first
    /// later update started from, or — never updated since the clone (no reflog) — the value it has now.
    static func otherRemoteTips(at date: Date, except ref: String, in path: String) -> [String] {
        let refs = (GitService.output(["for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"], in: path) ?? "")
            .split(separator: "\n").compactMap { line -> (name: String, sha: String)? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                return parts.count == 2 && parts[0] != ref && !parts[0].hasSuffix("/HEAD") ? (parts[0], parts[1]) : nil
            }
        guard !refs.isEmpty,
              let logs = GitService.output(["rev-parse"] + refs.flatMap { ["--git-path", "logs/" + $0.name] }, in: path)?
                .split(separator: "\n").map(String.init), logs.count == refs.count else { return [] }
        return zip(refs, logs).compactMap { ref, log in
            let file = log.hasPrefix("/") ? URL(filePath: log) : URL(filePath: path).appending(path: log)
            let entries = parseReflog((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            let then = entries.last { $0.date <= date }?.new ?? entries.first?.old ?? ref.sha
            return then.contains { $0 != "0" } ? then : nil // all zeros: the branch didn't exist then
        }
    }

    /// Newest first.
    static func commits(_ range: [String], in path: String) -> [Commit] {
        let log = GitService.output(["log", "--format=%H%x1f%s%x1f%ct", "-n", "50"] + range, in: path) ?? ""
        return log.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let seconds = TimeInterval(f[2]) else { return nil }
            return Commit(sha: f[0], subject: f[1], date: Date(timeIntervalSince1970: seconds))
        }
    }

    /// For Explain: the unit's commits with their whole messages, and for NOW what isn't sent as a diff.
    static func material(of unit: Unit, in repo: Repo?) -> (commits: String, diff: String?) {
        guard let repo else { return ("", nil) }
        let range: [String]
        switch unit.kind {
        case .sent(let send): range = ["\(send.from)..\(send.to)"]
        case .committed(let commit): range = ["-1", commit.sha]
        case .now: range = repo.upstream.map { repo.unsent.isEmpty ? [] : [$0 + "..HEAD"] } ?? []
        case .requests: range = []
        }
        let commits = range.isEmpty ? "" : GitService.output(["log", "--no-merges", "--format=- %s%n%b"] + range, in: repo.path) ?? ""
        guard unit.kind == .now else { return (commits, nil) }
        var diff = GitService.output(["diff", repo.unsent.isEmpty ? "HEAD" : repo.upstream ?? "HEAD"], in: repo.path) ?? ""
        let untracked = GitService.output(["ls-files", "--others", "--exclude-standard"], in: repo.path) ?? ""
        if !untracked.isEmpty { diff += "\nNew files not in git yet:\n" + untracked }
        return (commits, diff)
    }
}

/// What a unit of work changed, in the product's terms — written on the user's click by `claude -p`.
struct ProductSummary: Codable, Equatable {
    struct Change: Codable, Equatable {
        /// "new", "changed", "fixed" or "removed".
        var kind: String
        /// What a user of the product can now do or will notice.
        var what: String
        /// Where in the product, section first: "Leasing → Loan card"; empty when users don't see it.
        var where_: String

        enum CodingKeys: String, CodingKey { case kind, what, where_ = "where" }

        /// "Leasing → Loan card" → "Leasing".
        var section: String { where_.components(separatedBy: "→").first?.trimmingCharacters(in: .whitespaces) ?? "" }
    }

    var headline: String
    var changes: [Change]
    /// Open questions and risky spots to confirm before shipping.
    var check: [String]
    /// How to see it for yourself; empty when there's nothing to try.
    var howToTry: String

    enum CodingKeys: String, CodingKey { case headline, changes, check, howToTry = "how_to_try" }
}

private extension String {
    /// A hash that stays the same across launches (Swift's `hashValue` is seeded per process).
    var hashValueStable: UInt64 {
        utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
