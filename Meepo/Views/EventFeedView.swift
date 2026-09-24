import SwiftUI

/// One hook event: what happened, when, and its text.
struct EventRow: View {
    let event: HookEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Self.title(for: event.name))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(event.isFailure ? Tokens.danger : Tokens.text)
                Spacer()
                Text(event.createdAt, format: .dateTime.hour().minute().second())
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.textDim)
            }
            if let summary = event.summary, !summary.isEmpty {
                Text(Notifier.plainText(summary, limit: 300))
                    .font(.caption)
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private static func title(for name: String) -> String {
        switch name {
        case "SessionStart": "Session started"
        case "SessionEnd": "Session ended"
        case "UserPromptSubmit": "Prompt"
        case "PreToolUse": "Tool"
        case "PostToolUse": "Tool done"
        case "PostToolUseFailure": "Tool failed"
        case "PermissionRequest": "Permission request"
        case "PermissionDenied": "Denied"
        case "Notification": "Notification"
        case "Stop": "Reply ready"
        case "StopFailure": "Reply failed"
        case "PreCompact": "Compacting context"
        case "UserPromptExpansion": "Command"
        case "HookBlocked": "Blocked by your hook"
        default: name
        }
    }
}

/// Who listens on which port (SPEC module 5), with the Meepo session or project it belongs to.
struct PortsView: View {
    @Environment(AppStore.self) private var store
    @State private var ports: [ListeningPort] = []

    var body: some View {
        List(ports) { port in
            HStack(alignment: .firstTextBaseline) {
                Text(String(port.port)).font(Fonts.mono(13)).foregroundStyle(owner(of: port) == nil ? Tokens.textDim : Tokens.screen)
                    .frame(width: 54, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(port.process).foregroundStyle(Tokens.text).lineLimit(1)
                    Text(owner(of: port) ?? port.cwd ?? "pid \(port.pid)")
                        .font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.head)
                }
            }
            .listRowBackground(Tokens.dirt)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task {
            while !Task.isCancelled {
                ports = await Task.detached { Ports.listening() }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Deepest matching folder wins, so a worktree beats its main checkout.
    private func owner(of port: ListeningPort) -> String? {
        guard let cwd = port.cwd else { return nil }
        let candidates = store.sessions.compactMap { session -> (String, String)? in
            guard let dir = store.workdir(of: session), let project = store.project(for: session) else { return nil }
            return (dir, "\(project.name) · \(session.branch ?? "")")
        }
        return candidates.filter { cwd == $0.0 || cwd.hasPrefix($0.0 + "/") }.max { $0.0.count < $1.0.count }?.1
    }
}

/// CI (SPEC module 9): THIS follows the selected session's project — its default-branch pipeline, the session's
/// branch, other branches folded; ALL is one line per project, a click unfolds it.
struct CIView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmation: PixelConfirmation?
    @State var showAll = false
    @State private var unfolded: Int64?

    var body: some View {
        let current = store.selectedSession.flatMap { store.project(for: $0) }
        let projects = store.projects.filter { store.ciRuns[$0.id!] != nil }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button("THIS") { showAll = false }.overlay { if !showAll { Bevel(raised: false) } }
                    .disabled(current == nil)
                Button("ALL") { showAll = true }.overlay { if showAll { Bevel(raised: false) } }
            }
            .buttonStyle(PixelButtonStyle())
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if projects.isEmpty {
                        Text("No CI yet. GitHub (gh) and GitLab (glab) projects are checked once a minute.")
                            .font(.caption).foregroundStyle(Tokens.textDim)
                    } else if showAll || current == nil {
                        ForEach(projects) { project in
                            ProjectCISummary(project: project, isUnfolded: unfolded == project.id) {
                                unfolded = unfolded == project.id ? nil : project.id
                            }
                            if unfolded == project.id {
                                ProjectCI(project: project, branch: nil, confirmation: $confirmation).padding(.leading, 8)
                            }
                        }
                    } else if let current {
                        if store.ciRuns[current.id!] == nil {
                            Text("\(current.name): no CI runs found.").font(.caption).foregroundStyle(Tokens.textDim)
                        } else {
                            ProjectCI(project: current, branch: store.selectedSession?.branch, confirmation: $confirmation)
                        }
                    }
                }
                .padding(8)
            }
        }
        .pixelConfirm($confirmation)
    }
}

