import SwiftUI

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
                PipelineView(pipeline: pipeline, runs: runs, project: project, name: project.name,
                             confirm: { confirmation = $0 }) { await store.startPipelineStep($0, in: project) }
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
            if run.failed && run.isDeploy && store.servers(of: project.id).contains(where: { !$0.sources.isEmpty }) {
                Button("GET SERVER LOGS") { Task { await store.investigateDeploy(run, in: project) } }
                    .buttonStyle(PixelButtonStyle())
                    .help("Reads the logs of this project's servers (only the log sources set in Tools → SERVERS) and opens a new session that looks into why the deploy failed")
            }
        }
    }
}
