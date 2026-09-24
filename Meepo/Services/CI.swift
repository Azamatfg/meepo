import Foundation

/// A workflow run as `gh run list --json` returns it.
struct CIRun: Decodable, Equatable, Identifiable {
    let databaseId: Int64
    let workflowName: String
    let headBranch: String
    let headSha: String
    let status: String
    let conclusion: String?
    let createdAt: Date
    let attempt: Int
    let url: String
    /// What started it: push, pull_request, workflow_run, workflow_dispatch, schedule.
    var event: String?
    /// GitLab's job `failure_reason` (script_failure, ci_quota_exceeded, …); GitHub doesn't give one.
    var failureReason: String?
    var id: Int64 { databaseId }

    var isRunning: Bool { status != "completed" }
    var failed: Bool { status == "completed" && (conclusion == "failure" || conclusion == "timed_out") }
    var succeeded: Bool { status == "completed" && conclusion == "success" }
    /// Deploy-like workflows are never fixed automatically (SPEC module 9), only reported.
    var isDeploy: Bool {
        workflowName.range(of: #"(?i)deploy|release|publish|push|\bcd\b"#, options: .regularExpression) != nil
    }
    var key: String { "\(workflowName)|\(headBranch)" }
    /// Failed before running the code (no CI minutes, no runner…): rerunning or fixing code won't help.
    var isInfraFailure: Bool {
        failed && ["ci_quota_exceeded", "no_matching_runner", "runner_system_failure", "runner_unsupported",
                   "stuck_or_timeout_failure", "scheduler_failure", "api_failure", "builds_disabled", "user_blocked"]
            .contains(failureReason ?? "")
    }
}

/// CI behind an interface: GitHub Actions via `gh` first; GitLab CI etc. can implement the same (SPEC module 9).
protocol CIProvider: Sendable {
    func handles(_ project: Project) -> Bool
    func runs(in path: String) async -> [CIRun]
    func failedLog(_ run: CIRun, in path: String) async -> String
    func rerunFailed(_ run: CIRun, in path: String) async -> Bool
    /// The default branch's latest commit as a chain of steps; `runs` are this poll's `runs(in:)`.
    func pipeline(runs: [CIRun], in path: String) async -> Pipeline?
    /// Starts a manual step (deploy). Returns an error message, nil on success.
    func start(_ step: Pipeline.Step, of pipeline: Pipeline, in path: String) async -> String?
}

/// One commit on the default branch going through CI → build → deploy (GitHub workflows or GitLab stages).
struct Pipeline: Equatable {
    struct Step: Equatable, Identifiable {
        enum State: Equatable { case passed, failed, running, pending, skipped, manual }
        let name: String
        let state: State
        var url: String?
        /// What `start` launches: a workflow file (GitHub) or a manual job id (GitLab); nil = can't be started.
        var trigger: String?
        var id: String { name }
    }

    let branch: String
    let sha: String
    let steps: [Step]

    /// A manual step may start once every step before it passed or was skipped.
    func canStart(_ step: Step) -> Bool {
        guard step.trigger != nil, let index = steps.firstIndex(of: step) else { return false }
        return steps[..<index].allSatisfy { $0.state == .passed || $0.state == .skipped }
    }
}

struct GitHubActions: CIProvider {
    /// `gh` from the user's login shell PATH (GUI apps don't see Homebrew's bin).
    let gh: String

    func handles(_ project: Project) -> Bool { project.remote?.contains("github.com") == true }

    func runs(in path: String) async -> [CIRun] {
        let fields = "databaseId,workflowName,headBranch,headSha,status,conclusion,createdAt,attempt,url,event"
        guard let data = await CLI.run(gh, ["run", "list", "-L", "30", "--json", fields], in: path) else { return [] }
        return (try? Self.decoder.decode([CIRun].self, from: data)) ?? []
    }

    func failedLog(_ run: CIRun, in path: String) async -> String {
        guard let data = await CLI.run(gh, ["run", "view", String(run.databaseId), "--log-failed"], in: path) else { return "" }
        return CILog.trim(String(decoding: data, as: UTF8.self))
    }

    func rerunFailed(_ run: CIRun, in path: String) async -> Bool {
        await CLI.run(gh, ["run", "rerun", String(run.databaseId), "--failed"], in: path) != nil
    }

