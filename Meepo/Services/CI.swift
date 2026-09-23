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
    var id: Int64 { databaseId }

    var isRunning: Bool { status != "completed" }
    var failed: Bool { status == "completed" && (conclusion == "failure" || conclusion == "timed_out") }
    var succeeded: Bool { status == "completed" && conclusion == "success" }
    /// Deploy-like workflows are never fixed automatically (SPEC module 9), only reported.
    var isDeploy: Bool {
        workflowName.range(of: #"(?i)deploy|release|publish|push|\bcd\b"#, options: .regularExpression) != nil
    }
    var key: String { "\(workflowName)|\(headBranch)" }
}

/// CI behind an interface: GitHub Actions via `gh` first; GitLab CI etc. can implement the same (SPEC module 9).
protocol CIProvider: Sendable {
    func handles(_ project: Project) -> Bool
    func runs(in path: String) async -> [CIRun]
    func failedLog(_ run: CIRun, in path: String) async -> String
    func rerunFailed(_ run: CIRun, in path: String) async -> Bool
}

struct GitHubActions: CIProvider {
    /// `gh` from the user's login shell PATH (GUI apps don't see Homebrew's bin).
    let gh: String

    func handles(_ project: Project) -> Bool { project.remote?.contains("github.com") == true }

    func runs(in path: String) async -> [CIRun] {
        let fields = "databaseId,workflowName,headBranch,headSha,status,conclusion,createdAt,attempt,url"
        guard let data = await Self.run(gh, ["run", "list", "-L", "30", "--json", fields], in: path) else { return [] }
        return (try? Self.decoder.decode([CIRun].self, from: data)) ?? []
    }

    func failedLog(_ run: CIRun, in path: String) async -> String {
        guard let data = await Self.run(gh, ["run", "view", String(run.databaseId), "--log-failed"], in: path) else { return "" }
        return CILog.trim(String(decoding: data, as: UTF8.self))
    }

    func rerunFailed(_ run: CIRun, in path: String) async -> Bool {
        await Self.run(gh, ["run", "rerun", String(run.databaseId), "--failed"], in: path) != nil
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func run(_ executable: String, _ args: [String], in path: String) async -> Data? {
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
    case none, rerun, fix, giveUp, reportDeploy
}

enum CIGuard {
    static let maxFixAttempts = 3

    static func action(for run: CIRun, fixAttempts: Int, autofix: Bool) -> CIAction {
        guard run.failed else { return .none }
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
