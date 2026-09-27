import SwiftUI

/// One thing Meepo noticed in the user's history, with what it offers and "Not now".
struct NoticedRow: View {
    @Environment(AppStore.self) private var store
    let suggestion: Noticing.Suggestion
    var isCard = false
    @State private var isDrafting = false
    @State private var error: String?

    var body: some View {
        let isRetired = store.isRetired(suggestion)
        HStack(alignment: .center, spacing: 18) {
            // A 0.3 button may no longer be a habit in the history: no count to show then.
            if suggestion.count > 0 {
                Text("\(suggestion.count)×").font(Fonts.ui(isCard ? 40 : 26, weight: .bold)).foregroundStyle(Tokens.work)
                    .frame(minWidth: isCard ? 80 : 56, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                if isCard {
                    Text(isRetired ? "FROM MEEPO 0.3" : "MEEPO NOTICED").font(Fonts.ui(11, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Tokens.work)
                }
                Text(title).font(Fonts.ui(isCard ? 18 : 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.caption).foregroundStyle(Tokens.danger) }
            }
            Spacer(minLength: 8)
            switch suggestion.kind {
            case let .chain(commands):
                Button(isRetired ? "Make it again" : "Make a button") {
                    do { try store.makeButton(from: suggestion) } catch { self.error = error.localizedDescription }
                }
                .help("Saves /" + Recipes.buttonName(for: commands) + " as a skill of yours and puts it next to the stages")
                    .buttonStyle(PixelButtonStyle(compact: !isCard, isPrimary: true))
            case .skill:
                Button("Draft a skill…") { isDrafting = true }
                    .buttonStyle(PixelButtonStyle(compact: !isCard, isPrimary: true))
            }
            Button("Not now") { store.dismissSuggestion(suggestion) }
                .buttonStyle(PixelButtonStyle(compact: !isCard))
                .help(isRetired ? "Not shown again — unless you keep running them in a row" : "Hidden until you've done it twice as often")
        }
        .padding(isCard ? 18 : 12)
        .background(isCard ? Tokens.raised : Tokens.surface, in: RoundedRectangle(cornerRadius: isCard ? 16 : 10))
        .overlay(RoundedRectangle(cornerRadius: isCard ? 16 : 10).strokeBorder(Tokens.line))
        .sheet(isPresented: $isDrafting) { SkillDraftSheet(suggestion: suggestion) }
    }

    private var title: String {
        let isRetired = store.isRetired(suggestion)
        switch suggestion.kind {
        case let .chain(commands) where isRetired:
            return "Your " + commands.map { "/" + $0 }.joined(separator: " → ") + " button from meepo 0.3 is off"
        case let .chain(commands): return "You run " + commands.map { "/" + $0 }.joined(separator: " → ") + " one after another"
        case let .skill(phrase): return "You keep asking: “\(phrase)”"
        }
    }

    private var detail: String {
        let isRetired = store.isRetired(suggestion)
        switch suggestion.kind {
        case let .chain(commands) where isRetired:
            return "0.4 switched it off, because meepo no longer types into your terminal on its own. Make it again as /"
                + Recipes.buttonName(for: commands)
                + ": a skill of your own that runs them in order — in meepo and in any terminal. Claude stops if one asks you something."
        case .chain: return "In the last 8 weeks. A button runs them in order, as a skill of your own: each starts when the one before has finished, and Claude stops if one asks you something."
        case .skill: return "In the last 8 weeks. A skill of your own does it with one command — Claude drafts it, you read and save it."
        }
    }
}

/// Claude drafts a skill for a repeated request; the user reads, edits, names and saves it — or doesn't.
struct SkillDraftSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let suggestion: Noticing.Suggestion
    @State private var text = ""
    @State private var name = ""
    @State private var error: String?
    @State private var isWorking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New skill").font(Fonts.title(24))
            Text("Saved to your own ~/.claude/skills — for you, in every project. Nothing is saved until you press Save.")
                .foregroundStyle(Tokens.textDim)
            if isWorking {
                Text("Claude is drafting it…").foregroundStyle(Tokens.textDim)
                Spacer()
            } else {
                HStack {
                    Text("Name").foregroundStyle(Tokens.textDim)
                    TextField("my-skill", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                    Text("→ /\(ClaudeLauncher.worktreeSlug(name))").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                }
                TextEditor(text: $text)
                    .font(Fonts.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 10))
            }
            if let error { Text(error).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button("Save") {
                    do {
                        _ = try store.saveSkill(named: name, text: text, for: suggestion)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PixelButtonStyle(isPrimary: true))
                .disabled(isWorking || ClaudeLauncher.worktreeSlug(name).isEmpty || text.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 680, height: 560)
        .paperSheet()
        .task {
            guard case let .skill(phrase) = suggestion.kind else { return }
            do {
                text = try await store.draftSkill(for: phrase)
                name = Automations.frontmatterValue("name", in: text) ?? ""
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
