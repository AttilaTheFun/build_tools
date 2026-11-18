import Foundation

/// An app's bundles and code, as the signing service walks them (shireworks' Signer.nestedCode; apple_profiles.py).
enum AppleBundle {
    /// The extensions of bundles that carry code of their own.
    static let codeBundles: Set<String> = ["app", "appex", "framework", "xpc", "bundle", "plugin", "kext", "systemextension", "dext",
                                           "qlgenerator", "mdimporter"]
    /// Those an iPhone app provisions, each with its own profile.
    static let provisioned: Set<String> = ["app", "appex"]

    /// A bundle's Info.plist path: a Mac app's, an iPhone app's or framework's, a Mac framework's
    /// (Versions/Current/Resources, by its link).
    static func infoPath(_ bundle: String) -> String? {
        for relative in ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"] {
            let path = (bundle as NSString).appendingPathComponent(relative)
            var folder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &folder), !folder.boolValue { return path }
        }
        return nil
    }

    static func info(_ bundle: String) -> [String: Any]? {
        guard let path = infoPath(bundle), let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func bundleID(_ bundle: String) throws -> String {
        guard let identifier = info(bundle)?["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw SignError("\((bundle as NSString).lastPathComponent) names no CFBundleIdentifier")
        }
        return identifier
    }

    static func executable(_ bundle: String) -> String? {
        guard let name = info(bundle)?["CFBundleExecutable"] as? String, !name.isEmpty else { return nil }
        for relative in ["Contents/MacOS/\(name)", name] {
            let path = (bundle as NSString).appendingPathComponent(relative)
            var folder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &folder), !folder.boolValue { return path }
        }
        return nil
    }

    static func isMachO(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return false }
        let bytes = [UInt8](head)
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let following = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        if [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE].contains(magic) { return true }
        // A universal binary's count of architectures; a Java class file's version (45 or more) begins the same.
        return (magic == 0xCAFEBABE || magic == 0xCAFEBABF) && (1..<45).contains(following)
    }

    static func extensionOf(_ path: String) -> String { (path as NSString).pathExtension }

    static func hasCode(_ bundle: String) -> Bool {
        !["bundle", "plugin"].contains(extensionOf(bundle)) || executable(bundle) != nil
    }

    static func isLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return !isLink(path) && FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    static func realPath(_ path: String) -> String { (path as NSString).resolvingSymlinksInPath }

    /// The code inside a bundle, the deepest first: bundles of code, and every Mach-O file but a bundle's own
    /// executable; links never followed.
    static func nestedCode(_ bundle: String) throws -> [String] {
        var executables = Set<String>()
        var found: [String] = []
        var queue = [bundle]
        while let folder = queue.popLast() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted() ?? []
            for name in names {
                let path = (folder as NSString).appendingPathComponent(name)
                if isLink(path) { continue }
                if isFolder(path) {
                    queue.append(path)
                    guard name.contains("."), codeBundles.contains(extensionOf(name)), hasCode(path) else { continue }
                    // A Mac framework with versions is signed as its current version (Versions/A): rcodesign takes
                    // that for a bundle nested in the framework, which --shallow leaves alone.
                    var signed = path
                    let current = (path as NSString).appendingPathComponent("Versions/Current")
                    if isLink(current), FileManager.default.fileExists(atPath: current) {
                        let resolved = realPath(current)
                        // Only a version inside the framework: a malformed link never steers the signer outside it.
                        guard resolved.hasPrefix(realPath(path) + "/") else {
                            throw SignError("\(path.dropFirst(bundle.count + 1))'s Versions/Current points outside it")
                        }
                        signed = resolved
                    }
                    found.append(signed)
                    if let main = executable(signed) { executables.insert(realPath(main)) }
                } else if isMachO(path) {
                    found.append(path)
                }
            }
        }
        if let own = executable(bundle) { executables.insert(realPath(own)) }
        return found
            .filter { isFolder($0) || !executables.contains(realPath($0)) }
            .sorted { a, b in
                let (da, db) = (a.split(separator: "/").count, b.split(separator: "/").count)
                return da != db ? da > db : a < b
            }
    }
}
