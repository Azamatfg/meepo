import Foundation
import GRDB

enum SessionStatus: String, Codable, DatabaseValueConvertible {
    case thinking
    case waitingInput = "waiting_input"
    case waitingPermission = "waiting_permission"
    case idle
    case needsSync = "needs_sync"
    case error
}

struct Session: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: Int64
    /// UUID passed to `claude --session-id`; used for `claude --resume` after restart.
    var claudeSessionId: String
    var model: String?
    /// `claude --effort` level; nil = Claude Code's default.
    var effort: String?
    var branch: String?
    /// Workflow stage (a stage name from Settings), from the last slash command run in the session.
    var stage: String?
    /// Set for a parallel feature: `claude -w <name>` works in `<repo>/.claude/worktrees/<name>`.
    var worktreeName: String?
    /// Commit the worktree branched from; "merged" only counts once the branch moved past it.
    var worktreeBase: String?
    /// First of the session's 10 ports (PORT, MEEPO_PORT_BASE).
    var portBase: Int?
    var status: SessionStatus
    var createdAt: Date
    var lastActiveAt: Date
    /// The user's name for it (`claude --name`), so two sessions of one project can be told apart.
    var name: String? = nil
    /// Other folders this session also works in ("Also work in": `claude --add-dir`), e.g. a sibling project.
    var extraDirs: [String]? = nil
    /// A background agent opened here ("Open here"): its short id; meepo attaches to it (`claude attach`) while it runs.
    var agentId: String? = nil
    /// Where claude runs when that isn't the project folder: a session from outside meepo started in a subfolder.
    var folder: String? = nil
    /// A shell, not claude: an ssh alias or user@host, opened as `ssh <host>` (Servers → Open shell) — or
    /// `Session.localTerminal` (""), the user's own shell in the project folder (+ → Terminal).
    var sshHost: String? = nil

    static let localTerminal = ""
    var isLocalTerminal: Bool { sshHost == Self.localTerminal }
    /// `ssh <host>` to a project's server (not a local terminal, not claude).
    var isServerShell: Bool { sshHost.map { !$0.isEmpty } ?? false }
    /// What a shell's tab, header and menu bar call it; nil for claude.
    var shellCaption: String? { sshHost.map { $0.isEmpty ? "terminal" : "ssh \($0)" } }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
