import SwiftUI
import UniformTypeIdentifiers

/// Per-project to-dos with notes and attachments (SPEC module 7), in the TASKS sheet.
struct TasksView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var expanded: Int64?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("New task…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(12))
                    .foregroundStyle(Tokens.text)
                    .padding(5)
                    .background(Tokens.terminalBg)
                    .sunken()
                    .onSubmit(add)
                Button("ADD", action: add).buttonStyle(PixelButtonStyle())
            }
            .padding(8)
            List {
                ForEach(groups, id: \.title) { group in
                    Text(group.title.uppercased()).font(Fonts.title(16)).foregroundStyle(Tokens.text)
                        .listRowBackground(Tokens.dirt)
                    ForEach(group.tasks) { task in
                        TaskRow(task: task, isExpanded: expanded == task.id) {
                            expanded = expanded == task.id ? nil : task.id
                        }
                        .listRowBackground(Tokens.dirt)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// New tasks go to the selected session's project, or the one named in the text.
    private func add() {
        store.addTask(draft, projectId: store.guessProject(for: draft) ?? store.selectedSession?.projectId)
        draft = ""
    }

    private var groups: [(title: String, tasks: [TaskItem])] {
        let byProject = Dictionary(grouping: store.tasks) { $0.projectId }
        var result = store.projects.compactMap { project in
            byProject[project.id].map { (title: project.name, tasks: $0) }
        }
        if let unsorted = byProject[nil] { result.append((title: "Unsorted", tasks: unsorted)) }
        return result
    }
}

private struct TaskRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    @State private var note = ""
    @State private var link = ""
    @State private var isPickingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button(task.isDone ? "[x]" : "[ ]") {
                    var updated = task
                    updated.isDone.toggle()
                    store.updateTask(updated)
                }
                .buttonStyle(.plain)
                .font(Fonts.mono(12))
                .foregroundStyle(task.isDone ? Tokens.selectionSoft : Tokens.text)
                Text(task.text)
                    .foregroundStyle(task.isDone ? Tokens.textDim : Tokens.text)
                    .strikethrough(task.isDone)
                    .lineLimit(isExpanded ? nil : 2)
                Spacer(minLength: 0)
                if !task.note.isEmpty || !task.attachments.isEmpty {
                    Text("✎\(task.attachments.isEmpty ? "" : " \(task.attachments.count)")").font(.caption).foregroundStyle(Tokens.textDim)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpand)
            if isExpanded { details }
        }
        .onAppear { note = task.note }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $note)
                .font(Fonts.mono(12))
                .foregroundStyle(Tokens.text)
                .scrollContentBackground(.hidden)
                .frame(height: 60)
                .padding(4)
                .background(Tokens.terminalBg)
                .sunken()
                .onChange(of: note) { var t = task; t.note = note; store.updateTask(t) }
            ForEach(task.attachments, id: \.self) { item in
                HStack {
                    Text(item.hasPrefix("/") ? URL(filePath: item).lastPathComponent : item)
                        .font(.caption).foregroundStyle(Tokens.screen).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("✕") { var t = task; t.attachments.removeAll { $0 == item }; store.updateTask(t) }
                        .buttonStyle(.plain).foregroundStyle(Tokens.textDim)
                }
                .help(item)
            }
            HStack(spacing: 6) {
                TextField("https://…", text: $link)
                    .textFieldStyle(.plain).font(.caption).foregroundStyle(Tokens.text)
                    .padding(4).background(Tokens.terminalBg).sunken()
                    .onSubmit(addLink)
                Button("+ LINK", action: addLink)
                Button("+ FILE") { isPickingFile = true }
                Button("+ SHOT") { Task { await addScreenshot() } }
                    .help("Select an area; the image stays with the task until it is deleted")
                Button("DELETE") { store.deleteTask(task.id!) }
            }
            .buttonStyle(PixelButtonStyle())
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let urls = try? result.get() else { return }
            var t = task
            t.attachments += urls.map(\.path)
            store.updateTask(t)
        }
    }

    private func addScreenshot() async {
        let file = TaskItem.attachmentsDir.appending(path: "\(UUID().uuidString).png")
        try? FileManager.default.createDirectory(at: TaskItem.attachmentsDir, withIntermediateDirectories: true)
        guard await ScreenshotFlow.capture(to: file) else { return }
        var t = task
        t.attachments.append(file.path)
        store.updateTask(t)
    }

    private func addLink() {
        let value = link.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        var t = task
        t.attachments.append(value)
        store.updateTask(t)
        link = ""
    }
}

