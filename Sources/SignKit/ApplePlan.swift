import Foundation

/// How an Apple app is signed: which code, in what order, with which profile and entitlements (the signing service's
/// logic, as apple_profiles.py had it: Signer.iPhoneSteps, Signer.entitlements, ProfileFolder), for rcodesign to carry
/// out. A bundle with a profile is signed with its entitlements; any other code keeps the entitlements and identifier
/// its signature has (rcodesign carries them over).
public struct ApplePlan {
    public struct Step: Equatable, Sendable {
        public var path: String
        /// A bundle, signed `--shallow` (its code signed by the steps before it).
        public var bundle: Bool
        public var entitlements: Data?
        public var profile: String?
        /// Where the profile is embedded.
        public var embed: String?
        /// Its profile's App ID prefix, which `$(AppIdentifierPrefix)` is filled with (#21); nil without a profile.
        public var prefix: String? = nil
    }

    public enum Platform: Sendable { case ios, mac }

    /// What a piece of code's signature carries now ({} when none): rcodesign's print-signature-info, read.
    public typealias OwnEntitlements = (_ code: String) async throws -> [String: Any]

    /// The steps for `app`, the deepest code first and the app last. Refuses, saying why, when a bundle has no profile
    /// here naming the certificate, or its entitlements ask for one its profile doesn't allow. `additions`' groups go
    /// into the app's own entitlements (not its extensions'), before its profile is checked.
    public static func steps(app: String, platform: Platform, profiles all: [AppleProfile], certificate: String, kinds: [AppleProfile.Kind],
                             now: Date = Date(), additions: AppleAdditions = .none, own: OwnEntitlements) async throws -> [Step] {
        let certificate = certificate.replacingOccurrences(of: ":", with: "").uppercased()
        let profiles = all.filter { $0.mac == (platform == .mac) }
        let nested = try AppleBundle.nestedCode(app)
        let appID = try AppleBundle.bundleID(app)
        var steps: [Step] = []
        switch platform {
        case .ios:
            var bundles = [appID]
            for code in nested where AppleBundle.isFolder(code) && AppleBundle.provisioned.contains(AppleBundle.extensionOf(code)) {
                let identifier = try AppleBundle.bundleID(code)
                guard identifier.hasPrefix(appID + ".") else {
                    throw SignError("\((code as NSString).lastPathComponent) in \(appID) is \(identifier), not one of \(appID)'s own")
                }
                bundles.append(identifier)
            }
            let chosen = try choose(profiles, for: bundles, kinds: kinds, certificate: certificate, now: now)
            for code in nested + [app] {
                let provisioned = code == app || (AppleBundle.isFolder(code) && AppleBundle.provisioned.contains(AppleBundle.extensionOf(code)))
                guard provisioned else {
                    steps.append(Step(path: code, bundle: AppleBundle.isFolder(code)))
                    continue
                }
                let identifier = code == app ? appID : try AppleBundle.bundleID(code)
                guard let profile = chosen[identifier] else { throw SignError("no profile chosen for \(identifier)") }
                let values = try entitlements(own: try await own(code), bundle: identifier, profile: profile,
                                              additions: code == app ? try additions.filled(prefix: profile.prefix) : .none)
                steps.append(Step(path: code, bundle: true, entitlements: try xml(values), profile: profile.path,
                                  embed: (code as NSString).appendingPathComponent("embedded.mobileprovision"), prefix: profile.prefix))
            }
        case .mac:
            for code in nested { steps.append(Step(path: code, bundle: AppleBundle.isFolder(code))) }
            // A Mac app's profile of the kind asked for (Developer ID, the default, or development), if it has one
            // here: a Developer ID app needs one only where its entitlements Apple restricts; a development build
            // always does (it names the Macs it runs on).
            let kind = kinds.first ?? .developerID
            let candidates = profiles.filter { $0.bundleID == appID && $0.kind == kind && $0.expires > now && $0.certificates.contains(certificate) }
            let ownValues = try await own(app)
            if kind != .developerID, candidates.isEmpty {
                throw SignError("no \(kind.rawValue) profile for \(appID) here naming the signing certificate: "
                                + AppleProfile.described(profiles, appID, certificate: certificate, now: now))
            }
            if let profile = candidates.max(by: { $0.expires < $1.expires }) {
                let filled = try additions.filled(prefix: profile.prefix)
                steps.append(Step(path: app, bundle: true,
                                  entitlements: try xml(entitlements(own: ownValues, bundle: appID, profile: profile, additions: filled)),
                                  profile: profile.path, embed: (app as NSString).appendingPathComponent("Contents/embedded.provisionprofile"),
                                  prefix: profile.prefix))
            } else {
                // Without a profile, an entitlement Apple restricts has macOS kill the app at launch (AMFI), which
                // notarizing doesn't catch: refused here instead (a keychain group added among them).
                // No profile: no prefix for `$(AppIdentifierPrefix)`, so a value using it is refused (#21).
                let values = try additions.filled(prefix: nil).applied(to: ownValues, bundle: appID)
                let restricted = values.filter { restrictedOnMac($0.key, $0.value) }.keys.sorted()
                guard restricted.isEmpty else {
                    throw SignError("\(appID) asks for \(restricted.joined(separator: ", ")), which only a Developer ID profile allows, and there's "
                                    + "no profile for it here naming the signing certificate: "
                                    + AppleProfile.described(profiles, appID, certificate: certificate, now: now))
                }
                steps.append(Step(path: app, bundle: true, entitlements: values.isEmpty ? nil : try xml(values)))
            }
        }
        return steps
    }

