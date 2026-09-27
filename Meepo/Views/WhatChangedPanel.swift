import AppKit
import SwiftUI

/// What changed — in the product, not the code: the selected session's runs, and for a run, what it means for
/// the product's users, what to check before shipping and how to try it. Written on click by a fork of the
/// session's own conversation, then kept.
struct WhatChangedPanel: View {
    @Environment(AppStore.self) private var store
    @State private var selectedRun: String?
    @State private var error: String?
    @State private var preview: URL?
    @State private var openFile: String?

    var body: some View {
        if let session = store.selectedSession, let sessionId = session.id {
            let runs = store.runs(of: sessionId)
            // By default the latest finished run: that's the one with something to explain.
            if let run = runs.first(where: { $0.id == selectedRun }) ?? runs.first(where: \.isDone) ?? runs.first {
                VStack(alignment: .leading, spacing: 12) {
                    if let current = runs.first, !current.isDone, current.id != run.id {
                        Button { selectedRun = current.id } label: {
                            Text("Working now: “\(Notifier.plainText(current.request, limit: 60))”")
                                .font(.caption).foregroundStyle(Tokens.work).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    if run.id != (runs.first(where: \.isDone) ?? runs.first)?.id, selectedRun != nil {
                        Button("← Back to the latest") { selectedRun = nil }.buttonStyle(.plain).font(.caption).foregroundStyle(Tokens.work)
                    }
                    runHeader(run)
                    files(run)
                    if let summary = store.summary(of: run) {
                        SummaryView(summary: summary, preview: preview)
                    } else {
                        explainButton(run)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
                    footer(run, session: session)
                    if runs.count > 1 { earlier(runs.filter { $0.id != run.id }) }
                }
                .task(id: sessionId) { preview = await store.previewURL(of: session) }
                .sheet(isPresented: Binding(get: { openFile != nil }, set: { if !$0 { openFile = nil } })) {
                    if let openFile { FileViewer(root: "", path: openFile) }
                }
            } else {
                Text("Nothing yet. Ask Claude for something — each request becomes a run here.")
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
        } else {
            Text("Select a session to see what it changed.").font(.caption).foregroundStyle(Tokens.textDim)
        }
    }

    private func runHeader(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("“\(Notifier.plainText(run.request, limit: 160))”").font(Fonts.ui(14, weight: .semibold))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text([run.startedAt.formatted(date: .omitted, time: .shortened),
                  run.isDone ? nil : "working…",
                  run.files.isEmpty ? "no files edited" : "\(run.files.count) file\(run.files.count == 1 ? "" : "s") edited"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(run.isDone ? Tokens.textDim : Tokens.work)
        }
    }

    /// The files the run edited; a click opens one.
    @ViewBuilder
    private func files(_ run: Run) -> some View {
        if !run.files.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(run.files.prefix(8), id: \.self) { file in
                    Button { openFile = file } label: {
                        HStack(spacing: 6) {
                            Image(systemName: FileIcon.symbol(for: file)).font(.system(size: 11)).foregroundStyle(FileIcon.color(for: file))
                            Text(URL(filePath: file).lastPathComponent).font(.caption).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file)
                }
                if run.files.count > 8 { Text("and \(run.files.count - 8) more").font(.caption).foregroundStyle(Tokens.textDim) }
            }
        }
    }

    @ViewBuilder
    private func explainButton(_ run: Run) -> some View {
        let isWorking = store.explainingRuns.contains(run.id)
        VStack(alignment: .leading, spacing: 6) {
            Button(isWorking ? "Writing…" : "Explain for users") {
                Task {
                    do { _ = try await store.explain(run); error = nil } catch { self.error = error.localizedDescription }
                }
            }
            .buttonStyle(PixelButtonStyle(isPrimary: true))
            .disabled(isWorking || !run.isDone)
            Text(run.isDone
                 ? "Claude writes it from this session's own conversation — what users will notice, what to check before shipping. Uses a little of your limit, once."
                 : "Available when this run ends.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ run: Run, session: Session) -> some View {
        HStack(spacing: 8) {
            Button("Undo this run…") {
                store.confirmation = PixelConfirmation(
                    title: "Undo with Claude Code's rewind?",
                    message: "Opens /rewind in the terminal: pick the point before “\(Notifier.plainText(run.request, limit: 60))”. It puts back what Claude edited. What shell commands did — installs, migrations, git — stays as it is.",
                    action: "Open rewind",
                    isDestructive: false
                ) { store.rewind(session.id!) }
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .disabled(!run.isDone || run.files.isEmpty)
            Spacer()
        }
    }

    private func earlier(_ runs: [Run]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("EARLIER REQUESTS — CLICK ONE TO SEE WHAT IT CHANGED").font(Fonts.ui(11, weight: .bold)).tracking(1.2)
                .foregroundStyle(Tokens.textDim).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            ForEach(runs.prefix(8)) { run in
                Button { selectedRun = run.id } label: {
                    HStack(spacing: 6) {
                        Text(run.startedAt.formatted(date: .omitted, time: .shortened)).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
                        Text(Notifier.plainText(run.request, limit: 80)).lineLimit(1)
                        Spacer(minLength: 0)
                        if !run.files.isEmpty { Text("\(run.files.count)").font(Fonts.mono(10)).foregroundStyle(Tokens.textDim).help("files changed") }
                        if store.summary(of: run) != nil { Image(systemName: "text.bubble").font(.caption).foregroundStyle(Tokens.work) }
                    }
                    .font(.caption)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(run.id == selectedRun ? Tokens.work : Tokens.text)
            }
        }
    }
}

/// The summary itself: headline, changes with where they are, what to check, how to try.
private struct SummaryView: View {
    let summary: ProductSummary
    let preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.headline).font(Fonts.ui(18, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(summary.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(change.kind.uppercased()).font(Fonts.ui(10, weight: .bold)).tracking(0.8)
                            .foregroundStyle(change.kind == "removed" ? Tokens.need : Tokens.work)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Tokens.workTint, in: Capsule())
                        Text(change.what).fixedSize(horizontal: false, vertical: true)
                    }
                    if !change.where_.isEmpty {
                        Text(change.where_).font(.caption).foregroundStyle(Tokens.textDim).padding(.leading, 2)
                    }
                }
            }
            if !summary.check.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CHECK BEFORE YOU SHIP").font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.need)
                    ForEach(Array(summary.check.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            SelectionRing(kind: .waiting, size: 6)
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.needTint, in: RoundedRectangle(cornerRadius: 10))
            }
            if !summary.howToTry.isEmpty || preview != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HOW TO TRY").font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim)
                    if !summary.howToTry.isEmpty { Text(summary.howToTry).fixedSize(horizontal: false, vertical: true) }
                    if let preview {
                        Button("Open preview · \(preview.port.map(String.init) ?? "")") { NSWorkspace.shared.open(preview) }
                            .buttonStyle(PixelButtonStyle(compact: true))
                            .help("Something is listening in this session's own ports")
                    }
                }
            }
        }
    }
}
