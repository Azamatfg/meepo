import SwiftUI

/// What the Tasks tab lists: the active tasks, then what was done today; and the open ones set aside.
/// Older work is in the Done tab.
struct TaskBoard: Equatable {
    /// Active, oldest first. A task ticked a moment ago is still here (`lingering`), struck through, before it moves down.
    var open: [TaskItem]
    /// Latest first: the task just done lands right under the open ones.
    var doneToday: [TaskItem]
    /// What agents found, the latest first; not in the list until the user takes it.
    var inbox: [TaskItem]
    var waiting: [TaskItem]
    var later: [TaskItem]

    /// More active than this and the panel suggests moving some to Later. Only suggests.
    static let crowdedLimit = 5

    init(_ tasks: [TaskItem], lingering: Set<Int64> = [], now: Date = .now, calendar: Calendar = .current) {
        func staysOpen(_ task: TaskItem) -> Bool { task.isActive || task.id.map(lingering.contains) == true }
        func open(_ status: TaskStatus) -> [TaskItem] {
            tasks.filter { !$0.isDone && $0.status == status }.sorted { $0.createdAt < $1.createdAt }
        }
        self.open = tasks.filter(staysOpen).sorted { $0.createdAt < $1.createdAt }
        inbox = open(.inbox).reversed()
        waiting = open(.waiting)
        later = open(.later)
        let midnight = calendar.startOfDay(for: now)
        doneToday = tasks.filter { $0.isDone && !staysOpen($0) && ($0.doneAt ?? .distantPast) >= midnight }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    /// Today's work: done today out of done today plus still open.
    var doneCount: Int { doneToday.count + open.filter(\.isDone).count }
    var totalCount: Int { doneToday.count + open.count }
    var isCrowded: Bool { open.filter { !$0.isDone }.count > Self.crowdedLimit }
}

extension TaskStatus {
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .active: "Tasks"
        case .later: "Later"
        case .waiting: "Waiting on others"
        }
    }
}

/// What got done, for the Done tab: so the work shows, not only what's left.
struct DoneStats: Equatable {
    struct Day: Equatable {
        var date: Date
        var closed: Int
        var added: Int
    }

    struct Group: Equatable {
        var date: Date
        var tasks: [TaskItem]
    }

    var today: Int
    /// Today and the 6 days before it.
    var week: Int
    /// Days in a row with a task closed, up to today — or up to yesterday while nothing is closed yet today.
    var streak: Int
    /// The last 7 days, oldest first: closed against added, a fairer picture than what's left.
    var days: [Day]
    /// Done tasks by the day they were closed, the latest first.
    var feed: [Group]
    /// The first day of the streak; nil without one.
    var streakStart: Date?
    /// Tomorrow's midnight: every period ends here.
    var end: Date
    private var tasks: [TaskItem]

    static let feedLimit = 100

    init(_ tasks: [TaskItem], now: Date = .now, calendar: Calendar = .current) {
        let done = tasks.compactMap { task in task.isDone ? task.doneAt.map { (task, $0) } : nil }.sorted { $0.1 > $1.1 }
        let closedDays = Set(done.map { calendar.startOfDay(for: $0.1) })
        let midnight = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: midnight)! }
        days = (-6...0).map { offset in
            let start = day(offset), end = day(offset + 1)
            return Day(date: start, closed: done.filter { $0.1 >= start && $0.1 < end }.count,
                       added: tasks.filter { $0.createdAt >= start && $0.createdAt < end }.count)
        }
        today = days.last!.closed
        week = days.map(\.closed).reduce(0, +)
        let first = closedDays.contains(midnight) ? 0 : -1
        var cursor = first
        while closedDays.contains(day(cursor)) { cursor -= 1 }
        streak = first - cursor
        streakStart = streak > 0 ? day(cursor + 1) : nil
        end = day(1)
        self.tasks = tasks
        feed = Dictionary(grouping: done.prefix(Self.feedLimit)) { calendar.startOfDay(for: $0.1) }
            .map { Group(date: $0.key, tasks: $0.value.map(\.0)) }
            .sorted { $0.date > $1.date }
    }

    /// Closed in the period, the latest first.
    func closed(since start: Date, until end: Date) -> [TaskItem] {
        tasks.filter { task in task.isDone && task.doneAt.map { $0 >= start && $0 < end } == true }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    /// Written in the period, the latest first.
    func added(since start: Date, until end: Date) -> [TaskItem] {
        tasks.filter { $0.createdAt >= start && $0.createdAt < end }.sorted { $0.createdAt > $1.createdAt }
    }
}