    static func xml(_ values: [String: Any]) throws -> Data {
        try PlistXML.data(values)
    }

    /// One profile per bundle id, all of one kind, the first kind that has one for each, every one naming the certificate.
    static func choose(_ profiles: [AppleProfile], for bundles: [String], kinds: [AppleProfile.Kind], certificate: String,
                       now: Date) throws -> [String: AppleProfile] {
        func fits(_ profile: AppleProfile, _ identifier: String, _ kind: AppleProfile.Kind) -> Bool {
            profile.bundleID == identifier && profile.kind == kind && profile.expires > now && profile.certificates.contains(certificate)
        }
        for kind in kinds {
            var chosen: [String: AppleProfile] = [:]
            for identifier in bundles {
                if let best = profiles.filter({ fits($0, identifier, kind) }).max(by: { $0.expires < $1.expires }) { chosen[identifier] = best }
            }
            if chosen.count == Set(bundles).count { return chosen }
        }
        let missing = bundles.first { identifier in !profiles.contains { profile in kinds.contains { fits(profile, identifier, $0) } } } ?? bundles[0]
        throw SignError("no \(kinds.map(\.rawValue).joined(separator: " or ")) profile for \(missing) here naming the signing certificate: "
                        + AppleProfile.described(profiles, missing, certificate: certificate, now: now))
    }

    /// Whether a Mac app's entitlement needs a provisioning profile: its identity, keychain groups, push and every
    /// other com.apple.developer one, and app groups not named by the team (group.*, since macOS 15).
    static func restrictedOnMac(_ key: String, _ value: Any) -> Bool {
        if ["com.apple.application-identifier", "keychain-access-groups", "com.apple.developer.team-identifier"].contains(key) { return true }
        if key.hasPrefix("com.apple.developer.") { return true }
        if key == "com.apple.security.application-groups" { return (value as? [Any] ?? []).contains { ($0 as? String)?.hasPrefix("group.") == true } }
        return false
    }

