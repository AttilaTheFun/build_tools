import Foundation

/// An XML property list written here, not by PropertyListSerialization: statically linked (rules_swift's default for
/// a tool built by Bazel on Linux), Foundation can't bridge a Bool into a property list ("property lists cannot contain
/// objects of type 'Not A Type'"; Isomer, 2026-11-19), which every development profile's get-task-allow and every
/// BuildVariant stamp met. Read by Foundation as any XML plist is.
enum PlistXML {
    struct Unwritable: Error, CustomStringConvertible {
        let description: String
    }

    static func data(_ value: Any) throws -> Data {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        try write(value, into: &out, indent: "")
        out += "</plist>\n"
        return Data(out.utf8)
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A Bool's value, where `value` is one, decided by its type, never by bridging: a number read from a plist
    /// (UIDeviceFamily's 1 and 2, any 0 or 1) bridges to a Bool where it's asked to be one (NCH's review of #6).
    static func boolean(_ value: Any) -> Bool? {
        #if canImport(Darwin)
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil }
        #else
        // swift-corelibs-foundation: a Bool as itself, or an NSNumber made of one (its objCType "c"); never a number's.
        if let number = value as? NSNumber, type(of: value) != Bool.self {
            return String(cString: number.objCType) == "c" ? number.boolValue : nil
        }
        #endif
        return type(of: value) == Bool.self ? value as? Bool : nil
    }

    static func write(_ value: Any, into out: inout String, indent: String) throws {
        if let flag = boolean(value) {
            out += indent + (flag ? "<true/>" : "<false/>") + "\n"
        } else if let text = value as? String {
            out += indent + "<string>\(escaped(text))</string>\n"
        } else if let whole = value as? Int {
            out += indent + "<integer>\(whole)</integer>\n"
        } else if let real = value as? Double {
            out += indent + "<real>\(real)</real>\n"
        } else if let data = value as? Data {
            out += indent + "<data>\(data.base64EncodedString())</data>\n"
        } else if let date = value as? Date {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime]
            out += indent + "<date>\(format.string(from: date))</date>\n"
        } else if let list = value as? [Any] {
            out += indent + "<array>\n"
            for item in list { try write(item, into: &out, indent: indent + "\t") }
            out += indent + "</array>\n"
        } else if let dictionary = value as? [String: Any] {
            out += indent + "<dict>\n"
            for key in dictionary.keys.sorted() {
                out += indent + "\t<key>\(escaped(key))</key>\n"
                try write(dictionary[key]!, into: &out, indent: indent + "\t")
            }
            out += indent + "</dict>\n"
        } else {
            throw Unwritable(description: "a property list can't hold \(type(of: value))")
        }
    }
}