/// ALL: name, one dot per pipeline step, RUN when a deploy can start.
private struct ProjectCISummary: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let isUnfolded: Bool
    let onTap: () -> Void

    var body: some View {
        let pipeline = store.pipelines[project.id!]
        let head = store.ciRuns[project.id!]?.first { $0.headBranch == pipeline?.branch }
        HStack(spacing: 6) {
            Text(isUnfolded ? "▾" : "▸").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
            Text(project.name).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer()
            if let head, head.isInfraFailure {
                Text(head.failureReason ?? "").font(.caption2).foregroundStyle(Tokens.warn).lineLimit(1)
            }
            ForEach(pipeline?.steps ?? []) { step in
                Text(StepLook.symbol(step.state)).font(Fonts.mono(12)).foregroundStyle(StepLook.color(step.state))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// One project's CI: pipeline, the session's branch, other branches folded, the autofix switch.
private struct ProjectCI: View {
    @Environment(AppStore.self) private var store
    let project: Project
    /// The selected session's branch; nil in ALL.
    let branch: String?
    @Binding var confirmation: PixelConfirmation?
    @State private var showOthers = false

    var body: some View {
        let runs = store.ciRuns[project.id!] ?? []
        let pipeline = store.pipelines[project.id!]
        let mine = runs.filter { $0.headBranch == (branch ?? pipeline?.branch) }
        let others = runs.filter { !mine.contains($0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name.uppercased()).font(Fonts.title(16)).foregroundStyle(Tokens.text).lineLimit(1)
                Spacer()
                let on = store.autofixProjectIds.contains(project.id!)
                Button(on ? "AUTOFIX ✓" : "AUTOFIX") {
                    if on { store.autofixProjectIds.remove(project.id!) } else { store.autofixProjectIds.insert(project.id!) }
                }
                .buttonStyle(PixelButtonStyle())
                .foregroundStyle(on ? Tokens.selection : Tokens.textDim)
                .help("On: rerun a failure once, then fix it in a new session with a PR/MR (max 3). Deploys only notify.")
            }
            if let pipeline {
                PipelineView(pipeline: pipeline, project: project, confirmation: $confirmation)
                if let head = runs.first(where: { $0.headBranch == pipeline.branch }), head.isInfraFailure {
                    Text("\(head.failureReason ?? "") — CI didn't run the code, not a code failure")
                        .font(.caption).foregroundStyle(Tokens.warn)
                }
            }
            if !mine.isEmpty && (branch != nil && branch != pipeline?.branch || pipeline == nil) {
                Text("BRANCH \(branch ?? "")").font(.caption).foregroundStyle(Tokens.textDim)
                ForEach(mine.prefix(5)) { run in CIRunRow(run: run, project: project) }
            } else {
                ForEach(mine.filter(\.failed).prefix(3)) { run in CIRunRow(run: run, project: project) }
            }
            if !others.isEmpty {
                Button {
                    showOthers.toggle()
                } label: {
                    Text("\(showOthers ? "▾" : "▸") Other branches (\(others.count))\(others.contains(where: \.failed) ? " · \(others.filter(\.failed).count) ✗" : "")")
                        .font(.caption).foregroundStyle(others.contains(where: \.failed) ? Tokens.danger : Tokens.textDim)
                }
                .buttonStyle(.plain)
                if showOthers {
                    ForEach(others.prefix(10)) { run in CIRunRow(run: run, project: project) }
                }
            }
        }
        .padding(6)
        .background(Tokens.dirt)
    }
}

/// Step symbols and colors shared by the pipeline and the ALL summary.
enum StepLook {
    static func symbol(_ state: Pipeline.Step.State) -> String {
        switch state {
        case .passed: "✓"
        case .failed: "✗"
        case .running: "…"
        case .pending: "·"
        case .skipped: "–"
        case .manual: "○"
        }
    }

    static func color(_ state: Pipeline.Step.State) -> Color {
        switch state {
        case .passed: Tokens.selectionSoft
        case .failed: Tokens.danger
        case .running: Tokens.warn
        case .pending, .skipped: Tokens.textDim
        case .manual: Tokens.alert
        }
    }
}

/// The default branch's latest commit step by step: CI → build → deploy. Manual steps start on RUN, after a confirmation.
struct PipelineView: View {
    @Environment(AppStore.self) private var store
    let pipeline: Pipeline
    let project: Project
    @Binding var confirmation: PixelConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(pipeline.branch) @ \(pipeline.sha.prefix(7))").font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
            ForEach(pipeline.steps) { step in
                HStack {
                    Text(StepLook.symbol(step.state)).font(Fonts.mono(13)).foregroundStyle(StepLook.color(step.state))
                    Text(step.name).foregroundStyle(Tokens.text).lineLimit(1)
                    Spacer()
                    if step.trigger != nil {
                        Button("RUN") {
                            confirmation = PixelConfirmation(
                                title: "RUN \(step.name.uppercased())?",
                                message: "\(project.name) · \(pipeline.branch) @ \(pipeline.sha.prefix(7))",
                                action: "RUN"
                            ) { Task { await store.startPipelineStep(step, in: project) } }
                        }
                        .buttonStyle(PixelButtonStyle())
                        .disabled(!pipeline.canStart(step))
                        .help(pipeline.canStart(step) ? "Start \(step.name) on this commit" : "Waits for the steps above to pass")
                    }
                    if let url = step.url.flatMap(URL.init(string:)) { Link("↗", destination: url).foregroundStyle(Tokens.screen) }
                }
            }
        }
        .padding(.vertical, 4)
    }

}

struct CIRunRow: View {
    @Environment(AppStore.self) private var store
    let run: CIRun
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(run.failed ? "✗" : run.isRunning ? "…" : run.succeeded ? "✓" : "–")
                    .font(Fonts.mono(13))
                    .foregroundStyle(run.failed ? Tokens.danger : run.isRunning ? Tokens.warn : Tokens.selectionSoft)
                Text(run.workflowName).foregroundStyle(Tokens.text).lineLimit(1)
                if run.isDeploy { Text("DEPLOY").font(.caption2).foregroundStyle(Tokens.warn) }
                Spacer()
                Link("↗", destination: URL(string: run.url)!).foregroundStyle(Tokens.screen)
            }
            Text(run.headBranch).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(1)
            if run.failed && !run.isDeploy {
                HStack {
                    Button("RERUN") { Task { _ = await store.ciProvider(for: project)?.rerunFailed(run, in: project.path) } }
                    Button("FIX") { Task { await store.startCIFix(run, in: project) } }
                        .help("New session in a worktree with the failed step's log; it opens a PR, never pushes to main")
                }
                .buttonStyle(PixelButtonStyle())
            }
        }
    }
}
