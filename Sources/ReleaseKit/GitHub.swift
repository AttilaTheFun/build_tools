import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a request to GitHub sends and gets back; URLSession's in a job, a fake in the tests.
public protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: GitHubTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReleaseError("\(request.url?.absoluteString ?? "?"): no HTTP answer") }
        return (data, http)
    }
}

public struct ReleaseError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A release as the tools need it.
public struct Release: Sendable, Equatable {
    public let id: Int
    public let tag: String
    public let commit: String
    public let draft: Bool
    public let prerelease: Bool
}

/// GitHub's REST API for one repository, with the job's token (GH_TOKEN, else GITHUB_TOKEN): its releases, tags and
/// release assets. The token is only ever in a request's header.
public struct GitHub: Sendable {
    public let repository: String
    let token: String
    let api: URL
    let uploads: URL
    let transport: any GitHubTransport

    public init(repository: String, token: String, api: URL = URL(string: "https://api.github.com")!,
                uploads: URL = URL(string: "https://uploads.github.com")!, transport: any GitHubTransport = URLSessionTransport()) {
        self.repository = repository
        self.token = token
        self.api = api
        self.uploads = uploads
        self.transport = transport
    }

    /// The job's: GITHUB_REPOSITORY, GH_TOKEN (or GITHUB_TOKEN), GITHUB_API_URL.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> GitHub {
        guard let repository = environment["GITHUB_REPOSITORY"], !repository.isEmpty else { throw ReleaseError("GITHUB_REPOSITORY isn't set") }
        guard let token = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"], !token.isEmpty else {
            throw ReleaseError("GH_TOKEN isn't set: the job's token, with contents: write to draft or attach")
        }
        let api = environment["GITHUB_API_URL"].flatMap(URL.init(string:)) ?? URL(string: "https://api.github.com")!
        return GitHub(repository: repository, token: token, api: api)
    }

    public func releases() async throws -> [Release] {
        try await pages("repos/\(repository)/releases").compactMap { item in
            guard let id = item["id"] as? Int, let tag = item["tag_name"] as? String else { return nil }
            return Release(id: id, tag: tag, commit: item["target_commitish"] as? String ?? "",
                           draft: item["draft"] as? Bool ?? false, prerelease: item["prerelease"] as? Bool ?? false)
        }
    }

    public func tags() async throws -> [String] {
        try await pages("repos/\(repository)/tags").compactMap { $0["name"] as? String }
    }

    public func createRelease(tag: String, commit: String, name: String, prerelease: Bool, body: String) async throws {
        _ = try await json("POST", "repos/\(repository)/releases", ["tag_name": tag, "target_commitish": commit, "name": name,
                                                                    "draft": true, "prerelease": prerelease, "body": body])
    }

    public func updateRelease(id: Int, tag: String, commit: String, prerelease: Bool, body: String) async throws {
        _ = try await json("PATCH", "repos/\(repository)/releases/\(id)", ["tag_name": tag, "target_commitish": commit,
                                                                           "prerelease": prerelease, "body": body])
    }

    public func assets(release: Int) async throws -> [(id: Int, name: String)] {
        try await pages("repos/\(repository)/releases/\(release)/assets").compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return (id, name)
        }
    }

    public func deleteAsset(id: Int) async throws {
        _ = try await json("DELETE", "repos/\(repository)/releases/assets/\(id)", nil)
    }

    public func upload(release: Int, name: String, type: String, file: URL) async throws {
        var components = URLComponents(url: uploads.appendingPathComponent("repos/\(repository)/releases/\(release)/assets"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        var request = authorized(URLRequest(url: components.url!))
        request.httpMethod = "POST"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: file)
        request.timeoutInterval = 1800
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 201 else {
            throw ReleaseError("\(name) was not attached (\(response.statusCode)): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
    }

    // MARK: - Requests

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("build_tools-release", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func json(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> Any? {
        var request = authorized(URLRequest(url: api.appendingPathComponent(path)))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ReleaseError("\(method) \(path): \(response.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }

    /// Every page of a list, by its Link header's `next`.
    private func pages(_ path: String) async throws -> [[String: Any]] {
        var components = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        var next: URL? = components.url
        var items: [[String: Any]] = []
        while let url = next {
            let (data, response) = try await transport.send(authorized(URLRequest(url: url)))
            guard response.statusCode == 200 else {
                throw ReleaseError("GET \(path): \(response.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
            }
            guard let page = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ReleaseError("GET \(path): not a list")
            }
            items += page
            next = Self.nextPage(response.value(forHTTPHeaderField: "Link"))
        }
        return items
    }

    /// `<https://…?page=2>; rel="next", …`'s URL.
    static func nextPage(_ link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains("rel=\"next\""),
                  pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">") else { continue }
            return URL(string: String(pieces[0].dropFirst().dropLast()))
        }
        return nil
    }
}