/// The to-do list at hand, next to the terminals: type a task, tick it, watch it move down to Done.
/// The Done tab shows the work behind it. Notes, attachments and the morning start stay in the Tasks sheet (the menu).
struct TasksPanel: View {
    enum Tab: String { case tasks, inbox, done }

    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var lingering: Set<Int64> = []
    @State private var editing: Int64?
    @AppStorage("tasksTab") private var tab = Tab.tasks
    @AppStorage("tasksDoneShown") private var isDoneShown = true
    @State private var isWaitingShown = false
    @State private var isLaterShown = false
    @FocusState private var isAdding: Bool
    /// SELECT: a click ticks a task instead of opening it; the bar below moves the ticked ones all at once.
    @State private var isSelecting = false
    @State private var selected: Set<Int64> = []

    private enum Item: Identifiable {
        case project(String)
        case task(TaskItem)
        case done(count: Int)
        case waiting(count: Int)
        case later(count: Int)
        case crowded
        case empty(String)

        var id: String {
            switch self {
            case let .project(name): "project \(name)"
            case let .task(task): "task \(task.id ?? 0)"
            case .done: "done"
            case .waiting: "waiting"
            case .later: "later"
            case .crowded: "crowded"
            case .empty: "empty"
            }
        }
    }

    var body: some View {
        // The workspace shown in the title bar: its tasks only (All: every task).
        let stats = DoneStats(store.workspaceTasks)
        let board = TaskBoard(store.workspaceTasks, lingering: lingering)
        VStack(alignment: .leading, spacing: 2) {
            tabs(inbox: board.inbox.count)
            if isSelecting { bulkBar } else { counters(stats) }
            switch tab {
            case .tasks: list(board)
            case .inbox: InboxList(tasks: board.inbox)
            case .done: DoneFeed(stats: stats)
            }
        }
        // Claude closes tasks with `sqlite3` from its sessions: shown here without a restart.
        .task {
            while !Task.isCancelled {
                store.reloadTasksIfChangedOutside()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private func list(_ board: TaskBoard) -> some View {
        let items = items(of: board)
        addField
        if board.totalCount > 0 { progress(board) }
        // One list for every row: a task that changes its section keeps its identity and slides to its new place.
        ForEach(items, content: row)
            .animation(.snappy(duration: 0.3), value: items.map(\.id))
    }

    /// What the ticked tasks can do at once.
    private var bulkBar: some View {
        let ids = Array(selected)
        return HStack(spacing: 6) {
            Text("\(ids.count) selected").font(Fonts.ui(12, weight: .semibold)).foregroundStyle(Tokens.textDim)
            Menu("Workspace") {
                ForEach(store.workspaceNames, id: \.self) { name in
                    Button(name) { store.moveTasks(ids, toWorkspace: name); selected = [] }
                }
                if !store.workspaceNames.isEmpty { Divider() }
                Button("Their projects' workspace") { store.moveTasks(ids, toWorkspace: nil); selected = [] }
                Button("New Workspace…") { store.isWorkspacesShown = true }
            }
            Menu("Project") {
                ForEach(store.projects) { project in
                    Button(project.name) { store.moveTasks(ids, toProject: project.id); selected = [] }
                }
                Divider()
                Button("No project") { store.moveTasks(ids, toProject: nil); selected = [] }
            }
            Button("Later") {
                for task in store.tasks where ids.contains(task.id ?? -1) { var t = task; t.status = .later; store.updateTask(t) }
                selected = []
            }
            Spacer()
        }
        .menuStyle(.button)
        .buttonStyle(PixelButtonStyle(compact: true))
        .disabled(ids.isEmpty)
        .padding(.vertical, 6)
    }

    private func tabs(inbox: Int) -> some View {
        HStack(spacing: 4) {
            ForEach([(Tab.tasks, "Tasks"), (.inbox, "Inbox"), (.done, "Done")], id: \.0) { value, title in
                Button { tab = value } label: {
                    HStack(spacing: 5) {
                        Text(title.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2)
                        if value == .inbox, inbox > 0 {
                            Text("\(inbox)").font(Fonts.ui(10, weight: .bold)).monospacedDigit().foregroundStyle(Tokens.surface)
                                .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16).background(Tokens.work, in: Capsule())
                                .help("Not sorted yet: what agents found while they worked")
                        }
                    }
                    .foregroundStyle(tab == value ? Tokens.text : Tokens.textDim)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(tab == value ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tab == value ? Tokens.line : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == value ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if tab == .tasks {
                Button(isSelecting ? "DONE" : "SELECT") { isSelecting.toggle(); selected = [] }
                    .buttonStyle(PixelButtonStyle(compact: true))
                    .help("Tick several tasks, then move them to a workspace or a project at once")
            }
        }
        .padding(.bottom, 6)
    }

    /// Always on top, whichever tab: what got done is what keeps you going.
    private func counters(_ stats: DoneStats) -> some View {
        HStack(spacing: 6) {
            counter(stats.today, "today", help: "Tasks closed today — click to see them") {
                ClosedList(title: "Closed today", closed: stats.closed(since: stats.days.last!.date, until: stats.end))
            }
            counter(stats.week, "7 days", help: "Tasks closed today and the 6 days before — click to see them") {
                ClosedList(title: "Closed in 7 days", closed: stats.closed(since: stats.days.first!.date, until: stats.end), showsDay: true)
            }
            counter(stats.streak, stats.streak == 1 ? "day streak" : "days streak",
                    help: "Days in a row with at least one task closed — click to see them") {
                ClosedList(title: "The streak, \(stats.streak) \(stats.streak == 1 ? "day" : "days")",
                           closed: stats.streakStart.map { stats.closed(since: $0, until: stats.end) } ?? [], showsDay: true)
            }
        }
        .padding(.bottom, 8)
    }

    private func counter(_ value: Int, _ label: String, help: String, list: @escaping () -> ClosedList) -> some View {
        CounterTile(value: value, label: label, help: help, list: list)
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case let .project(name): header(name)
        case let .task(task):
            if isSelecting, let id = task.id {
                Button { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: selected.contains(id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected.contains(id) ? Tokens.work : Tokens.textDim).padding(.top, 2)
                        TaskLine(task: task, isEditing: false, onToggle: {}, onEdit: { _ in }).allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                TaskLine(task: task, isEditing: editing == task.id, onToggle: { toggle(task) },
                         onEdit: { editing = $0 ? task.id : nil })
            }
        case let .done(count): section("Done today", count, isShown: $isDoneShown)
        case let .waiting(count): section(TaskStatus.waiting.title, count, isShown: $isWaitingShown)
        case let .later(count): section(TaskStatus.later.title, count, isShown: $isLaterShown)
        case .crowded:
            Label("Lots in progress — move some to Later (right-click a task)", systemImage: "lightbulb")
                .font(Fonts.ui(11)).foregroundStyle(Tokens.textDim)
                .padding(.horizontal, 8).padding(.top, 6)
        case let .empty(text):
            Text(text).font(Fonts.ui(12)).foregroundStyle(Tokens.textDim).padding(.horizontal, 8).padding(.vertical, 10)
        }
    }

    private func items(of board: TaskBoard) -> [Item] {
        var items: [Item] = []
        if board.open.isEmpty {
            items.append(.empty(board.doneToday.isEmpty ? "Nothing here yet. Type a task above and press Return." : "All done for today."))
        }
        // Project names only when they tell tasks apart.
        let byProject = Dictionary(grouping: board.open) { $0.projectId }
        if byProject.count > 1 {
            for project in store.projects {
                guard let tasks = byProject[project.id] else { continue }
                items.append(.project(project.name))
                items += tasks.map(Item.task)
            }
            if let unsorted = byProject[nil] {
                // No one project: a whole workspace's, or all projects'.
                for (workspace, tasks) in Dictionary(grouping: unsorted, by: \.workspace).sorted(by: { ($0.key ?? "~") < ($1.key ?? "~") }) {
                    items.append(.project(workspace.map { store.workspace == nil ? "Whole workspace · \($0)" : "Whole workspace" } ?? "All projects"))
                    items += tasks.map(Item.task)
                }
            }
        } else {
            items += board.open.map(Item.task)
        }
        if board.isCrowded { items.append(.crowded) }
        if !board.doneToday.isEmpty {
            items.append(.done(count: board.doneToday.count))
            if isDoneShown { items += board.doneToday.map(Item.task) }
        }
        if !board.waiting.isEmpty {
            items.append(.waiting(count: board.waiting.count))
            if isWaitingShown { items += board.waiting.map(Item.task) }
        }
        if !board.later.isEmpty {
            items.append(.later(count: board.later.count))
            if isLaterShown { items += board.later.map(Item.task) }
        }
        return items
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(isAdding ? Tokens.work : Tokens.textDim)
            TextField("Add a task", text: $draft)
                .textFieldStyle(.plain)
                .font(Fonts.ui(13))
                .focused($isAdding)
                .onSubmit(add)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Tokens.ground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isAdding ? Tokens.work : Tokens.line))
        .contentShape(Rectangle())
        .onTapGesture { isAdding = true }
        .help("Return adds it — to the project its text names, else to the open session's project")
        .padding(.bottom, 6)
    }

    private func progress(_ board: TaskBoard) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.line)
                    Capsule().fill(board.doneCount == board.totalCount ? Tokens.added : Tokens.work)
                        .frame(width: geometry.size.width * CGFloat(board.doneCount) / CGFloat(board.totalCount))
                }
            }
            .frame(height: 4)
            Text("\(board.doneCount) of \(board.totalCount) today").font(Fonts.ui(11)).foregroundStyle(Tokens.textDim).monospacedDigit().fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.3), value: board.doneCount)
        .help("Done today out of everything open today")
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim).lineLimit(1)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
    }

    private func section(_ title: String, _ count: Int, isShown: Binding<Bool>) -> some View {
        Button { isShown.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(isShown.wrappedValue ? 90 : 0))
                Text(title.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2)
                Text("\(count)").font(Fonts.ui(11)).monospacedDigit()
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.textDim)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count), \(isShown.wrappedValue ? "shown" : "hidden")")
    }

    /// New tasks go to the project named in the text, or the selected session's.
    private func add() {
        store.addTask(draft, projectId: store.guessProject(for: draft) ?? store.selectedSession?.projectId)
        draft = ""
        isAdding = true // the next one can be typed right away
    }

    private func toggle(_ task: TaskItem) {
        guard let id = task.id else { return }
        var updated = task
        updated.isDone.toggle()
        store.updateTask(updated)
        guard updated.isDone else {
            lingering.remove(id)
            return
        }
        // Stays where it was for a moment, struck through: long enough to see it done, and to take a misclick back.
        lingering.insert(id)
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            lingering.remove(id)
        }
    }
}

