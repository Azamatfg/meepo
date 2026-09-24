import SwiftUI

/// Right panel: hook events of the selected session, newest first; refusals and failures highlighted.
struct EventFeedView: View {
    @Environment(AppStore.self) private var store

    enum Tab: String, CaseIterable { case events = "EVENTS", tasks = "TASKS", ci = "CI", ports = "PORTS" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(item.rawValue) { store.feedTab = item }
                        .buttonStyle(PixelButtonStyle())
                        .overlay { if store.feedTab == item { Bevel(raised: false) } }
                }
            }
            .padding(8)
            Rectangle().fill(Tokens.grassDeep).frame(height: 2)
            switch store.feedTab {
            case .events: feed
            case .tasks: TasksView()
            case .ci: CIView()
            case .ports: PortsView()
            }
        }
        .background(Tokens.dirt)
    }

    @ViewBuilder
    private var feed: some View {
        Group {
            if store.selectedEvents.isEmpty {
                Text(store.isBridgeInstalled ? "No events yet" : "Install the bridge to see events")
                    .foregroundStyle(Tokens.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.selectedEvents) { event in
                    EventRow(event: event)
                        .listRowBackground(Tokens.dirt)
                        .listRowSeparatorTint(Tokens.grassDeep)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Tokens.dirt)
    }
}

private struct EventRow: View {
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
        default: name
        }
    }
}

/// Who listens on which port (SPEC module 5), with the Meepo session or project it belongs to.
private struct PortsView: View {
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

/// CI per project (SPEC module 9): the default branch's pipeline with a manual deploy,
/// then the latest run per workflow and branch with rerun / fix, and the autofix switch.
private struct CIView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmation: PixelConfirmation?

    var body: some View {
        let projects = store.projects.filter { store.ciRuns[$0.id!] != nil }
        List {
            if projects.isEmpty {
                Text("No CI yet. GitHub (gh) and GitLab (glab) projects are checked once a minute.")
                    .font(.caption).foregroundStyle(Tokens.textDim).listRowBackground(Tokens.dirt)
            }
            ForEach(projects) { project in
                HStack {
                    Text(project.name.uppercased()).font(Fonts.title(16)).foregroundStyle(Tokens.text)
                    Spacer()
                    let on = store.autofixProjectIds.contains(project.id!)
                    Button(on ? "AUTOFIX ON" : "AUTOFIX OFF") {
                        if on { store.autofixProjectIds.remove(project.id!) } else { store.autofixProjectIds.insert(project.id!) }
                    }
                    .buttonStyle(PixelButtonStyle())
                    .help("On: rerun a failure once, then fix it in a new session with a PR (max 3). Deploy workflows only notify.")
                }
                .listRowBackground(Tokens.dirt)
                if let pipeline = store.pipelines[project.id!] {
                    PipelineView(pipeline: pipeline, project: project, confirmation: $confirmation).listRowBackground(Tokens.dirt)
                }
                ForEach((store.ciRuns[project.id!] ?? []).prefix(8)) { run in
                    CIRunRow(run: run, project: project).listRowBackground(Tokens.dirt)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .pixelConfirm($confirmation)
    }
}

/// The default branch's latest commit step by step: CI → build → deploy. Manual steps start on RUN, after a confirmation.
private struct PipelineView: View {
    @Environment(AppStore.self) private var store
    let pipeline: Pipeline
    let project: Project
    @Binding var confirmation: PixelConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(pipeline.branch) @ \(pipeline.sha.prefix(7))").font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
            ForEach(pipeline.steps) { step in
                HStack {
                    Text(symbol(step.state)).font(Fonts.mono(13)).foregroundStyle(color(step.state))
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

    private func symbol(_ state: Pipeline.Step.State) -> String {
        switch state {
        case .passed: "✓"
        case .failed: "✗"
        case .running: "…"
        case .pending: "·"
        case .skipped: "–"
        case .manual: "○"
        }
    }

    private func color(_ state: Pipeline.Step.State) -> Color {
        switch state {
        case .passed: Tokens.selectionSoft
        case .failed: Tokens.danger
        case .running: Tokens.warn
        case .pending, .skipped: Tokens.textDim
        case .manual: Tokens.alert
        }
    }
}

private struct CIRunRow: View {
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