/// Morning launch: paste today's list, open tasks carry over, sort by project, start all sessions.
/// TASKS in the title bar: the to-do list, and MORNING START to turn open tasks into sessions.
struct TasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isMorning = false

    var body: some View {
        if isMorning {
            MorningView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("TASKS").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                    Spacer()
                    Button("MORNING START") { isMorning = true }
                        .help("Pick open tasks and start a session for each")
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .buttonStyle(PixelButtonStyle())
                TasksView().background(Tokens.dirt).sunken()
            }
            .padding(16)
            .frame(width: 620, height: 600)
            .background(Tokens.grass)
            .pixelFrame(6)
            .preferredColorScheme(.dark)
        }
    }
}

struct MorningView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var selected: Set<Int64> = []

    var body: some View {
        let open = store.tasks.filter { !$0.isDone }
        VStack(alignment: .leading, spacing: 10) {
            Text("MORNING").font(Fonts.title(18)).foregroundStyle(Tokens.text)
            Text("One task per line. Projects are guessed by name — check them before starting.")
                .font(.caption).foregroundStyle(Tokens.textDim)
            HStack(alignment: .bottom, spacing: 6) {
                TextEditor(text: $pasted)
                    .font(Fonts.mono(12)).foregroundStyle(Tokens.text).scrollContentBackground(.hidden)
                    .frame(height: 80).padding(4).background(Tokens.terminalBg).sunken()
                Button("ADD") {
                    for line in AppStore.taskLines(pasted) {
                        if let task = store.addTask(line, projectId: store.guessProject(for: line)), let id = task.id { selected.insert(id) }
                    }
                    pasted = ""
                }
                .buttonStyle(PixelButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if open.isEmpty { Text("No open tasks").foregroundStyle(Tokens.textDim) }
                    ForEach(open) { task in MorningRow(task: task, selected: $selected) }
                }
            }
            .frame(minHeight: 160, maxHeight: 340)
            .padding(6)
            .background(Tokens.dirt)
            .sunken()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                let ready = open.filter { selected.contains($0.id!) && $0.projectId != nil }
                Button("START \(ready.count) SESSIONS") {
                    try? store.launchMorning(ready.compactMap(\.id))
                    dismiss()
                }
                .disabled(ready.isEmpty)
            }
            .buttonStyle(PixelButtonStyle())
        }
        .padding(16)
        .frame(width: 620)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
        // Open tasks from yesterday are in by default: "evening list → tomorrow's sessions".
        .onAppear { selected = Set(open.filter { $0.projectId != nil }.compactMap(\.id)) }
    }
}

private struct MorningRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    @Binding var selected: Set<Int64>

    var body: some View {
        let isOn = selected.contains(task.id!)
        HStack(spacing: 8) {
            Button(isOn ? "[x]" : "[ ]") { if isOn { selected.remove(task.id!) } else { selected.insert(task.id!) } }
                .buttonStyle(.plain).font(Fonts.mono(12)).foregroundStyle(Tokens.text)
            Text(task.text).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer()
            PixelMenu(selection: store.projects.first { $0.id == task.projectId }?.name ?? "— project —") {
                ForEach(store.projects) { project in
                    Button(project.name) {
                        var t = task
                        t.projectId = project.id
                        store.updateTask(t)
                        selected.insert(task.id!)
                    }
                }
            }
        }
    }
}

/// End of day: per project commits, stages, tokens, agent TODOs, next steps, tasks.
struct DayView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let days = store.daySummary()
        let text = AppStore.dayText(days)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DAY").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                Spacer()
                Button("COPY") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                ShareLink("SHARE", item: text)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(PixelButtonStyle())
            ScrollView {
                if days.isEmpty {
                    Text("Nothing happened today yet.").foregroundStyle(Tokens.textDim)
                }
                Text(text)
                    .font(Fonts.mono(12))
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Tokens.dirt)
            .sunken()
        }
        .padding(16)
        .frame(width: 680, height: 560)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
    }
}