private struct TaskLine: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    let isEditing: Bool
    let onToggle: () -> Void
    let onEdit: (Bool) -> Void
    @State private var isHovered = false
    @State private var text = ""
    @FocusState private var isTyping: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onToggle) {
                ZStack {
                    Circle().strokeBorder(task.isDone || isHovered ? Tokens.work : Tokens.idle, lineWidth: 1.5)
                    if task.isDone {
                        Circle().fill(Tokens.work)
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Tokens.surface)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Not done: \(task.text)" : "Done: \(task.text)")
            if isEditing {
                TextField("Task", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Fonts.ui(13))
                    .focused($isTyping)
                    .onSubmit(save)
                    .onExitCommand { onEdit(false) }
                    .onAppear {
                        text = task.text
                        isTyping = true
                    }
            } else {
                Text(task.text)
                    .font(Fonts.ui(13))
                    .foregroundStyle(task.isDone ? Tokens.textDim : Tokens.text)
                    .strikethrough(task.isDone, color: Tokens.textDim)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) { if !task.isDone { onEdit(true) } }
            }
            Spacer(minLength: 0)
            if !task.note.isEmpty || !task.attachments.isEmpty {
                Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(Tokens.textDim).padding(.top, 3)
                    .help("Has a note or attachments — open Tasks in the menu to see them")
            }
            if isHovered, !task.isDone, !isEditing, task.projectId != nil {
                Button(action: start) {
                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Tokens.work).frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Start a Claude session with this task as its first message")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovered ? Tokens.ghost : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if !task.isDone {
                Button("Edit") { onEdit(true) }
                Button("Start a session with it", action: start).disabled(task.projectId == nil)
                Menu("Project") {
                    ForEach(store.projects) { project in
                        Toggle(project.name, isOn: Binding(get: { task.projectId == project.id }, set: { _ in move(to: project.id) }))
                    }
                    Divider()
                    Toggle("No project", isOn: Binding(get: { task.projectId == nil }, set: { _ in move(to: nil) }))
                }
                // A task for a whole workspace (no one project), or for all projects.
                Menu("Workspace") {
                    ForEach(store.workspaceNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { store.workspace(of: task) == name },
                                                   set: { _ in if let id = task.id { store.moveTasks([id], toWorkspace: name) } }))
                    }
                    if !store.workspaceNames.isEmpty { Divider() }
                    Toggle("All projects", isOn: Binding(get: { task.projectId == nil && task.workspace == nil },
                                                         set: { _ in if let id = task.id { store.moveTasksToAllProjects([id]) } }))
                }
                Menu("Move to") {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Toggle(status.title, isOn: Binding(get: { task.status == status }, set: { _ in store.setStatus(task, status) }))
                    }
                }
                Divider()
            }
            Button("Delete", role: .destructive) { if let id = task.id { store.deleteTask(id) } }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != task.text {
            var updated = task
            updated.text = trimmed
            store.updateTask(updated)
        }
        onEdit(false)
    }

    private func move(to projectId: Int64?) {
        var updated = task
        updated.projectId = projectId
        store.updateTask(updated)
    }

    private func start() {
        guard let id = task.id else { return }
        do { try store.launchMorning([id]) } catch { store.bridgeError = error.localizedDescription }
    }
}

