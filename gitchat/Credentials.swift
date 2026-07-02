import Foundation

struct Credentials: Codable {
    var token: String
    var login: String
    var baseURL: String
}

/// Token storage: a 0600 file in Application Support (same trust model as the
/// gh CLI's config). Ad-hoc/dev signing makes Keychain ACLs painful across
/// rebuilds, so a locked-down file is the pragmatic choice for a personal app.
enum CredentialsVault {
    nonisolated static var fileURL: URL {
        Store.baseDir.appendingPathComponent("credentials.json")
    }

    nonisolated static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    nonisolated static func save(_ c: Credentials) {
        try? FileManager.default.createDirectory(at: Store.baseDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    nonisolated static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: gh CLI integration

    nonisolated static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", "/opt/local/bin/gh"]

    nonisolated static var ghInstalled: Bool {
        ghPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocking; call off the main actor.
    nonisolated static func detectGhToken() -> String? {
        guard let gh = ghPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "token"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let tok = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tok.isEmpty ? nil : tok
    }
}
