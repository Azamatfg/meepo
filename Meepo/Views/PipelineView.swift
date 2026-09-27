import SwiftUI

/// One commit going through CI, top to bottom: what each step does, how long it took or has been running,
/// and the one thing to do now — Run a deploy, see why a step failed, let Claude fix it, rerun it.
struct PipelineView: View {
    @Environment(AppStore.self) private var store
    let pipeline: Pipeline
    let runs: [CIRun]
    /// The meepo project a failure can be fixed in; nil for a repo that is only shown.
    let project: Project?
    /// For the Run confirmation: the project's or repo's name.
    let name: String
    /// Shows the Run confirmation — in the window, or inside a sheet that has its own.
    let confirm: (PixelConfirmation) -> Void
    let start: (Pipeline.Step) async -> Void

    var body: some View {
        let summary = pipeline.summary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.textDim)
                Text(pipeline.branch).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
                Text(pipeline.title ?? String(pipeline.sha.prefix(7))).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            .help(pipeline.commitHelp)
            Text(summary.text).font(Fonts.ui(13, weight: .semibold))
                .foregroundStyle(summary.needsYou ? Tokens.need : Tokens.text)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
                    row(step, isLast: index == pipeline.steps.count - 1)
                }
            }
        }
    }

    private func row(_ step: Pipeline.Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                icon(step).frame(width: 16, height: 16)
                if !isLast {
                    Rectangle().fill(step.state == .passed ? StepLook.color(.passed) : Tokens.line).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(step.name).font(Fonts.ui(13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    time(step)
                }
                if let purpose = Pipeline.Step.purpose(of: step.name) {
                    Text(purpose).font(.caption).foregroundStyle(Tokens.textDim)
                }
                actions(step)
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func icon(_ step: Pipeline.Step) -> some View {
        let state = step.state
        switch state {
        case .running: ProgressView().controlSize(.mini)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(StepLook.color(state))
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(StepLook.color(state))
        // Orange only once it's really up to you; grey while earlier steps still have to pass.
        case .manual: Image(systemName: "hand.tap.fill").foregroundStyle(pipeline.canStart(step) ? StepLook.color(state) : Tokens.textDim)
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(StepLook.color(state))
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(StepLook.color(state))
        }
    }

    /// How long it took, a live clock while it runs, or what it waits for.
    @ViewBuilder
    private func time(_ step: Pipeline.Step) -> some View {
        Group {
            switch step.state {
            case .running:
                if let started = step.started {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.duration(context.date.timeIntervalSince(started)))
                    }
                } else {
                    Text("running")
                }
            case .manual: Text(step.trigger == nil ? "waits for approval" : pipeline.canStart(step) ? "waits for you" : "after the steps above")
            case .pending: Text("queued")
            case .skipped: Text("skipped")
            case .passed, .failed:
                if let started = step.started, let finished = step.finished { Text(Self.duration(finished.timeIntervalSince(started))) }
            }
        }
        .font(Fonts.mono(11))
        .foregroundStyle(Tokens.textDim)
    }

    @ViewBuilder
    private func actions(_ step: Pipeline.Step) -> some View {
        let run = runs.first { $0.url == step.url } ?? runs.first { $0.headSha == pipeline.sha && $0.failed }
        HStack(spacing: 6) {
            if step.state == .manual, pipeline.canStart(step) {
                Button("Run") { confirm(step) }.buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
            }
            if step.state == .failed {
                if let project, let run, !run.isDeploy, !run.isInfraFailure {
                    Button("Fix with Claude") { Task { await store.startCIFix(run, in: project) } }
                        .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                        .help("A new session in a worktree with the failed step's log; it opens a PR, never pushes to main")
                }
                if let project, let run, run.isDeploy || Self.isDeploy(step),
                   store.servers(of: project.id).contains(where: { !$0.sources.isEmpty }) {
                    Button("Get server logs") { Task { await store.investigateDeploy(run, in: project) } }
                        .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                        .help("Reads the logs of this project's servers (only the log sources set in Tools → SERVERS) and opens a new session that looks into why the deploy failed")
                }
                if let project, let run, !run.isDeploy, !pipeline.steps.contains(where: { $0.state == .failed && Self.isDeploy($0) }) {
                    Button("Rerun") {
                        Task {
                            _ = await store.ciProvider(for: project)?.rerunFailed(run, in: project.path)
                            await store.refreshCI()
                        }
                    }
                    .buttonStyle(PixelButtonStyle(compact: true))
                }
            }
            if let url = step.url.flatMap(URL.init(string:)) {
                Link(step.state == .failed ? "Why? ↗" : "Log ↗", destination: url).font(.caption)
            }
        }
    }

    private func confirm(_ step: Pipeline.Step) {
        confirm(PixelConfirmation(
            title: "Run \(step.name)?",
            message: "\(name) · \(pipeline.commitDetail)" + (Pipeline.Step.purpose(of: step.name).map { " — it \($0)." } ?? ""),
            action: "Run"
        ) { Task { await start(step) } })
    }

    /// A step that puts things live is only ever started with a confirmation (Run), never by Rerun.
    static func isDeploy(_ step: Pipeline.Step) -> Bool {
        step.trigger != nil || Pipeline.Step.purpose(of: step.name) == "puts it live"
    }

    /// "45s", "2m 14s", "1h 3m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