/// The Inbox tab: what agents found while they worked. Each one is taken into the list, put off, or dropped.
private struct InboxList: View {
    @Environment(AppStore.self) private var store
    let tasks: [TaskItem]

    var body: some View {
        if tasks.isEmpty {
            Text("Inbox is empty. What agents find while they work lands here, not in your list.")
                .font(Fonts.ui(12)).foregroundStyle(Tokens.textDim).padding(.horizontal, 8).padding(.vertical, 10)
        }
        ForEach(tasks) { task in
            VStack(alignment: .leading, spacing: 6) {
                Text(task.text).font(Fonts.ui(13)).foregroundStyle(Tokens.text).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let project = store.projects.first(where: { $0.id == task.projectId }) {
                        Text(project.name).font(Fonts.ui(11)).foregroundStyle(Tokens.textDim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    action("Do", filled: true, help: "Into the list") { store.setStatus(task, .active) }
                    action("Later", help: "Out of the way, kept under Later") { store.setStatus(task, .later) }
                    Button { if let id = task.id { store.deleteTask(id) } } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Tokens.textDim).frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                    .accessibilityLabel("Delete: \(task.text)")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(Tokens.ground, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 4)
            .transition(.opacity)
        }
    }

    private func action(_ title: String, filled: Bool = false, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title.uppercased()).font(Fonts.ui(10, weight: .bold)).tracking(1)
                .foregroundStyle(filled ? Tokens.surface : Tokens.text)
                .padding(.horizontal, 9).frame(height: 22)
                .background(filled ? Tokens.work : Tokens.raised, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filled ? .clear : Tokens.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Dates in the UI's language, whatever the Mac's.
private let english = Locale(identifier: "en_US")

/// The Done tab: the week's closed against added, then every closed task by day.
private struct DoneFeed: View {
    @Environment(AppStore.self) private var store
    let stats: DoneStats

    var body: some View {
        WeekChart(stats: stats)
        if stats.feed.isEmpty {
            Text("Nothing closed yet. Tick a task in Tasks and it shows up here.")
                .font(Fonts.ui(12)).foregroundStyle(Tokens.textDim).padding(.horizontal, 8).padding(.vertical, 10)
        }
        ForEach(stats.feed, id: \.date) { group in
            HStack(spacing: 6) {
                Text(Self.title(of: group.date).uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2)
                Text("\(group.tasks.count)").font(Fonts.ui(11)).monospacedDigit()
            }
            .foregroundStyle(Tokens.textDim)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
            ForEach(group.tasks) { task in row(task) }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Tokens.added).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.text).font(Fonts.ui(13)).foregroundStyle(Tokens.text).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(([store.projects.first { $0.id == task.projectId }?.name,
                       task.doneAt?.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(english))]
                        .compactMap { $0 }).joined(separator: " · "))
                    .font(Fonts.ui(11)).foregroundStyle(Tokens.textDim)
                if let outcome = task.outcome {
                    Text(outcome).font(Fonts.ui(11)).foregroundStyle(Tokens.textDim).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contextMenu {
            Button("Mark as not done") {
                var reopened = task
                reopened.isDone = false
                store.updateTask(reopened)
            }
            Button("Delete", role: .destructive) { if let id = task.id { store.deleteTask(id) } }
        }
    }

    static func title(of day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().locale(english))
    }
}

/// Closed against added, day by day for a week: a list that grows while you close ten a day is not you falling behind.
private struct WeekChart: View {
    @Environment(AppStore.self) private var store
    let stats: DoneStats
    @State private var shown: Date?
    @State private var hovered: Date?
    private let height: CGFloat = 52
    private var days: [DoneStats.Day] { stats.days }

    var body: some View {
        let top = max(1, days.map { max($0.closed, $0.added) }.max() ?? 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(days, id: \.date) { day in
                    Button { shown = shown == day.date ? nil : day.date } label: { column(day, top: top) }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? day.date : (hovered == day.date ? nil : hovered) }
                        .popover(isPresented: Binding(get: { shown == day.date }, set: { if !$0 { shown = nil } }), arrowEdge: .bottom) {
                            let end = Calendar.current.date(byAdding: .day, value: 1, to: day.date)!
                            ClosedList(title: DoneFeed.title(of: day.date), closed: stats.closed(since: day.date, until: end),
                                       added: stats.added(since: day.date, until: end))
                                .environment(store)
                        }
                }
            }
            HStack(spacing: 12) {
                legend(Tokens.added, "Closed \(days.map(\.closed).reduce(0, +))")
                legend(Tokens.idle, "Added \(days.map(\.added).reduce(0, +))")
            }
        }
        .padding(10)
        .background(Tokens.ground, in: RoundedRectangle(cornerRadius: 8))
    }

