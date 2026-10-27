import SwiftUI

/// The automatic replies: switched on or off, where they answer, and the
/// rules -- a regular expression, and the answers to pick from.
struct AutoReplyEditor: View {
    static let windowID = "autoReplies"

    private let settings = SettingsStore.shared
    @State private var rules: [AutoReplyRule] = []
    @State private var trial = ""

    private var startMessages: Binding<Int> {
        Binding(get: { AutoReplier.shared.startMessages },
                set: { settings.set($0, forKey: AutoReplier.startMessagesKey) })
    }

    private var scope: Binding<AutoReplyScope> {
        Binding(get: { AutoReplier.shared.scope }, set: { settings.set($0.rawValue, forKey: AutoReplier.scopeKey) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Reply automatically", isOn: settings.binding(AutoReplier.enabledKey, default: false))
                .toggleStyle(.switch)
                .font(.headline)
            Picker("Answer in", selection: scope) {
                ForEach(AutoReplyScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Picker("In a private chat", selection: startMessages) {
                ForEach([1, 2, 3, 4, 6, 10], id: \.self) { count in
                    Text(count == 1 ? "only its first message" : "only in its first \(count) messages").tag(count)
                }
                Text("every message").tag(0)
            }
            .fixedSize()
            .help("Messages from both sides count. After 30 minutes of silence, a private chat starts over as a new conversation.")
            Text("A line from someone else that matches a pattern, ignoring case, is answered with one of its replies, picked at random, after a second or two. {nick} is who wrote, {me} your nick. The first matching rule answers; each person at most once per rule in ten minutes, and never a notice, an action or an ignored nick. In a private chat, only the start of a conversation is answered, as set above: once you are talking, it is left to you. After 30 minutes of silence, a conversation starts over.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($rules) { $rule in
                        RuleEditor(rule: $rule) { rules.removeAll { $0.id == rule.id } }
                    }
                }
            }

            HStack {
                Button {
                    rules.append(AutoReplyRule(pattern: "", replies: []))
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                Button("Restore Samples") { rules = AutoReplier.samples }
                    .help("The list Irctell came with")
                Spacer()
            }

            Divider()
            HStack {
                SearchField(prompt: "Try a line, as someone would write it", text: $trial)
                if !trial.isEmpty {
                    Text(trialResult)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 680)
        .onAppear { rules = AutoReplier.shared.rules }
        .onChange(of: rules) { AutoReplier.shared.rules = rules }
    }

    private var trialResult: String {
        guard let rule = AutoReplier.shared.rule(matching: trial) else { return "No rule answers that." }
        let number = (rules.firstIndex { $0.id == rule.id } ?? 0) + 1
        return "Rule \(number) answers, e.g. “\(rule.replies.first ?? "")”"
    }
}

/// One rule: on or off, its pattern, and its replies, one a line.
private struct RuleEditor: View {
    @Binding var rule: AutoReplyRule
    let remove: () -> Void
    @State private var replies = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $rule.isEnabled)
                    .labelsHidden()
                    .help("Use this rule")
                TextField("Regular expression", text: $rule.pattern)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this rule")
            }
            if !rule.pattern.isEmpty, let error = AutoReplier.error(in: rule.pattern) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Replies, one a line")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $replies)
                .font(.body)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .background(.background, in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .onChange(of: replies) { rule.replies = lines(replies) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .opacity(rule.isEnabled ? 1 : 0.6)
        .onAppear { replies = rule.replies.joined(separator: "\n") }
        // Restore Samples changes the rule under the editor.
        .onChange(of: rule.replies) {
            if lines(replies) != rule.replies { replies = rule.replies.joined(separator: "\n") }
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
