import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The GitHub REST calls proof-diff makes, with the job's token (GH_TOKEN, else GITHUB_TOKEN).
public struct GitHub: Sendable {
    public let api: String
    let token: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        api = environment["GITHUB_API_URL"] ?? "https://api.github.com"
        token = environment["GH_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } ?? environment["GITHUB_TOKEN"]
    }

    public struct Refused: Error, CustomStringConvertible {
        public let description: String
    }

    /// Redirects not followed: an asset's answer is a redirect to its storage, asked without the token.
    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            Self.session.dataTask(with: request) { data, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard let response = response as? HTTPURLResponse else {
                    return continuation.resume(throwing: Refused(description: "no HTTP answer"))
                }
                continuation.resume(returning: (data ?? Data(), response))
            }.resume()
        }
    }

    func request(_ url: String, method: String = "GET", accept: String = "application/vnd.github+json", body: Data? = nil,
                 contentType: String? = nil, timeout: TimeInterval = 120) throws -> URLRequest {
        guard let url = URL(string: url) else { throw Refused(description: "not a URL: \(url)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        return request
    }

    func json(_ path: String) async throws -> Any {
        let (data, response) = try await send(try request(api + path))
        guard (200..<300).contains(response.statusCode) else { throw Refused(description: "GitHub \(response.statusCode) for \(path)") }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// A repository's releases, every page (ten at most).
    public func releases(_ repository: String) async throws -> [[String: Any]] {
        var found: [[String: Any]] = []
        for page in 1...10 {
            let some = try await json("/repos/\(repository)/releases?per_page=100&page=\(page)") as? [[String: Any]] ?? []
            found += some
            if some.count < 100 { break }
        }
        return found
    }

    /// An asset's bytes: GitHub answers with a redirect to its storage, which is asked without the token.
    public func assetData(_ repository: String, asset: Int) async throws -> Data {
        let (data, response) = try await send(try request("\(api)/repos/\(repository)/releases/assets/\(asset)",
                                                         accept: "application/octet-stream", timeout: 300))
        if (200..<300).contains(response.statusCode) { return data }
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
            throw Refused(description: "GitHub \(response.statusCode) for asset \(asset)")
        }
        let (stored, storedResponse) = try await send(URLRequest(url: url, timeoutInterval: 300))
        guard (200..<300).contains(storedResponse.statusCode) else { throw Refused(description: "storage \(storedResponse.statusCode) for asset \(asset)") }
        return stored
    }

    /// A tag's commit; nil where GitHub can't say.
    public func commit(_ repository: String, tag: String) async -> String? {
        (try? await json("/repos/\(repository)/commits/\(tag)") as? [String: Any])?["sha"] as? String
    }

    /// A file attached to a release as the asset `name`.
    public func upload(_ data: Data, name: String, contentType: String, release: Int, in repository: String) async throws {
        let uploads = api == "https://api.github.com" ? "https://uploads.github.com" : api
        let (_, response) = try await send(try request("\(uploads)/repos/\(repository)/releases/\(release)/assets?name=\(name)", method: "POST",
                                                       body: data, contentType: contentType))
        guard (200..<300).contains(response.statusCode) else { throw Refused(description: "GitHub \(response.statusCode) attaching \(name)") }
    }
}
