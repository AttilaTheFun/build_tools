import Foundation

/// What `sign apple` adds to the outer app just before it signs it (Isomer, 2026-11-27): Info.plist keys, app groups
/// and keychain groups, the values a build used to bake in from secrets, stamped by the signing job instead (which
/// holds them), so the build itself needs none. Only the outer app's: its extensions and other code keep theirs.
/// Nothing of their values is ever printed (they come from secrets).
public struct AppleAdditions: Sendable, Equatable {
    /// An Info.plist value added: a string, or an array of strings.
    public enum Value: Sendable, Equatable {
        case string(String)
        case strings([String])

        var plist: Any {
            switch self {
            case .string(let text): text
            case .strings(let texts): texts
            }
        }

        /// Whether a value already in the Info.plist is this one.
        func equals(_ present: Any) -> Bool {
            switch self {
            case .string(let text): (present as? String) == text
            case .strings(let texts): (present as? [String]) == texts
            }
        }
    }

    /// Keys merged into the outer app's Info.plist; one already there with another value is refused.
    public var infoPlist: [String: Value]
    /// Appended, each once, to `com.apple.security.application-groups` (made where there's none).
    public var appGroups: [String]
    /// Appended last, each once, to `keychain-access-groups`, after the app's own (the first stays where the app saves
    /// without naming a group); where it has none, `<TEAM>.<bundle id>` first, TEAM the added group's own prefix.
    public var keychainGroups: [String]

    public static let none = AppleAdditions()

    public var isEmpty: Bool { infoPlist.isEmpty && appGroups.isEmpty && keychainGroups.isEmpty }

    /// Written in a value, the app's App ID prefix and its dot (`TEAM.`), filled from each top-level app's chosen
    /// profile (#21), as Xcode fills it: so a signing job needs no team of its own to spell a group.
    public static let prefixPlaceholder = "$(AppIdentifierPrefix)"

    /// The Info.plist keys `sign apple` sets itself, which `--add-infoplist` may not (Manager's review of #20).
    public static let ownKeys: Set<String> = ["BuildVariant"]

    /// Refused, saying why (by its place, never its value), for a group that isn't one: an app group empty or with a
    /// space or a slash, or a keychain group without its team's ten-character prefix; or for an Info.plist key
    /// `sign apple` sets itself (`ownKeys`).
    public init(infoPlist: [String: Value] = [:], appGroups: [String] = [], keychainGroups: [String] = []) throws {
        for (index, group) in appGroups.enumerated() where group.isEmpty || group.contains(where: { $0.isWhitespace || $0 == "/" }) {
            throw SignError("--add-groups' app group number \(index + 1) isn't an app group")
        }
        for (index, group) in keychainGroups.enumerated() where Self.team(of: Self.placeholderFilled(group, prefix: "ABCDEFGHIJ")) == nil {
            throw SignError("--add-groups' keychain group number \(index + 1) isn't <TEAM>.<group>, TEAM its team's ten capital letters and digits")
        }
        for key in infoPlist.keys.sorted() where Self.ownKeys.contains(key) {
            throw SignError("--add-infoplist may not set \(key): sign apple sets it (--variant)")
        }
        self.infoPlist = infoPlist
        self.appGroups = appGroups
        self.keychainGroups = keychainGroups
    }

    private init() {
        infoPlist = [:]
        appGroups = []
        keychainGroups = []
    }

