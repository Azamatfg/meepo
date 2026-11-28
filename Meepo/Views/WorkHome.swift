import SwiftUI

/// Home (2026-11-28): the week in a sentence, the next steps worth taking (each one click into Tasks), the user's
/// Claude Code setup level by level, and Claude's review of how they work and what their projects' stack is due
/// for. Counted from Claude Code's and Meepo's own files; only the review is a model call, once a day. The old
/// Home (Deck, Today) is in Settings → Everything else.
struct WorkHome: View {
    @Environment(AppStore.self) private var store
    @State private var facts: SetupFacts?
    @State private var review = WeekReview.load()
    @State private var isReviewing = false
    @State private var failure: String?
    @State private var added: Set<String> = []
    /// When the review last ran on its own: a failed one waits a day before trying again, not every visit to Home.
    @AppStorage("reviewTriedAt") private var triedAt = 0.0

    /// In the language the user writes their prompts in (SetupFacts.isRussian).
    private func t(_ en: String, _ ru: String) -> String { facts?.isRussian == true ? ru : en }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("This week", "Эта неделя") + (store.workspace.map { " · \($0)" } ?? "")).font(Fonts.ui(36, weight: .bold))
                    if let facts { Text(SetupMap.summary(facts)).font(Fonts.ui(16)).foregroundStyle(Tokens.textDim) }
                    // The review reads every project: its summary is the whole week's, shown with All.
                    if store.workspace == nil, let summary = review?.summary {
                        Text(summary).font(Fonts.ui(15)).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                            .frame(maxWidth: 1000, alignment: .leading) // a line longer than this is hard to read
                    }
                }
                // Full width in two columns: what to act on on the left, where you stand on the right.
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 28) {
                        if let facts { nextSteps(facts) }
                        principlesSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 28) {
                        ProdAgentsSection(isRussian: facts?.isRussian == true)
                        if let facts { setup(facts) }
                        stackSection
                    }
                    .frame(width: 400, alignment: .topLeading)
                }
            }
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Again whenever the title bar's workspace changes: the week is that workspace's.
        .task(id: store.workspace) {
            facts = await store.setupFacts()
            let isStale = review.map { Date.now.timeIntervalSince($0.createdAt ?? .distantPast) > WeekReview.refreshEvery } ?? true
            if isStale, Date.now.timeIntervalSince1970 - triedAt > 86400 {
                triedAt = Date.now.timeIntervalSince1970
                start()
            }
        }
    }

    // MARK: Next steps

    private func nextSteps(_ facts: SetupFacts) -> some View {
        let steps = SetupMap.steps(facts)
        let tips = review?.claudeCode ?? []
        return VStack(alignment: .leading, spacing: 10) {
            label(t("NEXT STEPS", "СЛЕДУЮЩИЕ ШАГИ"))
            if let noticed = store.visibleSuggestions.first { NoticedRow(suggestion: noticed, isCard: true) }
            ForEach(steps, id: \.title) { step in
                card(title: step.title, why: step.evidence, task: step.task)
            }
            ForEach(tips.prefix(max(0, 3 - steps.count)), id: \.title) { tip in
                card(title: tip.title, why: tip.why, task: tip.tryThis)
            }
            if steps.isEmpty && tips.isEmpty && store.visibleSuggestions.isEmpty {
                Text(t("Nothing stands out this week.", "На этой неделе ничего не выделяется.")).foregroundStyle(Tokens.textDim)
            }
        }
    }

    private func card(title: String, why: String, task: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Fonts.ui(16, weight: .semibold))
                Text(why).font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                Text(task).font(Fonts.ui(13)).foregroundStyle(Tokens.work).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(added.contains(task) ? t("IN TASKS", "В ЗАДАЧАХ") : t("TO TASKS", "В ЗАДАЧИ")) {
                if store.addTask(task, projectId: nil) != nil { added.insert(task) }
            }
            .buttonStyle(PixelButtonStyle(compact: true, isPrimary: !added.contains(task)))
            .disabled(added.contains(task))
            .help("Put this step in your Tasks list")
        }
        .padding(16)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
    }

    // MARK: Setup map

    private func setup(_ facts: SetupFacts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label(t("YOUR CLAUDE CODE SETUP", "ТВОЙ СЕТАП CLAUDE CODE"))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SetupMap.levels(facts), id: \.name) { level in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(level.name).font(Fonts.ui(14, weight: .bold))
                        ForEach(level.items, id: \.name) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: Self.symbol(item.state)).foregroundStyle(Self.color(item.state))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(Fonts.ui(13, weight: .semibold))
                                    Text(item.detail).font(.caption).foregroundStyle(Tokens.textDim).lineLimit(2)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
                }
            }
        }
    }

    private static func symbol(_ state: SetupMap.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .partly: "circle.lefthalf.filled"
        case .missing: "circle"
        }
    }

    private static func color(_ state: SetupMap.State) -> Color {
        switch state {
        case .done: Tokens.work
        case .partly: Tokens.need
        case .missing: Tokens.textDim
        }
    }

    // MARK: Review

    private var principlesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                label(t("HOW THE BEST WORK — AND YOU", "КАК РАБОТАЮТ ЛУЧШИЕ — И ТЫ"))
                if isReviewing { Text(t("Claude is reading your week…", "Claude читает твою неделю…")).font(.caption).foregroundStyle(Tokens.textDim) }
                Spacer()
                if !isReviewing, review != nil {
                    Button(t("AGAIN", "ЕЩЁ РАЗ")) { start() }.buttonStyle(PixelButtonStyle(compact: true))
                        .help("Research again: how strong engineers work, then your projects — Opus, a few minutes")
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(Tokens.need) }
            Text(t("Claude Opus, once a week: first researches how strong engineers and researchers work and why (their own writing, with sources), then reads your busiest projects (read-only) and recommends from those principles. A second opinion, not a verdict.",
                   "Claude Opus раз в неделю: сначала изучает, как работают сильные инженеры и исследователи и почему (их собственные тексты, со ссылками), потом читает твои самые активные проекты (только чтение) и советует из этих принципов. Это второе мнение, а не приговор."))
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            ForEach(review?.principles ?? [], id: \.name) { principle in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(principle.name).font(Fonts.ui(16, weight: .semibold))
                        Spacer(minLength: 8)
                        Button(added.contains(principle.step) ? t("IN TASKS", "В ЗАДАЧАХ") : t("TO TASKS", "В ЗАДАЧИ")) {
                            if store.addTask(principle.step, projectId: nil) != nil { added.insert(principle.step) }
                        }
                        .buttonStyle(PixelButtonStyle(compact: true, isPrimary: !added.contains(principle.step)))
                        .disabled(added.contains(principle.step))
                    }
                    Text(principle.who).font(Fonts.ui(12, weight: .semibold)).foregroundStyle(Tokens.textDim)
                    Text(principle.why).font(Fonts.ui(13)).fixedSize(horizontal: false, vertical: true)
                    (Text(t("In your work: ", "У тебя: ")).bold() + Text(principle.inYourWork))
                        .font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                    Text(principle.step).font(Fonts.ui(13)).foregroundStyle(Tokens.work).fixedSize(horizontal: false, vertical: true)
                    if let url = URL(string: principle.source), url.scheme?.hasPrefix("http") == true {
                        Link(url.host() ?? principle.source, destination: url).font(.caption)
                    }
                }
                .padding(16)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
            }
        }
    }

    /// The review's calls on tools and practices for the projects shown, beside the setup map.
    private var stackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !techHere.isEmpty { label(t("TOOLS AND PRACTICES FOR YOUR PROJECTS", "ИНСТРУМЕНТЫ И ПРАКТИКИ ДЛЯ ТВОИХ ПРОЕКТОВ")) }
            ForEach(techHere, id: \.title) { tech in
                HStack(alignment: .top, spacing: 12) {
                    Text((facts?.isRussian == true ? ["now": "сейчас", "not yet": "рано", "drop it": "убрать"][tech.verdict] ?? tech.verdict : tech.verdict).uppercased())
                        .font(Fonts.ui(10, weight: .bold)).tracking(1)
                        .foregroundStyle(tech.verdict == "now" ? Tokens.work : tech.verdict == "drop it" ? Tokens.need : Tokens.textDim)
                        .frame(width: 64, alignment: .leading)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(tech.project) · \(tech.title)").font(Fonts.ui(15, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let principle = tech.principle, !principle.isEmpty {
                            Text("← \(principle)").font(.caption).foregroundStyle(Tokens.textDim)
                        }
                        Text(tech.why).font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                        Text(tech.tryThis).font(Fonts.ui(13)).foregroundStyle(Tokens.work).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The review's calls for the projects of the workspace shown (a call naming several counts if one is here).
    private var techHere: [WeekReview.Tech] {
        let tech = review?.tech ?? []
        guard store.workspace != nil else { return tech }
        let names = store.workspaceProjects.map(\.name)
        return tech.filter { item in names.contains { item.project.localizedCaseInsensitiveContains($0) } }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Fonts.ui(11, weight: .bold)).tracking(1.4).foregroundStyle(Tokens.textDim)
    }

    private func start() {
        isReviewing = true
        failure = nil
        Task {
            do { review = try await store.reviewWeek() } catch { failure = error.localizedDescription }
            isReviewing = false
        }
    }
}