    /// A profile's entitlements for a bundle that came with none: the team's wildcard keychain group made the bundle's
    /// own, other wildcards left out.
    static func concrete(_ allowed: [String: Any], prefix: String, bundle: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in allowed {
            if let text = value as? String {
                if !text.contains("*") { result[key] = text }
            } else if let list = value as? [Any], let strings = list as? [String], strings.count == list.count {
                let kept = strings.compactMap { item -> String? in
                    if item == prefix + ".*" { return prefix + "." + bundle }
                    return item.contains("*") ? nil : item
                }
                if !kept.isEmpty { result[key] = kept }
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// A bundle's entitlements made its profile's: `additions`' groups added to them first (the outer app's alone), each
    /// refused where the profile doesn't allow it.
    static func entitlements(own: [String: Any], bundle: String, profile: AppleProfile, additions: AppleAdditions = .none) throws -> [String: Any] {
        let allowed = profile.entitlements
        let mac = profile.mac
        let identifierKey = mac ? "com.apple.application-identifier" : "application-identifier"
        let pushKey = mac ? "com.apple.developer.aps-environment" : "aps-environment"
        let debugKey = mac ? "com.apple.security.get-task-allow" : "get-task-allow"
        if let refused = additions.refusal(allowed: allowed) {
            throw SignError("\(bundle)'s profile (\(profile.name)) does not allow the \(refused): give its App ID those groups and make the "
                            + "profile again")
        }
        var result = additions.applied(to: own.isEmpty ? concrete(allowed, prefix: profile.prefix, bundle: bundle) : own, bundle: bundle,
                                       prefix: profile.prefix)
        let built = (own[identifierKey] as? String).flatMap { $0.contains(".") ? String($0.prefix { $0 != "." }) + "." : nil }
        result[identifierKey] = profile.prefix + "." + bundle
        if allowed["com.apple.developer.team-identifier"] != nil { result["com.apple.developer.team-identifier"] = profile.team }
        if let groups = result["keychain-access-groups"] as? [String] {
            result["keychain-access-groups"] = groups.map { group in
                for old in ["$(AppIdentifierPrefix)"] + (built.map { [$0] } ?? []) where group.hasPrefix(old) {
                    return profile.prefix + "." + group.dropFirst(old.count)
                }
                return group
            }
        }
        if result[pushKey] != nil, let push = allowed[pushKey] { result[pushKey] = push }
        if let debug = allowed[debugKey] { result[debugKey] = debug } else { result.removeValue(forKey: debugKey) }
        // On an iPhone every key must be one its profile allows; on a Mac those a profile gates, the hardened
        // runtime's and the sandbox's being no profile's.
        let refused = result.filter { allowed[$0.key] == nil && (!mac || restrictedOnMac($0.key, $0.value)) }.keys.sorted()
        guard refused.isEmpty else {
            throw SignError("\(bundle)'s profile (\(profile.name)) does not allow \(refused.joined(separator: ", ")): give its App ID those "
                            + "capabilities and make the profile again")
        }
        return result
    }

    /// The entitlements in rcodesign's print-signature-info output (its `entitlements_plist:` lines), {} when none.
    static func entitlements(fromSignatureInfo output: String) throws -> [String: Any] {
        var lines: [String] = []
        var collecting = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("entitlements_plist:") {
                collecting = true
                continue
            }
            guard collecting else { continue }
            guard stripped.hasPrefix("- ") else { break }
            var item = String(stripped.dropFirst(2))
            if item.count >= 2, item.hasPrefix("'"), item.hasSuffix("'") {
                item = String(item.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else if item.count >= 2, item.hasPrefix("\""), item.hasSuffix("\""),
                      let decoded = try? JSONDecoder().decode(String.self, from: Data(item.utf8)) {
                item = decoded
            }
            lines.append(item)
            if item.trimmingCharacters(in: .whitespaces) == "</plist>" { break }
        }
        guard !lines.isEmpty else { return [:] }
        guard let values = (try? PropertyListSerialization.propertyList(from: Data(lines.joined(separator: "\n").utf8), format: nil)) as? [String: Any] else {
            throw SignError("the entitlements its signature carries couldn't be read")
        }
        return values
    }
}
