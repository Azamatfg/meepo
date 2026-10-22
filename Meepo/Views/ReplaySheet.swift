import SwiftUI

/// REPLAY: past commits of a project redone by Claude on other setups, graded by the tests those commits added.
/// Answers "is this model, this effort, better on my own work?" with pass rates, cost and time.
struct ReplaySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projectId: Int64?
    @State private var taskId: Int64?
    @State private var candidates: [Replay.Candidate]?
    @State private var setups = [Replay.Setup(model: "opus", effort: "xhigh"), Replay.Setup(model: "opus", effort: "medium")]
    @State private var attempts = 2
    @State private var confirmation: PixelConfirmation?

    var body: some View {
        let project = store.projects.first { $0.id == projectId } ?? store.projects.first
        let tasks = store.replayTasks.filter { $0.projectId == project?.id }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("REPLAY").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                PixelMenu(selection: project?.name ?? "No projects") {
                    ForEach(store.projects) { item in Button(item.name) { projectId = item.id; taskId = nil; candidates = nil } }
                }
                if let project {
                    Button("ADD…") { Task { candidates = await store.replayCandidates(for: project) } }
                        .help("Pick a past commit that added tests")
                }
                Spacer()
                if let activity = store.replayActivity {
                    Text(activity).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(1)
                    Button("STOP") { store.stopReplay() }.help("Stops after the run in progress")
                }
                Button("Close") { dismiss() }.keyboardShortcut(confirmation == nil ? .cancelAction : nil)
            }
            .buttonStyle(PixelButtonStyle())
            HStack(alignment: .top, spacing: 10) {
                taskList(tasks)
                if let candidates, let project {
                    CandidateList(candidates: candidates, project: project) { self.candidates = nil }
                } else if let task = tasks.first(where: { $0.id == taskId }) ?? tasks.first, let project {
                    // By id: a verdict arriving (isValid) mustn't rebuild it and wipe what's being typed.
                    TaskEditor(task: task, project: project, confirmation: $confirmation).id(task.id)
                } else {
                    Text("Replay a past commit: Claude redoes it on the code before it, and the tests that commit added say whether it worked. ADD picks one.")
                        .foregroundStyle(Tokens.textDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8).background(Tokens.dirt).sunken()
                }
            }
            RunPanel(tasks: tasks, setups: $setups, attempts: $attempts)
        }
        .padding(16)
        .frame(width: 900, height: 680)
        .background(Tokens.grass)
        .pixelFrame(6)
        .pixelConfirm($confirmation)
        .task { store.reloadReplay() }
    }

    private func taskList(_ tasks: [ReplayTask]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tasks) { task in
                    Button { taskId = task.id; candidates = nil } label: {
                        HStack {
                            Text(task.isValid == true ? "✓" : task.isValid == false ? "✗" : "·").frame(width: 14)
                            Text(task.subject).lineLimit(1)
                            Spacer()
                        }
                        .padding(4)
                        .background(task.id == (taskId ?? tasks.first?.id) ? Tokens.dirt : .clear)
                    }
                    .buttonStyle(.plain)
                    .help(task.isValid == true ? "Valid" : task.isValid == false ? "Can't grade fairly" : "Not validated yet")
                }
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(Tokens.dirt)
        .sunken()
    }
}

private struct CandidateList: View {
    @Environment(AppStore.self) private var store
    let candidates: [Replay.Candidate]
    let project: Project
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commits that changed code and tests, up to \(Replay.maxLines) lines").foregroundStyle(Tokens.textDim)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { candidate in
                        HStack {
                            Text(candidate.sha.prefix(7)).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
                            Text(candidate.subject).lineLimit(1)
                            Spacer()
                            Button("ADD") { store.addReplayTask(candidate, in: project); onDone() }
                                .disabled(store.replayActivity != nil)
                        }
                        .help(candidate.tests.joined(separator: "\n"))
                    }
                    if candidates.isEmpty { Text("None found").foregroundStyle(Tokens.textDim) }
                }
            }
            Button("Cancel", action: onDone)
        }
        .buttonStyle(PixelButtonStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The instruction is what the agent gets; read it as the agent would: does it say everything the tests expect?
private struct TaskEditor: View {
    @Environment(AppStore.self) private var store
    let task: ReplayTask
    let project: Project
    @Binding var confirmation: PixelConfirmation?
    @State private var instruction = ""
    @State private var check = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.sha.prefix(7)).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
                Text(task.subject).lineLimit(1)
                Spacer()
            }
            TextEditor(text: $instruction)
                .font(Fonts.mono(12))
                .scrollContentBackground(.hidden)
                .padding(6).background(Tokens.dirt).sunken()
            TextField("Check", text: $check).font(Fonts.mono(11)).textFieldStyle(.plain)
                .padding(6).background(Tokens.dirt).sunken()
                .help("Runs after the commit's tests are put in; exit 0 = passed")
            HStack {
                if instruction != task.instruction || check != task.checkCommand {
                    Button("SAVE") { var edited = task; edited.instruction = instruction; edited.checkCommand = check; store.updateReplayTask(edited) }
                        .disabled(store.replayActivity != nil)
                        .help(store.replayActivity != nil ? "After Replay is done: a validation or run in progress uses the task as it was" : "")
                }
                Button("VALIDATE") { store.validateReplayTask(task, in: project) }
                    .disabled(store.replayActivity != nil)
                    .help("Doing nothing must fail the check, and the commit itself must pass it")
                Text(task.isValid == true ? "Valid" : task.isValid == false ? "Can't grade fairly: doing nothing passes, or the commit fails" : "")
                    .foregroundStyle(Tokens.textDim)
                Spacer()
                Button("DELETE") {
                    confirmation = PixelConfirmation(title: "DELETE THIS TASK?", message: "Its runs go too.", action: "DELETE") {
                        store.deleteReplayTask(task.id!)
                    }
                }
                .disabled(store.replayActivity != nil)
            }
            .buttonStyle(PixelButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { instruction = task.instruction; check = task.checkCommand }
    }
}

