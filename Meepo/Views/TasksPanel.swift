import SwiftUI

/// What the Tasks tab lists: what's left to do, then what was done today. Older work is in the Done tab.
struct TaskBoard: Equatable {
    /// Oldest first. A task ticked a moment ago is still here (`lingering`), struck through, before it moves down.
    var open: [TaskItem]
    /// Latest first: the task just done lands right under the open ones.
    var doneToday: [TaskItem]

    init(_ tasks: [TaskItem], lingering: Set<Int64> = [], now: Date = .now, calendar: Calendar = .current) {
        func staysOpen(_ task: TaskItem) -> Bool { !task.isDone || task.id.map(lingering.contains) == true }
        open = tasks.filter(staysOpen).sorted { $0.createdAt < $1.createdAt }
        let midnight = calendar.startOfDay(for: now)
        doneToday = tasks.filter { !staysOpen($0) && ($0.doneAt ?? .distantPast) >= midnight }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    /// Today's work: done today out of done today plus still open.
    var doneCount: Int { doneToday.count + open.filter(\.isDone).count }
    var totalCount: Int { doneToday.count + open.count }
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
        feed = Dictionary(grouping: done.prefix(Self.feedLimit)) { calendar.startOfDay(for: $0.1) }
            .map { Group(date: $0.key, tasks: $0.value.map(\.0)) }
            .sorted { $0.date > $1.date }
    }
}

/// The to-do list at hand, next to the terminals: type a task, tick it, watch it move down to Done.
/// The Done tab shows the work behind it. Notes, attachments and the morning start stay in the Tasks sheet (the menu).
struct TasksPanel: View {
    enum Tab: String { case tasks, done }

    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var lingering: Set<Int64> = []
    @State private var editing: Int64?
    @AppStorage("tasksTab") private var tab = Tab.tasks
    @AppStorage("tasksDoneShown") private var isDoneShown = true
    @FocusState private var isAdding: Bool

    private enum Item: Identifiable {
        case project(String)
        case task(TaskItem)
        case done(count: Int)
        case empty(String)

        var id: String {
            switch self {
            case let .project(name): "project \(name)"
            case let .task(task): "task \(task.id ?? 0)"
            case .done: "done"
            case .empty: "empty"
            }
        }
    }

    var body: some View {
        let stats = DoneStats(store.tasks)
        VStack(alignment: .leading, spacing: 2) {
            tabs
            counters(stats)
            switch tab {
            case .tasks: list
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
    private var list: some View {
        let board = TaskBoard(store.tasks, lingering: lingering)
        let items = items(of: board)
        addField
        if board.totalCount > 0 { progress(board) }
        // One list for every row: a task that changes its section keeps its identity and slides to its new place.
        ForEach(items, content: row)
            .animation(.snappy(duration: 0.3), value: items.map(\.id))
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach([(Tab.tasks, "Tasks"), (.done, "Done")], id: \.0) { value, title in
                Button { tab = value } label: {
                    Text(title.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2)
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
        }
        .padding(.bottom, 6)
    }

    /// Always on top, whichever tab: what got done is what keeps you going.
    private func counters(_ stats: DoneStats) -> some View {
        HStack(spacing: 6) {
            counter(stats.today, "today", help: "Tasks closed today")
            counter(stats.week, "7 days", help: "Tasks closed today and the 6 days before")
            counter(stats.streak, stats.streak == 1 ? "day streak" : "days streak",
                    help: "Days in a row with at least one task closed")
        }
        .padding(.bottom, 8)
    }

    private func counter(_ value: Int, _ label: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(Fonts.ui(20, weight: .bold)).monospacedDigit()
                .foregroundStyle(value > 0 ? Tokens.added : Tokens.textDim)
                .contentTransition(.numericText())
            Text(label.uppercased()).font(Fonts.ui(10, weight: .bold)).tracking(1).foregroundStyle(Tokens.textDim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Tokens.ground, in: RoundedRectangle(cornerRadius: 8))
        .animation(.snappy(duration: 0.3), value: value)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case let .project(name): header(name)
        case let .task(task):
            TaskLine(task: task, isEditing: editing == task.id, onToggle: { toggle(task) },
                     onEdit: { editing = $0 ? task.id : nil })
        case let .done(count): section("Done today", count, isShown: $isDoneShown)
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
                items.append(.project("No project"))
                items += unsorted.map(Item.task)
            }
        } else {
            items += board.open.map(Item.task)
        }
        if !board.doneToday.isEmpty {
            items.append(.done(count: board.doneToday.count))
            if isDoneShown { items += board.doneToday.map(Item.task) }
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

/// Dates in the UI's language, whatever the Mac's.
private let english = Locale(identifier: "en_US")

/// The Done tab: the week's closed against added, then every closed task by day.
private struct DoneFeed: View {
    @Environment(AppStore.self) private var store
    let stats: DoneStats

    var body: some View {
        WeekChart(days: stats.days)
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
    let days: [DoneStats.Day]
    private let height: CGFloat = 52

    var body: some View {
        let top = max(1, days.map { max($0.closed, $0.added) }.max() ?? 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(days, id: \.date) { day in
                    VStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 2) {
                            bar(day.closed, of: top, Tokens.added)
                            bar(day.added, of: top, Tokens.idle)
                        }
                        .frame(height: height, alignment: .bottom)
                        Text(day.date.formatted(Date.FormatStyle().weekday(.narrow).locale(english)))
                            .font(Fonts.ui(10, weight: .bold)).foregroundStyle(Tokens.textDim)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(day.closed) closed, \(day.added) added")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.closed) closed, \(day.added) added")
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
