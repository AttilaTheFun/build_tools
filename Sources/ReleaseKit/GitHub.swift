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

/// A release's asset.
public struct Asset: Sendable, Equatable {
    public let id: Int
    public let name: String
}

/// GitHub's REST API for one repository, with the job's token (GH_TOKEN, else GITHUB_TOKEN): its releases, tags and
/// release assets. The token is only ever in a request's header.
///
/// GitHub has bad days (5xx, connections dropped): every call is tried up to `attempts` times, a while apart, and a
/// call that changes something is retried only once it's known not to have landed (p2prc#12 and #15: a delete that
/// landed before its 502, a rename that did).
public struct GitHub: Sendable {
    public let repository: String
    let token: String
    let api: URL
    let uploads: URL
    let transport: any GitHubTransport
    let attempts: Int
    /// The wait before attempt `n` (2, 3, …): 2, 4, 8, 16 s in a job; none in the tests.
    let pause: @Sendable (Int) async -> Void

    public init(repository: String, token: String, api: URL = URL(string: "https://api.github.com")!,
                uploads: URL = URL(string: "https://uploads.github.com")!, transport: any GitHubTransport = URLSessionTransport(),
                attempts: Int = 5, pause: @escaping @Sendable (Int) async -> Void = { try? await Task.sleep(for: .seconds(1 << ($0 - 1))) }) {
        self.repository = repository
        self.token = token
        self.api = api
        self.uploads = uploads
        self.transport = transport
        self.attempts = attempts
        self.pause = pause
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

    // MARK: - Releases and tags

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

    /// A draft `tag` made; a retry first looks for the draft an earlier attempt may have made, so there's never two.
    public func createRelease(tag: String, commit: String, name: String, prerelease: Bool, body: String) async throws {
        try await changing("POST releases (\(tag))", landed: {
            try await releases().contains { $0.draft && $0.tag == tag }
        }) {
            try await request("POST", "repos/\(repository)/releases", ["tag_name": tag, "target_commitish": commit, "name": name,
                                                                        "draft": true, "prerelease": prerelease, "body": body])
        }
    }

    /// The draft's fields set again (the same again on a retry). `tag_name` always sent: a PATCH without it untags a
    /// draft.
    public func updateRelease(id: Int, tag: String, commit: String, prerelease: Bool, body: String) async throws {
        try await changing("PATCH release \(id)", landed: { false }) {
            try await request("PATCH", "repos/\(repository)/releases/\(id)", ["tag_name": tag, "target_commitish": commit,
                                                                               "prerelease": prerelease, "body": body])
        }
    }

    // MARK: - Assets

    public func assets(release: Int) async throws -> [Asset] {
        try await pages("repos/\(repository)/releases/\(release)/assets").compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return Asset(id: id, name: name)
        }
    }

    /// One asset as it is now; nil once it's gone (404).
    public func asset(id: Int) async throws -> Asset? {
        try await retrying("GET asset \(id)") {
            let (data, response) = try await send("GET", "repos/\(repository)/releases/assets/\(id)", nil)
            if response.statusCode == 404 { return nil }
            try Self.check(response, data, "GET asset \(id)")
            guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = item["name"] as? String else {
                throw ReleaseError("GET asset \(id): not an asset")
            }
            return Asset(id: id, name: name)
        }
    }

    /// The asset deleted; a retry first asks whether it's gone already.
    public func deleteAsset(id: Int) async throws {
        try await changing("DELETE asset \(id)", landed: { try await asset(id: id) == nil }) {
            let (data, response) = try await send("DELETE", "repos/\(repository)/releases/assets/\(id)", nil)
            guard response.statusCode != 404 else { return }
            try Self.check(response, data, "DELETE asset \(id)")
        }
    }

    /// The asset renamed; a retry first asks whether it has the name already.
    public func renameAsset(id: Int, to name: String) async throws {
        try await changing("rename asset \(id) to \(name)", landed: { try await asset(id: id)?.name == name }) {
            try await request("PATCH", "repos/\(repository)/releases/assets/\(id)", ["name": name])
        }
    }