/// Setups to compare, how many attempts each, and what came of the runs so far.
private struct RunPanel: View {
    @Environment(AppStore.self) private var store
    let tasks: [ReplayTask]
    @Binding var setups: [Replay.Setup]
    @Binding var attempts: Int
    /// ultracode is a setting, not an --effort value.
    private let efforts = ClaudeLauncher.effortLevels.filter { $0 != ClaudeLauncher.ultracode }

    var body: some View {
        let valid = tasks.filter { $0.isValid == true }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ForEach(setups.indices, id: \.self) { index in
                    PixelMenu(selection: setups[index].model.isEmpty ? "Default" : setups[index].model) {
                        ForEach(store.modelChoices(), id: \.value) { option in Button(option.title) { setups[index].model = option.value } }
                    }
                    PixelMenu(selection: setups[index].effort.isEmpty ? "Default" : setups[index].effort) {
                        ForEach(efforts, id: \.self) { level in Button(level.isEmpty ? "Default" : level) { setups[index].effort = level } }
                    }
                    if setups.count > 1 { Button("−") { setups.remove(at: index) } }
                    Text("|").foregroundStyle(Tokens.textDim)
                }
                if setups.count < 3 { Button("+") { setups.append(Replay.Setup(model: "sonnet", effort: "")) } }
                Spacer()
                PixelMenu(selection: "×\(attempts)") {
                    ForEach(1...5, id: \.self) { count in Button("×\(count)") { attempts = count } }
                }
                .help("Attempts per task and setup: one run is luck")
                Button("RUN \(valid.count * setups.count * attempts)") { store.runReplay(valid, setups: setups, attempts: attempts) }
                    .disabled(valid.isEmpty || store.replayActivity != nil)
                    .help("Every valid task on every setup, one at a time. Fable and max effort use your limit fastest")
            }
            .buttonStyle(PixelButtonStyle())
            results(of: Set(tasks.compactMap(\.id)))
        }
    }

    private func results(of taskIds: Set<Int64>) -> some View {
        let runs = store.replayRuns.filter { taskIds.contains($0.taskId) }
        let bySetup = Dictionary(grouping: runs, by: \.setup).sorted { $0.key.title < $1.key.title }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                ForEach(["SETUP", "PASSED", "COST", "TIME", "BROKE"], id: \.self) { Text($0).foregroundStyle(Tokens.textDim) }
            }
            ForEach(bySetup, id: \.key) { setup, runs in
                let graded = runs.filter { $0.passed != nil }
                let passed = graded.filter { $0.passed == true }.count
                GridRow {
                    Text(setup.title)
                    Text(graded.isEmpty ? "—" : "\(passed) of \(graded.count)")
                    Text(graded.isEmpty ? "—" : String(format: "$%.2f", graded.map(\.costUsd).reduce(0, +) / Double(graded.count)))
                        .help("Average per run")
                    Text(graded.isEmpty ? "—" : Duration.seconds(graded.map(\.seconds).reduce(0, +) / Double(graded.count))
                        .formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                        .help("Average per run")
                    Text("\(runs.count - graded.count)")
                        .help(runs.compactMap(\.error).last ?? "Runs that broke before the agent's work could be checked")
                }
            }
        }
        .font(Fonts.mono(12))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.dirt)
        .sunken()
    }
}
