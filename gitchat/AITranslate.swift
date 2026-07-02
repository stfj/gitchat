import Foundation

// Translates a pull request into plain non-engineer language using an LLM.
// Provider + key configured in Settings (stored 0600 alongside the GitHub
// token). Anthropic is the default; OpenAI supported as an alternative.

struct AIConfig: Codable {
    var provider: String = "anthropic"   // "anthropic" | "openai"
    var model: String = ""               // empty → provider default
    var key: String = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "anthropic"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
    }

    var resolvedModel: String {
        let m = model.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? AITranslator.defaultModel(provider: provider) : m
    }
}

enum TranslateError: LocalizedError {
    case needsKey
    case badResponse(String)
    case http(Int, String)
    case refused

    var errorDescription: String? {
        switch self {
        case .needsKey:
            "Add an API key in Settings → AI translation first."
        case .badResponse(let detail):
            "The AI provider returned something unexpected (\(detail))."
        case .http(let code, let message):
            "AI request failed (HTTP \(code)): \(message)"
        case .refused:
            "The model declined to summarize this PR."
        }
    }
}

@MainActor
final class AITranslator {
    static let shared = AITranslator()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 180   // reasoning models can take a while
        return URLSession(configuration: cfg)
    }()

    nonisolated static func defaultModel(provider: String) -> String {
        provider == "openai" ? "gpt-5.1" : "claude-opus-4-8"
    }

    func translate(prompt: String, config: AIConfig) async throws -> String {
        let key = config.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslateError.needsKey }
        if config.provider == "openai" {
            return try await callOpenAI(prompt: prompt, model: config.resolvedModel, key: key)
        }
        return try await callAnthropic(prompt: prompt, model: config.resolvedModel, key: key)
    }

    // MARK: Anthropic Messages API

    private func callAnthropic(prompt: String, model: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // No temperature/top_p — removed on current Claude models (400 if sent).
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 8000,
            "messages": [["role": "user", "content": prompt]],
        ])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.badResponse("non-HTTP response")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let message = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw TranslateError.http(http.statusCode, message)
        }
        if let stop = obj?["stop_reason"] as? String, stop == "refusal" {
            throw TranslateError.refused
        }
        guard let content = obj?["content"] as? [[String: Any]] else {
            throw TranslateError.badResponse("missing content")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        guard !text.isEmpty else { throw TranslateError.badResponse("empty answer") }
        return text
    }

    // MARK: OpenAI Chat Completions

    private func callOpenAI(prompt: String, model: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.badResponse("non-HTTP response")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let message = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw TranslateError.http(http.statusCode, message)
        }
        guard let choices = obj?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            throw TranslateError.badResponse("missing choices")
        }
        return text
    }

    // MARK: Prompt

    nonisolated static func buildPrompt(chat: Chat, body: String, files: [GHPullFile]) -> String {
        var parts: [String] = []
        parts.append("""
        You are helping a non-engineer teammate understand a GitHub pull request. \
        Translate it into plain, friendly English — no jargon; if a technical term \
        is unavoidable, explain it in a short parenthetical.

        Structure the answer as:
        1. **What changed** — one or two sentences in plain language.
        2. **Why it matters** — what a user or teammate would actually notice or care about.
        3. **Anything to watch** — risks or behavior changes, or "nothing notable" if routine.

        Keep it under 250 words total.
        """)
        parts.append("PR title: \(chat.title)\nRepo: \(chat.repoFullName) #\(chat.number)\nAuthor: \(chat.author.login)")
        if !body.isEmpty {
            parts.append("PR description:\n\(String(body.prefix(4000)))")
        }

        let shown = files.prefix(60)
        let totalAdditions = files.compactMap(\.additions).reduce(0, +)
        let totalDeletions = files.compactMap(\.deletions).reduce(0, +)
        parts.append("Changed files: \(files.count) (+\(totalAdditions)/−\(totalDeletions))"
            + (files.count > 60 ? " — showing the first 60" : ""))

        var patchBudget = 14_000
        for file in shown {
            var entry = "--- \(file.filename) (\(file.status ?? "modified"), +\(file.additions ?? 0)/−\(file.deletions ?? 0))"
            if patchBudget > 200, let patch = file.patch, !patch.isEmpty {
                let excerpt = String(patch.prefix(min(1200, patchBudget)))
                entry += "\n\(excerpt)"
                patchBudget -= excerpt.count
            }
            parts.append(entry)
        }
        return parts.joined(separator: "\n\n")
    }
}