    private func column(_ day: DoneStats.Day, top: Int) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                bar(day.closed, of: top, Tokens.added)
                bar(day.added, of: top, Tokens.idle)
            }
            .frame(height: height, alignment: .bottom)
            Text(day.date.formatted(Date.FormatStyle().weekday(.narrow).locale(english)))
                .font(Fonts.ui(10, weight: .bold)).foregroundStyle(Tokens.textDim)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(hovered == day.date || shown == day.date ? Tokens.grassLight : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .help("\(day.closed) closed, \(day.added) added — click to see them")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.closed) closed, \(day.added) added")
    }

    private func bar(_ value: Int, of top: Int, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(color)
            .frame(width: 7, height: value == 0 ? 2 : max(3, height * CGFloat(value) / CGFloat(top)))
            .opacity(value == 0 ? 0.35 : 1)
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title.uppercased()).font(Fonts.ui(10, weight: .bold)).tracking(1).foregroundStyle(Tokens.textDim).monospacedDigit()
        }
    }
}

/// A number on top of the panel; a click shows the tasks behind it.
private struct CounterTile: View {
    @Environment(AppStore.self) private var store
    let value: Int
    let label: String
    let help: String
    let list: () -> ClosedList
    @State private var isShown = false
    @State private var isHovered = false