    func pipeline(runs: [CIRun], in path: String) async -> Pipeline? {
        guard let branchData = await CLI.run(gh, ["repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"], in: path),
              let workflowData = await CLI.run(gh, ["workflow", "list", "--json", "name,path,state"], in: path) else { return nil }
        let workflows = (try? JSONDecoder().decode([Workflow].self, from: workflowData)) ?? []
        let branch = String(decoding: branchData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.pipeline(runs: runs, workflows: workflows.filter { $0.state == "active" }, branch: branch)
    }

    func start(_ step: Pipeline.Step, of pipeline: Pipeline, in path: String) async -> String? {
        guard let workflow = step.trigger else { return "Nothing to start" }
        return await CLI.run(gh, ["workflow", "run", workflow, "--ref", pipeline.branch], in: path) == nil
            ? "gh workflow run \(workflow) failed" : nil
    }

    struct Workflow: Decodable { let name, path, state: String }

    /// Workflows on the branch's latest commit in start order (CI → Build → …), then deploy workflows
    /// not yet run on it as manual steps. Pull requests and schedules aren't part of the chain.
    static func pipeline(runs: [CIRun], workflows: [Workflow], branch: String) -> Pipeline? {
        let chain = runs.filter { $0.headBranch == branch && ["push", "workflow_run", "workflow_dispatch"].contains($0.event ?? "push") }
        guard let head = (chain.filter { $0.event == "push" }.max { $0.createdAt < $1.createdAt }
                          ?? chain.max { $0.createdAt < $1.createdAt }) else { return nil }
        var latest: [String: CIRun] = [:]
        for run in chain where run.headSha == head.headSha && (latest[run.workflowName]?.createdAt ?? .distantPast) < run.createdAt {
            latest[run.workflowName] = run
        }
        let deploys = workflows.filter { $0.name.range(of: #"(?i)deploy|release|\bcd\b"#, options: .regularExpression) != nil }
        var steps = latest.values.sorted { $0.createdAt < $1.createdAt }.map { run in
            Pipeline.Step(name: run.workflowName, state: state(of: run), url: run.url,
                          trigger: deploys.first { $0.name == run.workflowName }?.path)
        }
        for deploy in deploys where latest[deploy.name] == nil {
            steps.append(Pipeline.Step(name: deploy.name, state: .manual, trigger: deploy.path))
        }
        return Pipeline(branch: branch, sha: head.headSha, steps: steps)
    }

    private static func state(of run: CIRun) -> Pipeline.Step.State {
        if run.isRunning { return .running }
        if run.succeeded { return .passed }
        if run.conclusion == "skipped" || run.conclusion == "neutral" { return .skipped }
        return .failed
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Runs a CLI (`gh`, `glab`) in the project folder; stdout on exit 0, nil otherwise.
enum CLI {
    static func run(_ executable: String, _ args: [String], in path: String) async -> Data? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = args
            process.currentDirectoryURL = URL(filePath: path)
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }
}

/// GitLab CI via the user's `glab` (`glab auth login` once); `:fullpath` is the repo of the project folder.
struct GitLabCI: CIProvider {
    let glab: String

    func handles(_ project: Project) -> Bool { project.remote?.contains("gitlab") == true }

    func runs(in path: String) async -> [CIRun] {
        guard let data = await api(["projects/:fullpath/pipelines?per_page=30"], in: path),
              let pipelines = try? Self.decoder.decode([APIPipeline].self, from: data) else { return [] }
        var runs = pipelines.map(\.run)
        // Only the newest pipeline per branch is shown and acted on; ask why those failed.
        var seen: Set<String> = []
        for index in runs.indices where seen.insert(runs[index].headBranch).inserted && runs[index].failed {
            if let jobs = await api(["projects/:fullpath/pipelines/\(runs[index].databaseId)/jobs?scope[]=failed"], in: path),
               let failed = try? Self.decoder.decode([APIJob].self, from: jobs) {
                runs[index].failureReason = failed.lazy.compactMap(\.failure_reason).first
            }
        }
        return runs
    }

    func failedLog(_ run: CIRun, in path: String) async -> String {
        guard let data = await api(["projects/:fullpath/pipelines/\(run.databaseId)/jobs?scope[]=failed"], in: path),
              let jobs = try? Self.decoder.decode([APIJob].self, from: data) else { return "" }
        var log = ""
        for job in jobs {
            // Jobs that never ran (e.g. ci_quota_exceeded) have an empty trace; the reason is all there is.
            if let reason = job.failure_reason { log += "\(job.name)\tfailure_reason: \(reason)\n" }
            if let trace = await api(["projects/:fullpath/jobs/\(job.id)/trace"], in: path) {
                log += "\(job.name)\t" + String(decoding: trace, as: UTF8.self) + "\n"
            }
        }
        return CILog.trim(log)
    }

    func rerunFailed(_ run: CIRun, in path: String) async -> Bool {
        await api(["-X", "POST", "projects/:fullpath/pipelines/\(run.databaseId)/retry"], in: path) != nil
    }

    func pipeline(runs: [CIRun], in path: String) async -> Pipeline? {
        guard let projectData = await api(["projects/:fullpath"], in: path),
              let branch = (try? JSONDecoder().decode(APIProject.self, from: projectData))?.default_branch,
              let head = runs.filter({ $0.headBranch == branch }).max(by: { $0.createdAt < $1.createdAt }),
              let data = await api(["projects/:fullpath/pipelines/\(head.databaseId)/jobs?per_page=100"], in: path),
              let jobs = try? Self.decoder.decode([APIJob].self, from: data) else { return nil }
        return Pipeline(branch: branch, sha: head.headSha, steps: Self.steps(jobs, url: head.url))
    }

    func start(_ step: Pipeline.Step, of pipeline: Pipeline, in path: String) async -> String? {
        guard let job = step.trigger else { return "Nothing to start" }
        return await api(["-X", "POST", "projects/:fullpath/jobs/\(job)/play"], in: path) == nil ? "glab: couldn't start job \(job)" : nil
    }

    private func api(_ args: [String], in path: String) async -> Data? { await CLI.run(glab, ["api"] + args, in: path) }

    /// One step per stage, in pipeline order (earlier stages get lower job ids).
    /// A stage is failed if a job that must pass failed, busy while any job is, manual if it waits for a click.
    static func steps(_ jobs: [APIJob], url: String) -> [Pipeline.Step] {
        let stages = Dictionary(grouping: jobs, by: \.stage).sorted { $0.value.map(\.id).min()! < $1.value.map(\.id).min()! }
        return stages.map { stage, jobs in
            let statuses = Set(jobs.filter { !($0.allow_failure ?? false) || $0.status != "failed" }.map(\.status))
            let manual = jobs.first { $0.status == "manual" }
            let state: Pipeline.Step.State =
                !statuses.isDisjoint(with: ["failed", "canceled"]) ? .failed
                : !statuses.isDisjoint(with: ["running", "pending", "preparing", "waiting_for_resource"]) ? .running
                : !statuses.isDisjoint(with: ["created", "scheduled"]) ? .pending
                : manual != nil ? .manual
                : !statuses.isEmpty && statuses.subtracting(["skipped"]).isEmpty ? .skipped
                : .passed
            return Pipeline.Step(name: stage, state: state, url: jobs.count == 1 ? jobs[0].web_url : url,
                                 trigger: manual.map { String($0.id) })
        }
    }

    struct APIProject: Decodable { let default_branch: String? }

    struct APIJob: Decodable {
        let id: Int64
        let name: String
        let stage: String
        let status: String
        let web_url: String
        let allow_failure: Bool?
        var failure_reason: String?
    }

    struct APIPipeline: Decodable {
        let id: Int64
        let sha: String
        let ref: String
        let status: String
        let source: String?
        let created_at: Date
        let web_url: String

        /// Pipeline as a CIRun, so notifications and autofix work the same as on GitHub.
        var run: CIRun {
            let done = ["success", "failed", "canceled", "skipped", "manual"].contains(status)
            let conclusion = ["success": "success", "failed": "failure", "canceled": "cancelled",
                              "skipped": "skipped", "manual": "action_required"][status]
            return CIRun(databaseId: id, workflowName: "Pipeline", headBranch: ref, headSha: sha,
                         status: done ? "completed" : status, conclusion: conclusion, createdAt: created_at,
                         attempt: 1, url: web_url, event: source)
        }
    }

    /// GitLab dates carry milliseconds ("2026-09-23T14:30:54.123Z"), which plain `.iso8601` rejects.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
        }
        return decoder
    }()
}

/// Cuts a failed job log down to what explains the failure (SPEC §3: save tokens).
/// `gh --log-failed` returns the whole job (every step labelled "UNKNOWN STEP"): a real one was 686 KB.
enum CILog {
    static func trim(_ raw: String, limit: Int = 12_000) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.split(separator: "\t", maxSplits: 2).last ?? "")
                .replacingOccurrences(of: #"^\d{4}-\d\d-\d\dT[\d:.]+Z "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\x1B\[[0-9;]*m|\[\d+(;\d+)*m"#, with: "", options: .regularExpression)
        }
        // The failed step: the last "Run …" group before the first ##[error].
        guard let error = lines.firstIndex(where: { $0.contains("##[error]") }) else { return tail(lines, limit: limit) }
        let start = lines[..<error].lastIndex { $0.hasPrefix("##[group]Run ") } ?? 0
        let step = Array(lines[start...error])

        // Test runners' own failure markers (Django, pytest, Go, Jest, panics). A plain Traceback only counts
        // when none of these exist: logged-and-caught exceptions are noise.
        let strong = #"^(FAIL|ERROR): |^FAILED |^_{3,} .* _{3,}$|^E {2,}|--- FAIL|✕|panic:|short test summary info"#
        var marks = step.indices.filter { step[$0].range(of: strong, options: .regularExpression) != nil }
        if marks.isEmpty { marks = step.indices.filter { step[$0].contains("Traceback") || step[$0].contains("Error:") } }

        var keep = Set(0..<min(2, step.count))                     // which command failed
        keep.formUnion(max(0, step.count - 15)..<step.count)       // runner summary, exit code
        var seenBlocks = Set<String>()
        for mark in marks {
            // A failure block runs until the runner's next separator, at most 40 lines. Django puts a
            // separator right under "ERROR: test_x" before the traceback, so the first two lines don't end it.
            var end = mark + 1
            while end < step.count, end - mark < 40,
                  end - mark <= 2 || step[end].range(of: #"^(=|-|_){10,}$"#, options: .regularExpression) == nil { end += 1 }
            let block = step[mark..<end].joined(separator: "\n")
            if seenBlocks.insert(block).inserted { keep.formUnion(mark..<end) }
        }

        var out: [String] = []
        var previous = -2
        for index in keep.sorted() {
            if index != previous + 1 { out.append("…") }
            out.append(String(step[index].prefix(400)))
            previous = index
        }
        let text = out.joined(separator: "\n")
        return text.count <= limit ? text : String(text.prefix(limit)) + "\n… (trimmed)"
    }

    private static func tail(_ lines: [String], limit: Int) -> String {
        String(lines.suffix(80).joined(separator: "\n").suffix(limit))
    }
}

/// What the guard does about one run (SPEC module 9: rerun once, then fix, at most N attempts, deploys only notify).
enum CIAction: Equatable {
    case none, rerun, fix, giveUp, reportDeploy, reportInfra
}

enum CIGuard {
    static let maxFixAttempts = 3

