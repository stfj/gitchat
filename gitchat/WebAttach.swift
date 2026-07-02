import SwiftUI
import WebKit

// Uploads images to GitHub's own attachment host (github.com/user-attachments),
// the same place the web UI puts drag-and-dropped images, so attachments
// inherit the repository's visibility (private repos → private attachments).
//
// There is no token API for this host; it only works with a signed-in web
// session. The user signs in once in an in-app WebKit sheet; cookies persist
// in the app's own WKWebsiteDataStore. The flow mirrors github.com's uploader:
//   1. GET  /{repo}/issues/new                → CSRF token, fetch-nonce
//   2. POST /upload/policies/assets           → S3 policy + asset URLs
//   3. POST <s3 upload_url> (multipart+file)
//   4. PUT  <asset_upload_url>                → finalized asset href

enum AttachmentError: LocalizedError {
    case needsWebLogin
    case needsRepo
    case sessionRejected(Int)
    case protocolChanged(String)

    var errorDescription: String? {
        switch self {
        case .needsWebLogin:
            "Uploading private attachments needs a one-time GitHub sign-in — use the sheet that just opened, then attach the image again."
        case .needsRepo:
            "Choose a repository before attaching images."
        case .sessionRejected(let code):
            "GitHub rejected the upload session (HTTP \(code)). Sign in again from Settings → Attachments."
        case .protocolChanged(let detail):
            "GitHub's upload flow looks different than expected (\(detail)). You can switch Settings → Attachments to the public-repo fallback."
        }
    }
}

// MARK: - Web session (cookies from the in-app sign-in)

@MainActor
final class WebSession {
    static let shared = WebSession()

    // One consistent UA for both the login web view and the uploader requests.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private var store: WKHTTPCookieStore {
        WKWebsiteDataStore.default().httpCookieStore
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
    }

    /// "name=value; …" for github.com, or nil when there's no signed-in session.
    func cookieHeader() async -> String? {
        let gh = await allCookies().filter { $0.domain.hasSuffix("github.com") }
        guard gh.contains(where: { $0.name == "user_session" && !$0.value.isEmpty }) else { return nil }
        return gh.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func hasSession() async -> Bool {
        await cookieHeader() != nil
    }

    /// Keep the session fresh: fold any Set-Cookie from upload responses back
    /// into the WebKit store.
    func absorb(response: HTTPURLResponse, requestURL: URL) {
        guard let fields = response.allHeaderFields as? [String: String] else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: requestURL)
        for cookie in cookies { store.setCookie(cookie) }
    }

    func signOut() async {
        for cookie in await allCookies() where cookie.domain.hasSuffix("github.com") {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { cont.resume() }
            }
        }
    }
}

// MARK: - Uploader

