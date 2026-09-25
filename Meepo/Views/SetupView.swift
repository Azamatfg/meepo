import SwiftUI

/// Claude Code Setup: what in ~/.claude quietly works against the user, each with a fix and an undo.
struct SetupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var findings: [SetupCheck.Finding] = []
    @State private var fixed: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Code Setup").font(Fonts.title(24))
                if let version = store.claudeVersion { Text(version).font(Fonts.mono(12)).foregroundStyle(Tokens.textDim) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            Text("Checks your own ~/.claude — settings, hooks, permissions, skills. Every fix is backed up and can be undone here or in Tools → Changes. Project files under git are the team's and aren't touched.")
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(Tokens.danger) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if findings.isEmpty {
                        Text("Nothing to fix.").font(Fonts.ui(18, weight: .semibold)).padding(.top, 20)
                    }
                    ForEach(findings) { finding in row(finding) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: 640, height: 560)
        .paperSheet()
        .onAppear { findings = store.setupFindings() }
    }

    private func row(_ finding: SetupCheck.Finding) -> some View {
        let isFixed = fixed.contains(finding.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SelectionRing(kind: isFixed ? .working : .sync, size: 9).padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.title).font(Fonts.ui(16, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    Text(finding.detail).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isFixed {
                    Text("Fixed").foregroundStyle(Tokens.work)
                    Button("Undo") { set(finding, false) }.buttonStyle(PixelButtonStyle(compact: true))
                } else {
                    Button(finding.fixTitle) { set(finding, true) }.buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                }
            }
        }
        .padding(14)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
    }

    private func set(_ finding: SetupCheck.Finding, _ applied: Bool) {
        do {
            try store.setSetupFix(finding, applied: applied)
            if applied { fixed.insert(finding.id) } else { fixed.remove(finding.id) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