    /// A file uploaded as `name`, its new asset answered. A retry first deletes whatever half-made asset of that name
    /// an earlier attempt left.
    public func upload(release: Int, name: String, type: String, file: URL) async throws -> Asset {
        let data = try Data(contentsOf: file)
        var components = URLComponents(url: uploads.appendingPathComponent("repos/\(repository)/releases/\(release)/assets"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        var made: Asset?
        try await changing("upload \(name)", landed: {
            for leftover in try await assets(release: release) where leftover.name == name {
                try await deleteAsset(id: leftover.id)
            }
            return false
        }) {
            var request = authorized(URLRequest(url: components.url!))
            request.httpMethod = "POST"
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            request.timeoutInterval = 1800
            let (answer, response) = try await transport.send(request)
            guard response.statusCode == 201 else {
                throw HTTPFailure(status: response.statusCode, what: "\(name) was not attached (\(response.statusCode)): \(Self.excerpt(answer))")
            }
            guard let item = try JSONSerialization.jsonObject(with: answer) as? [String: Any], let id = item["id"] as? Int else {
                throw ReleaseError("\(name) was attached, but its answer named no asset")
            }
            made = Asset(id: id, name: item["name"] as? String ?? name)
        }
        return made!
    }

    // MARK: - Requests

    /// A failed attempt: GitHub's answer, or none (thrown by the transport).
    struct HTTPFailure: Error, CustomStringConvertible {
        let status: Int
        let what: String
        var description: String { what }
        var retryable: Bool { status >= 500 || status == 429 }
    }

    static func retryable(_ error: any Error) -> Bool {
        if let failure = error as? HTTPFailure { return failure.retryable }
        return !(error is ReleaseError)
    }

    /// A read, tried again on a 5xx or a dropped connection.
    private func retrying<T>(_ what: String, _ body: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch where Self.retryable(error) && attempt < attempts {
                attempt += 1
                FileHandle.standardError.write(Data("release: \(what): \(error); trying again (\(attempt) of \(attempts))\n".utf8))
                await pause(attempt)
            } catch let failure as HTTPFailure {
                throw ReleaseError(failure.what)
            }
        }
    }

    /// A change, tried again on a 5xx or a dropped connection once `landed` says the last attempt didn't land
    /// (true: it did, and it's done).
    private func changing(_ what: String, landed: () async throws -> Bool, _ body: () async throws -> Void) async throws {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch where Self.retryable(error) && attempt < attempts {
                attempt += 1
                FileHandle.standardError.write(Data("release: \(what): \(error); trying again (\(attempt) of \(attempts))\n".utf8))
                await pause(attempt)
                if try await landed() { return }
            } catch let failure as HTTPFailure {
                throw ReleaseError(failure.what)
            }
        }
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("build_tools-release", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> (Data, HTTPURLResponse) {
        var request = authorized(URLRequest(url: api.appendingPathComponent(path)))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await transport.send(request)
    }

    /// One request, a non-2xx thrown.
    private func request(_ method: String, _ path: String, _ body: [String: Any]?) async throws {
        let (data, response) = try await send(method, path, body)
        try Self.check(response, data, "\(method) \(path)")
    }

    private static func check(_ response: HTTPURLResponse, _ data: Data, _ what: String) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPFailure(status: response.statusCode, what: "\(what): \(response.statusCode): \(excerpt(data))")
        }
    }

    private static func excerpt(_ data: Data) -> String { String(decoding: data.prefix(300), as: UTF8.self) }

    /// Every page of a list, by its Link header's `next`.
    private func pages(_ path: String) async throws -> [[String: Any]] {
        var components = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        var next: URL? = components.url
        var items: [[String: Any]] = []
        while let url = next {
            let (page, link): ([[String: Any]], String?) = try await retrying("GET \(path)") {
                let (data, response) = try await transport.send(authorized(URLRequest(url: url)))
                try Self.check(response, data, "GET \(path)")
                guard let page = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw ReleaseError("GET \(path): not a list")
                }
                return (page, response.value(forHTTPHeaderField: "Link"))
            }
            items += page
            next = Self.nextPage(link)
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