    var body: some View {
        Button { isShown.toggle() } label: { tile }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .popover(isPresented: $isShown, arrowEdge: .bottom) { list().environment(store) }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(Fonts.ui(20, weight: .bold)).monospacedDigit()
                .foregroundStyle(value > 0 ? Tokens.added : Tokens.textDim)
                .contentTransition(.numericText())
            Text(label.uppercased()).font(Fonts.ui(10, weight: .bold)).tracking(1).foregroundStyle(Tokens.textDim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isHovered || isShown ? Tokens.grassLight : Tokens.ground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isShown ? Tokens.line : .clear))
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.3), value: value)
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

/// The tasks behind a number or a day of the chart, in a popover.
private struct ClosedList: View {
    @Environment(AppStore.self) private var store
    let title: String
    let closed: [TaskItem]
    var added: [TaskItem]?
    var showsDay = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.text)
                    .padding(.horizontal, 6).padding(.bottom, 4)
                section(added == nil ? nil : "Closed", closed, at: \.doneAt, mark: "checkmark.circle.fill", Tokens.added)
                if let added { section("Added", added, at: { $0.createdAt }, mark: "plus.circle", Tokens.idle) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func section(_ name: String?, _ tasks: [TaskItem], at time: @escaping (TaskItem) -> Date?, mark: String, _ color: Color) -> some View {
        if let name {
            Text("\(name.uppercased())  \(tasks.count)").font(Fonts.ui(10, weight: .bold)).tracking(1).foregroundStyle(Tokens.textDim)
                .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
        }
        if tasks.isEmpty {
            Text("None").font(Fonts.ui(12)).foregroundStyle(Tokens.textDim).padding(.horizontal, 6).padding(.vertical, 4)
        }
        ForEach(tasks) { task in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mark).font(.system(size: 12)).foregroundStyle(color).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.text).font(Fonts.ui(12)).foregroundStyle(Tokens.text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(([store.projects.first { $0.id == task.projectId }?.name, time(task).map(stamp)].compactMap { $0 })
                        .joined(separator: " · "))
                        .font(Fonts.ui(10)).foregroundStyle(Tokens.textDim)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
    }

    private func stamp(_ date: Date) -> String {
        date.formatted((showsDay ? Date.FormatStyle().weekday(.abbreviated) : Date.FormatStyle()).hour().minute().locale(english))
    }
}