@MainActor
final class UserAttachmentUploader {
    static let shared = UserAttachmentUploader()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg)
    }()

    private struct Policies: Decodable {
        var uploadURL: String
        var uploadAuthenticityToken: String?
        var form: [String: String]?
        var header: [String: String]?
        var asset: AssetInfo?
        var assetUploadURL: String?
        var assetUploadAuthenticityToken: String?
        var sameOrigin: Bool?

        enum CodingKeys: String, CodingKey {
            case uploadURL = "upload_url"
            case uploadAuthenticityToken = "upload_authenticity_token"
            case form, header, asset
            case assetUploadURL = "asset_upload_url"
            case assetUploadAuthenticityToken = "asset_upload_authenticity_token"
            case sameOrigin = "same_origin"
        }
    }

    private struct AssetInfo: Decodable {
        var href: String?
    }

    func upload(data: Data, fileName: String, contentType: String,
                repoFullName: String, repositoryID: Int, cookieHeader: String) async throws -> String {
        // 1. Referer page → CSRF token + nonce.
        let referer = try await fetchRefererPage(repoFullName: repoFullName, cookieHeader: cookieHeader)
        guard let csrf = referer.authenticityToken else {
            throw AttachmentError.protocolChanged("no CSRF token on \(referer.url.path)")
        }

        // 2. Upload policy.
        let boundary1 = "gitchat-\(UUID().uuidString)"
        var policyReq = URLRequest(url: URL(string: "https://github.com/upload/policies/assets")!)
        policyReq.httpMethod = "POST"
        policyReq.httpBody = Self.multipartBody(fields: [
            ("repository_id", String(repositoryID)),
            ("name", fileName),
            ("size", String(data.count)),
            ("content_type", contentType),
            ("authenticity_token", csrf),
        ], file: nil, boundary: boundary1)
        policyReq.setValue("multipart/form-data; boundary=\(boundary1)", forHTTPHeaderField: "Content-Type")
        policyReq.setValue("application/json", forHTTPHeaderField: "Accept")
        policyReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        policyReq.setValue("true", forHTTPHeaderField: "GitHub-Verified-Fetch")
        if let nonce = referer.fetchNonce { policyReq.setValue(nonce, forHTTPHeaderField: "X-Fetch-Nonce") }
        if let version = referer.clientVersion { policyReq.setValue(version, forHTTPHeaderField: "X-GitHub-Client-Version") }
        policyReq.setValue("https://github.com", forHTTPHeaderField: "Origin")
        policyReq.setValue(referer.url.absoluteString, forHTTPHeaderField: "Referer")
        policyReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        policyReq.setValue(WebSession.userAgent, forHTTPHeaderField: "User-Agent")

        let (policyData, policyResp) = try await send(policyReq)
        guard (200..<300).contains(policyResp.statusCode) else {
            if policyResp.statusCode == 401 || policyResp.statusCode == 403 || policyResp.statusCode == 404 {
                throw AttachmentError.sessionRejected(policyResp.statusCode)
            }
            throw AttachmentError.protocolChanged("policies returned \(policyResp.statusCode)")
        }
        let policies: Policies
        do {
            policies = try JSONDecoder().decode(Policies.self, from: policyData)
        } catch {
            throw AttachmentError.protocolChanged("unreadable policies response")
        }

        // 3. Binary upload (usually S3; occasionally same-origin).
        guard let uploadURL = URL(string: policies.uploadURL) else {
            throw AttachmentError.protocolChanged("bad upload_url")
        }
        let boundary2 = "gitchat-\(UUID().uuidString)"
        var binReq = URLRequest(url: uploadURL)
        binReq.httpMethod = "POST"
        binReq.httpBody = Self.multipartBody(
            fields: (policies.form ?? [:]).map { ($0.key, $0.value) },
            file: (field: "file", name: fileName, contentType: contentType, data: data),
            boundary: boundary2
        )
        binReq.setValue("multipart/form-data; boundary=\(boundary2)", forHTTPHeaderField: "Content-Type")
        binReq.setValue(contentType, forHTTPHeaderField: "X-File-Content-Type")
        for (key, value) in policies.header ?? [:] { binReq.setValue(value, forHTTPHeaderField: key) }
        if policies.sameOrigin == true, let token = policies.uploadAuthenticityToken {
            binReq.setValue(token, forHTTPHeaderField: "authenticity_token")
        }
        binReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        binReq.setValue(WebSession.userAgent, forHTTPHeaderField: "User-Agent")

        let (_, binResp) = try await send(binReq)
        guard (200..<300).contains(binResp.statusCode) else {
            throw AttachmentError.protocolChanged("binary upload returned \(binResp.statusCode)")
        }

        // 4. Finalize.
        var href = policies.asset?.href
        if let finalize = policies.assetUploadURL {
            let finalURL = finalize.hasPrefix("/") ? "https://github.com" + finalize : finalize
            if let url = URL(string: finalURL) {
                let boundary3 = "gitchat-\(UUID().uuidString)"
                var finReq = URLRequest(url: url)
                finReq.httpMethod = "PUT"
                finReq.httpBody = Self.multipartBody(fields: [
                    ("authenticity_token", policies.assetUploadAuthenticityToken ?? ""),
                ], file: nil, boundary: boundary3)
                finReq.setValue("multipart/form-data; boundary=\(boundary3)", forHTTPHeaderField: "Content-Type")
                finReq.setValue("application/json", forHTTPHeaderField: "Accept")
                finReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                finReq.setValue("https://github.com", forHTTPHeaderField: "Origin")
                finReq.setValue("https://github.com/", forHTTPHeaderField: "Referer")
                finReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                finReq.setValue(WebSession.userAgent, forHTTPHeaderField: "User-Agent")

                let (finData, finResp) = try await send(finReq)
                if (200..<300).contains(finResp.statusCode),
                   let finalized = try? JSONDecoder().decode(AssetInfo.self, from: finData),
                   let finalHref = finalized.href, !finalHref.isEmpty {
                    href = finalHref
                }
            }
        }

        guard var result = href, !result.isEmpty else {
            throw AttachmentError.protocolChanged("upload finished but no asset URL returned")
        }
        if result.hasPrefix("/") { result = "https://github.com" + result }
        return result
    }

    private struct RefererPage {
        var url: URL
        var authenticityToken: String?
        var fetchNonce: String?
        var clientVersion: String?
    }

    private func fetchRefererPage(repoFullName: String, cookieHeader: String) async throws -> RefererPage {
        let candidates = [
            "https://github.com/\(repoFullName)/issues/new",
            "https://github.com/\(repoFullName)",
        ]
        var lastStatus = 0
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var req = URLRequest(url: url)
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue(WebSession.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://github.com", forHTTPHeaderField: "Origin")
            req.setValue(candidate, forHTTPHeaderField: "Referer")
            let (data, resp) = try await send(req)
            lastStatus = resp.statusCode
            guard resp.statusCode == 200, let html = String(data: data, encoding: .utf8) else { continue }
            let page = RefererPage(
                url: resp.url ?? url,
                authenticityToken: Self.firstMatch("name=[\"']authenticity_token[\"'][^>]*value=[\"']([^\"']+)[\"']", in: html)
                    ?? Self.firstMatch("<meta[^>]*name=[\"']csrf-token[\"'][^>]*content=[\"']([^\"']+)[\"']", in: html),
                fetchNonce: Self.firstMatch("<meta[^>]*name=[\"']fetch-nonce[\"'][^>]*content=[\"']([^\"']+)[\"']", in: html),
                clientVersion: Self.firstMatch("<meta[^>]*name=[\"']release[\"'][^>]*content=[\"']([^\"']+)[\"']", in: html)
            )
            if page.authenticityToken != nil { return page }
        }
        if lastStatus == 404 || lastStatus == 401 {
            throw AttachmentError.sessionRejected(lastStatus)
        }
        throw AttachmentError.protocolChanged("couldn't load an upload page (HTTP \(lastStatus))")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AttachmentError.protocolChanged("non-HTTP response")
        }
        if let url = request.url {
            WebSession.shared.absorb(response: http, requestURL: url)
        }
        return (data, http)
    }

    nonisolated static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    nonisolated static func multipartBody(fields: [(String, String)],
                                          file: (field: String, name: String, contentType: String, data: Data)?,
                                          boundary: String) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }
        if let file {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\r\n")
            append("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    nonisolated static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "webp": "image/webp"
        case "tiff", "tif": "image/tiff"
        case "bmp": "image/bmp"
        default: "application/octet-stream"
        }
    }
}

// MARK: - In-app GitHub sign-in sheet

struct GitHubLoginSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to GitHub")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            WebLoginView {
                app.webSessionActive = true
                dismiss()
            }
            .frame(width: 480, height: 600)
            Divider()
            Text("One-time sign-in so gitchat can upload images to GitHub's own attachment storage — attachments stay as private as the repo they're posted to. The session lives only in this app on this Mac.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(10)
        }
    }
}

struct WebLoginView: NSViewRepresentable {
    var onAuthenticated: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = WebSession.userAgent
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://github.com/login")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onAuthenticated: () -> Void
        private var finished = false

        init(onAuthenticated: @escaping () -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                guard !self.finished else { return }
                if await WebSession.shared.hasSession() {
                    self.finished = true
                    self.onAuthenticated()
                }
            }
        }
    }
}