    /// The Info.plist keys of `--add-infoplist`'s file: a JSON object whose values are strings or arrays of strings,
    /// each key once. Refused naming the key, never its value.
    public static func infoPlist(json data: Data) throws -> [String: Value] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SignError("--add-infoplist's file isn't a JSON object")
        }
        if let twice = repeatedKey(data) { throw SignError("--add-infoplist's file has \(twice) more than once") }
        var values: [String: Value] = [:]
        for (key, value) in object {
            if let text = value as? String {
                values[key] = .string(text)
            } else if let list = value as? [Any], let texts = list as? [String], texts.count == list.count {
                values[key] = .strings(texts)
            } else {
                throw SignError("--add-infoplist's \(key) is neither a string nor an array of strings")
            }
        }
        return values
    }

    /// The groups of `--add-groups`' file (Manager's review of #20: no group on the command line, where another process
    /// or a step echoing it sees it): a JSON object, `{"app": [...], "keychain": [...]}`, each an array of strings,
    /// either left out. Anything else refused, never saying a value.
    public static func groups(json data: Data) throws -> (app: [String], keychain: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SignError("--add-groups' file isn't a JSON object")
        }
        if let twice = repeatedKey(data) { throw SignError("--add-groups' file has \(twice) more than once") }
        if let stray = object.keys.sorted().first(where: { $0 != "app" && $0 != "keychain" }) {
            throw SignError("--add-groups' file has \(stray): only app and keychain")
        }
        func list(_ key: String) throws -> [String] {
            guard let value = object[key] else { return [] }
            guard let items = value as? [Any], let texts = items as? [String], texts.count == items.count else {
                throw SignError("--add-groups' \(key) isn't an array of strings")
            }
            return texts
        }
        return (try list("app"), try list("keychain"))
    }

    /// The first key a JSON object (already read as one) has twice at its top level, or nil: JSONSerialization keeps
    /// the last of the two, silently. Its keys found by walking its text, strings and nesting kept track of.
    static func repeatedKey(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var seen = Set<String>()
        var depth = 0, index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                // A string: to its closing quote, past escapes.
                var end = index + 1
                while end < bytes.count, bytes[end] != UInt8(ascii: "\"") { end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1 }
                // A key of the top object: a string at depth 1 followed by a colon.
                var after = end + 1
                while after < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[after]) { after += 1 }
                if depth == 1, after < bytes.count, bytes[after] == UInt8(ascii: ":"), end < bytes.count,
                   let key = try? JSONDecoder().decode(String.self, from: Data(bytes[index...end])) {
                    if !seen.insert(key).inserted { return key }
                }
                index = end + 1
                continue
            }
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
            if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") { depth -= 1 }
            index += 1
        }
        return nil
    }

    /// Whether a value anywhere uses `$(AppIdentifierPrefix)`.
    public var usesPrefix: Bool {
        let values = appGroups + keychainGroups + infoPlist.values.flatMap { value -> [String] in
            switch value {
            case .string(let text): [text]
            case .strings(let texts): texts
            }
        }
        return values.contains { $0.contains(Self.prefixPlaceholder) }
    }

    /// `text` with `$(AppIdentifierPrefix)` made `<prefix>.`.
    static func placeholderFilled(_ text: String, prefix: String) -> String {
        text.replacingOccurrences(of: prefixPlaceholder, with: prefix + ".")
    }

    /// These additions for one top-level app: `$(AppIdentifierPrefix)` filled with its chosen profile's prefix (#21).
    /// Refused where a value uses it and the app has no profile to take it from (a Mac app signed without one).
    func filled(prefix: String?) throws -> AppleAdditions {
        guard usesPrefix else { return self }
        guard let prefix else {
            throw SignError("--add-groups or --add-infoplist uses \(Self.prefixPlaceholder), but the app has no provisioning profile to "
                            + "take its prefix from")
        }
        let info = infoPlist.mapValues { value -> Value in
            switch value {
            case .string(let text): .string(Self.placeholderFilled(text, prefix: prefix))
            case .strings(let texts): .strings(texts.map { Self.placeholderFilled($0, prefix: prefix) })
            }
        }
        return try AppleAdditions(infoPlist: info, appGroups: appGroups.map { Self.placeholderFilled($0, prefix: prefix) },
                                  keychainGroups: keychainGroups.map { Self.placeholderFilled($0, prefix: prefix) })
    }

    /// A keychain group's team: its prefix, ten capital letters or digits, before a dot and more.
    static func team(of group: String) -> String? {
        let parts = group.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10, !parts[1].isEmpty,
              parts[0].allSatisfy({ ($0.isLetter && $0.isUppercase) || $0.isNumber }) else { return nil }
        return String(parts[0])
    }

    /// `info` with the keys added; one already there with another value refused (by its name alone).
    func merged(into info: [String: Any]) throws -> [String: Any] {
        var info = info
        for (key, value) in infoPlist.sorted(by: { $0.key < $1.key }) {
            if let present = info[key] {
                guard value.equals(present) else { throw SignError("the Info.plist already has \(key), with another value") }
                continue
            }
            info[key] = value.plist
        }
        return info
    }

    /// `entitlements` with the groups added, for `bundle`, the outer app. `prefix`: its profile's App ID prefix, for
    /// its own keychain group where it has none (Manager's review of #20), else the added group's team.
    func applied(to entitlements: [String: Any], bundle: String, prefix: String? = nil) -> [String: Any] {
        var result = entitlements
        if !appGroups.isEmpty {
            var groups = result["com.apple.security.application-groups"] as? [String] ?? []
            for group in appGroups where !groups.contains(group) { groups.append(group) }
            result["com.apple.security.application-groups"] = groups
        }
        if let first = keychainGroups.first, let team = prefix ?? Self.team(of: first) {
            var groups = result["keychain-access-groups"] as? [String] ?? []
            // None of its own: the app's own group first, where it saves without naming one, as Xcode makes it.
            if groups.isEmpty { groups = ["\(team).\(bundle)"] }
            for group in keychainGroups where !groups.contains(group) { groups.append(group) }
            result["keychain-access-groups"] = groups
        }
        return result
    }

    /// Why a profile refuses the groups added (how many of each, never which), or nil: each must be one its
    /// entitlements list, or match one of its wildcards (`TEAM.*`).
    func refusal(allowed: [String: Any]) -> String? {
        func permits(_ key: String, _ group: String) -> Bool {
            (allowed[key] as? [String] ?? []).contains { pattern in
                pattern == group || (pattern.hasSuffix("*") && group.hasPrefix(String(pattern.dropLast())))
            }
        }
        let apps = appGroups.filter { !permits("com.apple.security.application-groups", $0) }.count
        let keychains = keychainGroups.filter { !permits("keychain-access-groups", $0) }.count
        let said = (apps > 0 ? ["\(apps) app group\(apps == 1 ? "" : "s") added"] : [])
            + (keychains > 0 ? ["\(keychains) keychain group\(keychains == 1 ? "" : "s") added"] : [])
        return said.isEmpty ? nil : said.joined(separator: " and ")
    }
}