    static func action(for run: CIRun, fixAttempts: Int, autofix: Bool) -> CIAction {
        guard run.failed else { return .none }
        if run.isInfraFailure { return .reportInfra }
        if run.isDeploy { return .reportDeploy }
        guard autofix else { return .none }
        if run.attempt < 2 { return .rerun }                  // flaky? try once more first
        return fixAttempts < maxFixAttempts ? .fix : .giveUp
    }

    /// The fix session's first message: context in, guardrails on (never main/master, never force).
    static func fixPrompt(_ run: CIRun, log: String) -> String {
        let branch = "ci-fix/\(run.headBranch)-\(run.databaseId)"
        return """
            CI failed and needs a fix.
            Workflow: \(run.workflowName)
            Branch: \(run.headBranch)
            Commit: \(run.headSha)
            Run: \(run.url)

            Log of the failed step (trimmed):
            ```
            \(log)
            ```

            Fix only what makes CI fail:
            1. git fetch origin \(run.headBranch) && git checkout -B \(branch) origin/\(run.headBranch)
            2. Reproduce locally if you can, fix, run the relevant tests.
            3. Commit, push \(branch), and open a PR into \(run.headBranch) with `gh pr create`.
            Never push to main, master or \(run.headBranch) directly, never force-push. If it isn't fixable from code \
            (secrets, infrastructure, flaky service), stop and explain why.
            """
    }
}
