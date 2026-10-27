import Foundation
import FoundationModels
import NaturalLanguage
import os

/// What the model is asked: the last lines, and whose reply it suggests.
struct ReplyRequest: Sendable {
    var lines: [ChatLine]
    var me: String
    var conversation: String
    var isPrivate: Bool
}

/// A reply to suggest, from Apple Intelligence's model on this Mac: the
/// conversation never leaves it. Shown in the empty input field; Tab takes it.
///
/// The model answers one request at a time, from a queue: the conversation
/// in front first, then the private chats in the background. A background
/// request that has run too long while the one in front waits is stopped and
/// put back at the end; none runs longer than `hardLimit`.
@MainActor
final class ReplySuggester {
    static let shared = ReplySuggester()

    static let enabledKey = "ai.suggestReplies"
    static let backgroundKey = "ai.suggestInBackground"
    /// How many of the last messages the model reads.
    static let contextLines = 20

    var isEnabled: Bool { settings.bool(forKey: ReplySuggester.enabledKey, default: true) }
    var suggestsInBackground: Bool { isEnabled && settings.bool(forKey: ReplySuggester.backgroundKey, default: true) }

    /// Several lines often come at once: the last of them is answered.
    var settleDelay: Duration = .milliseconds(800)
    /// How long a background request may go on while the one in front waits.
    var interruptAfter: Duration = .seconds(2)
    var hardLimit: Duration = .seconds(10)
    /// The model; replaceable for tests.
    var generate: (ReplyRequest) async -> String?
    var isModelAvailable: () -> Bool

    private let settings: SettingsStore

    private struct Job {
        weak var buffer: ChatBuffer?
        weak var session: NetworkSession?
        /// The message it answers, by `key`.
        var line: String
        var foreground: Bool
        var readyAt: ContinuousClock.Instant
    }

