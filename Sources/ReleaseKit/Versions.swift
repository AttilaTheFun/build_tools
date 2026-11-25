import Foundation

/// A repository's versions as its releases and tags have them (ported from shireworks' version_from_tags.sh and
/// check_version_line.sh): the committed Info.plist names the line, `MAJOR.MINOR.0`, and each build of it is
/// `MAJOR.MINOR.N`, N one past the highest of the line's releases and tags, or the one already given to this commit.
public enum Versions {
    /// `1.2` of `1.2`, `1.2.0` or `1.2.7`; nil unless it starts MAJOR.MINOR, both numbers.
    public static func line(of version: String) -> String? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        return "\(Int(parts[0])!).\(Int(parts[1])!)"
    }

    /// The version a build of `commit` on `line` is: the number a release or tag of the line at that commit already
    /// has (the same again for the same commit), else one past the line's highest.
    public static func next(line: String, commit: String, releases: [(tag: String, commit: String)], tags: [String]) -> String {
        let prefix = "v\(line)."
        func number(_ tag: String) -> Int? {
            guard tag.hasPrefix(prefix) else { return nil }
            let rest = tag.dropFirst(prefix.count)
            guard !rest.isEmpty, rest.allSatisfy(\.isASCIIDigit) else { return nil }
            return Int(rest)
        }
        var highest = 0
        var mine = 0
        for release in releases {
            guard let n = number(release.tag) else { continue }
            highest = max(highest, n)
            if release.commit == commit { mine = max(mine, n) }
        }
        for tag in tags {
            if let n = number(tag) { highest = max(highest, n) }
        }
        return "\(line).\(mine > 0 ? mine : highest + 1)"
    }

    /// The line's production releases (published, not pre-releases), if any: a line that has one takes no more
    /// proposals, so the committed line must move on.
    public static func published(on line: String, releases: [(tag: String, draft: Bool, prerelease: Bool)]) -> [String] {
        releases.filter { release in
            guard !release.draft, !release.prerelease, release.tag.hasPrefix("v") else { return false }
            return Self.line(of: String(release.tag.dropFirst())) == line && release.tag.dropFirst().split(separator: ".").count <= 3
        }.map(\.tag)
    }

    /// The line after `line`: `1.3` after `1.2`.
    public static func lineAfter(_ line: String) -> String {
        let parts = line.split(separator: ".").compactMap { Int($0) }
        return "\(parts[0]).\(parts[1] + 1)"
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// An XML Info.plist's string value read or set as text, the rest of the file left as it is (its comments too), as
/// version_from_tags.sh did: the first `<string>` after the key.
public enum InfoPlistText {
    public static func value(of key: String, in text: String) -> String? {
        guard let range = valueRange(of: key, in: text) else { return nil }
        return String(text[range])
    }

    public static func setting(_ key: String, to value: String, in text: String) -> String? {
        guard let range = valueRange(of: key, in: text) else { return nil }
        var text = text
        text.replaceSubrange(range, with: value)
        return text
    }

    private static func valueRange(of key: String, in text: String) -> Range<String.Index>? {
        guard let keyRange = text.range(of: "<key>\(key)</key>"),
              let open = text.range(of: "<string>", range: keyRange.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) else { return nil }
        // Only whitespace (or comments) between the key and its string: not some later key's.
        let between = text[keyRange.upperBound..<open.lowerBound]
        guard !between.contains("<key>") else { return nil }
        return open.upperBound..<close.lowerBound
    }
}
