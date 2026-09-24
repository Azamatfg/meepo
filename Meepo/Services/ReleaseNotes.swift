import Foundation

/// Release note drafts (SPEC module 12): commits since the last note plus the last /ship report, in the
/// user's voice from their sample posts. Written by a headless `claude -p` outside any session; the user
/// copies the text wherever it goes, so there are no bots or tokens.
enum ReleaseNotes {
    /// The user's sample posts, one style for every project.
    static var styleURL: URL { MeepoHome.url.appending(path: "release-style.md") }

    /// Subjects and bodies after the last note's sha; nil when there is nothing new.
    /// A first note, or a sha lost to a rewritten history, takes the last 20 commits.
    static func commits(after sha: String?, in path: String) -> String? {
        let format = ["log", "--no-merges", "--format=- %h %s%n%b"]
        let log: String?
        if let sha, let count = GitService.output(["rev-list", "--count", "\(sha)..HEAD"], in: path) {
            log = count == "0" ? nil : GitService.output(format + ["\(sha)..HEAD"], in: path)
        } else {
            log = GitService.output(format + ["-n", "20"], in: path)
        }
        return log.map { String($0.replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression).prefix(12_000)) }
    }

    static func prompt(project: String, commits: String, shipReport: String?, style: String) -> String {
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = ["""
            Write a release note for "\(project)" from the changes below, in the voice of the samples: \
            same language, length, tone, formatting and emoji habits. Write for users, not developers: what they \
            can do now or what got better; leave out refactors, tests, CI and chores unless that is all there is. \
            Output only the note, no preface.
            """]
        parts.append(style.isEmpty
            ? "No samples yet: write a short, plain post in the language of the commit messages."
            : "<samples>\n\(style)\n</samples>")
        parts.append("<commits>\n\(commits)\n</commits>")
        if let shipReport, !shipReport.isEmpty { parts.append("<ship_report>\n\(shipReport.prefix(4_000))\n</ship_report>") }
        return parts.joined(separator: "\n\n")
    }
}