    private var queue: [Job] = []
    private var running: (job: Job, task: Task<String?, Never>, started: ContinuousClock.Instant)?
    /// Set when the running request was stopped to make way: it goes back
    /// in the queue.
    private var requeueRunning = false
    private var worker: Task<Void, Never>?

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        generate = { request in await ReplySuggester.askModel(request) }
        isModelAvailable = { SystemLanguageModel.default.availability == .available }
    }

    // MARK: - The queue

    /// Asks for a reply to the conversation's newest message: `foreground`
    /// for the conversation in front, first in the queue; otherwise a
    /// private chat in the background, last.
    func request(for buffer: ChatBuffer, in session: NetworkSession, foreground: Bool) {
        let name = buffer.name
        guard foreground ? isEnabled : suggestsInBackground else {
            return AppLog.debug("suggestions", "\(name): off in Settings")
        }
        guard buffer.kind != .server, !session.isMemos(buffer) else { return }
        guard isModelAvailable() else {
            return AppLog.debug("suggestions", "\(name): \(unavailableReason ?? "the model is not available")")
        }
        guard let heard = ReplySuggester.lastHeard(in: buffer, session: session) else {
            return AppLog.debug("suggestions", "\(name): no message to answer")
        }
        guard !heard.isSelf else {
            buffer.suggestion = nil
            return AppLog.debug("suggestions", "\(name): the last message is your own")
        }
        let last = (id: ReplySuggester.key(heard), line: heard)
        guard buffer.draft.isEmpty else { return AppLog.debug("suggestions", "\(name): you are typing") }
        guard buffer.suggestionAnswers != last.id else {
            return AppLog.debug("suggestions", "\(name): already answered (\(last.id))")
        }
        AppLog.debug("suggestions", "\(name): queued \(foreground ? "first, in front" : "last, in the background") for \(last.id)")

        // Already being worked on: at most moved forward. For an older
        // message it goes on: in a busy channel, stopping it for every new
        // line would never let one finish. The newer one is asked after.
        if let current = running, current.job.buffer === buffer, current.job.line == last.id {
            if foreground { running?.job.foreground = true }
            return
        }
        // Waiting already: it keeps its time, so lines coming faster than
        // the settling delay do not put it off for ever.
        let waited = queue.first { $0.buffer === buffer }
        queue.removeAll { $0.buffer === buffer || $0.buffer == nil }
        // The suggestion shown stays until the new one replaces it: in a busy
        // channel, clearing it at every line would hardly ever show one.
        let job = Job(buffer: buffer, session: session, line: last.id, foreground: foreground,
                      readyAt: waited?.readyAt ?? .now + settleDelay)
        if foreground {
            queue.insert(job, at: 0)
        } else {
            queue.append(job)
        }
        if worker == nil {
            worker = Task { [weak self] in await self?.work() }
        }
    }

    /// Whether a request for the conversation is waiting or running.
    func isWorking(on buffer: ChatBuffer) -> Bool {
        running?.job.buffer === buffer || queue.contains { $0.buffer === buffer }
    }

    private func work() async {
        defer { worker = nil }
        while !queue.isEmpty {
            let now = ContinuousClock.now
            // The conversation in front first: while it settles, nothing else
            // is started.
            let front = queue.first { $0.foreground }
            let candidates = front.map { [$0] } ?? queue
            guard let ready = candidates.first(where: { $0.readyAt <= now }),
                  let index = queue.firstIndex(where: { $0.buffer === ready.buffer && $0.line == ready.line }) else {
                let next = candidates.map(\.readyAt).min() ?? now
                try? await Task.sleep(until: next)
                continue
            }
            let job = queue.remove(at: index)
            guard let buffer = job.buffer, let session = job.session else { continue }
            guard isStillWanted(job, buffer, session) else {
                AppLog.debug("suggestions", "\(buffer.name): dropped, no longer wanted (typing, answered, or a newer message)")
                continue
            }
            AppLog.info("suggestions", "\(buffer.name): asking the model (\(job.foreground ? "in front" : "background"), \(queue.count) waiting)")
            let request = ReplyRequest(lines: ReplySuggester.recentLines(of: buffer, in: session), me: session.nick,
                                       conversation: buffer.name, isPrivate: buffer.kind == .query)
            let generate = self.generate
            let task = Task { await generate(request) }
            running = (job, task, .now)
            requeueRunning = false
            let watchdog = Task { [weak self] in await self?.watch() }
            let suggestion = await task.value
            watchdog.cancel()
            let finished = running?.job ?? job
            let took = running.map { ContinuousClock.now - $0.started } ?? .zero
            let seconds = String(format: "%.1f s", Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)
            running = nil
            if task.isCancelled {
                AppLog.notice("suggestions", requeueRunning
                    ? "\(buffer.name): stopped after \(seconds) for the conversation in front; tried again later"
                    : "\(buffer.name): stopped after \(seconds)")
                if requeueRunning {
                    var again = finished
                    again.readyAt = .now
                    queue.append(again)
                }
                requeueRunning = false
                continue
            }
            // Shown even when a newer message came meanwhile: it is still a
            // reply to the conversation, and the newer one is asked next.
            guard buffer.draft.isEmpty, ReplySuggester.lastHeard(in: buffer, session: session)?.isSelf != true else {
                AppLog.debug("suggestions", "\(buffer.name): answer after \(seconds) not used: typing, or you wrote meanwhile")
                continue
            }
            AppLog.info("suggestions", suggestion == nil ? "\(buffer.name): no suggestion (\(seconds))"
                                                         : "\(buffer.name): suggestion ready in \(seconds)")
            buffer.suggestion = suggestion
            // Answered, with a reply or none: not asked again for this line.
            buffer.suggestionAnswers = finished.line
        }
    }

    /// Stops the running request when it takes too long: always after
    /// `hardLimit`, and when it is a background one and the conversation in
    /// front waits, after `interruptAfter` -- then it is tried again later.
    private func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            guard let current = running else { return }
            let elapsed = ContinuousClock.now - current.started
            if elapsed > hardLimit {
                AppLog.warning("suggestions", "\(current.job.buffer?.name ?? "?"): over the time limit, given up")
                requeueRunning = false
                current.job.buffer?.suggestionAnswers = current.job.line
                current.task.cancel()
                return
            }
            if !current.job.foreground, elapsed > interruptAfter,
               queue.contains(where: { $0.foreground && $0.readyAt <= .now }) {
                requeueRunning = true
                current.task.cancel()
                return
            }
        }
    }

    /// The conversation still has that message as its newest, and nothing
    /// typed.
    private func isStillWanted(_ job: Job, _ buffer: ChatBuffer, _ session: NetworkSession) -> Bool {
        buffer.draft.isEmpty && buffer.suggestionAnswers != job.line
            && ReplySuggester.lastHeard(in: buffer, session: session).map(ReplySuggester.key) == job.line
    }

    /// The newest message or action in the conversation, from anyone: from
    /// those that came since launch, or else from the log.
    static func lastHeard(in buffer: ChatBuffer, session: NetworkSession?) -> ChatLine? {
        func usable(_ line: ChatLine) -> Bool {
            (line.kind == .message || line.kind == .action) && !line.isIgnored
        }
        if let line = buffer.lines.last(where: usable) { return line }
        guard buffer.kind != .server, let log = session?.log, let session else { return nil }
        let scope = LogStore.Scope.buffer(network: session.id, key: LogStore.key(for: buffer.name, kind: buffer.kind))
        return log.lines(in: scope, limit: 30).last(where: usable)
    }

    /// What tells a line from another: its row in the log, which stays the
    /// same however often it is read back; else its ID.
    static func key(_ line: ChatLine) -> String {
        line.logID.map { "log:\($0)" } ?? line.id.uuidString
    }

    /// The last messages, from the log when fewer came since launch.
    static func recentLines(of buffer: ChatBuffer, in session: NetworkSession) -> [ChatLine] {
        let count = contextLines
        func usable(_ line: ChatLine) -> Bool {
            (line.kind == .message || line.kind == .action) && !line.isIgnored
        }
        let heard = Array(buffer.lines.filter(usable).suffix(count))
        guard heard.count < count, let log = session.log else { return heard }
        let scope = LogStore.Scope.buffer(network: session.id, key: LogStore.key(for: buffer.name, kind: buffer.kind))
        let logged = log.lines(in: scope, limit: count * 3).filter(usable).suffix(count)
        return logged.count > heard.count ? Array(logged) : heard
    }

    // MARK: - The model

    /// Why there are no suggestions on this Mac; nil when the model is there.
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac cannot run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off: turn it on in System Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready: its model is being downloaded."
        case .unavailable:
            return "Apple Intelligence is not available."
        }
    }

    /// A reply `me` could send next, in the conversation's language; nil when
    /// there is none, or the model declined. Stops when the task is cancelled.
    nonisolated static func askModel(_ request: ReplyRequest) async -> String? {
        do {
            return try await askModelThrowing(request)
        } catch is CancellationError {
            return nil
        } catch where isRefusal(error) && request.lines.count > retryLines {
            // One rough line minutes ago is enough to refuse the lot: once
            // more with the last few only.
            AppLog.notice("suggestions", "the model declined \(request.lines.count) lines; trying the last \(retryLines)")
            var shorter = request
            shorter.lines = Array(request.lines.suffix(retryLines))
            do {
                return try await askModelThrowing(shorter)
            } catch {
                AppLog.notice("suggestions", "no suggested reply: \(String(describing: error))")
                return nil
            }
        } catch where isRefusal(error) {
            AppLog.notice("suggestions", "no suggested reply: \(String(describing: error))")
            return nil
        } catch {
            // Declined by the model's guardrails, or the model went away.
            AppLog.error("suggestions", "the model gave no reply: \(String(describing: error))")
            return nil
        }
    }

    /// How many lines are tried again with when the model declines more.
    nonisolated static let retryLines = 4

    /// Apple's model on this Mac, with the guardrails meant for working with
    /// text the app was given, not written by the user: what IRC is. The
    /// default ones decline many an ordinary, rough conversation.
    nonisolated static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// The model declined: its guardrails, or a refusal of its own.
    nonisolated static func isRefusal(_ error: Error) -> Bool {
        switch error as? LanguageModelSession.GenerationError {
        case .guardrailViolation, .refusal: true
        default: false
        }
    }

    /// The model's answer, or why there is none.
    nonisolated static func askModelThrowing(_ request: ReplyRequest) async throws -> String? {
        let lines = request.lines, me = request.me, conversation = request.conversation
        guard !lines.isEmpty else { return nil }
        let place = request.isPrivate ? "a private chat with \(conversation)" : "the IRC channel \(conversation)"
        // Told outright: left to itself, the model answers in English.
        let language = ReplySuggester.language(of: lines.suffix(5).filter { !$0.isSelf })
        let instructions = """
            You help \(me) chat in \(place). Suggest one short reply that \(me) could send next, \
            answering the last messages. Write the reply in \(language). Write it as \(me) would: \
            casual and friendly, usually one sentence. Give only the reply itself: no quotes, \
            no nick in front, no explanation.
            """
        let transcript = lines.map(ReplySuggester.transcriptLine).joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(
            to: "The conversation so far, oldest first:\n\(transcript)\n\nThe reply \(me) sends next, in \(language):",
            options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 80))
        return ReplySuggester.cleaned(response.content, me: me)
    }

    /// The language the lines are written in, by name, as the model
    /// understands it; English when it cannot be told.
    nonisolated static func language(of lines: [ChatLine]) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.map { IRCFormatting.strip($0.text) }.joined(separator: "\n"))
        guard let code = recognizer.dominantLanguage?.rawValue else { return "English" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// One line as the model reads it: `<nick> text`, without formatting.
    nonisolated static func transcriptLine(_ line: ChatLine) -> String {
        let text = IRCFormatting.strip(line.text)
        let nick = line.sender ?? "?"
        return line.kind == .action ? "* \(nick) \(text)" : "<\(nick)> \(text)"
    }

    /// The model's answer as a line to send: the first line, without quotes
    /// or a nick in front, and not too long.
    nonisolated static func cleaned(_ answer: String, me: String) -> String? {
        var text = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        text = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["<\(me)>", "\(me):", "\(me) :"] where text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("„", "“")]
        for (open, close) in quotes where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        return String(text.prefix(400))
    }
}
