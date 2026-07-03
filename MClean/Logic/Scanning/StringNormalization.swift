import Foundation

extension String {

    /// Called once per filesystem entry during app scans, so it must stay
    /// cheap: one lowercasing pass plus one in-place removal pass, instead of
    /// four chained replacingOccurrences each allocating a fresh String.
    func normalizedForMatching() -> String {
        var out = self.lowercased()
        out.removeAll { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }
        return out
    }

    func strippingTrailingVersion() -> String {
        self.replacingOccurrences(
            of: #"\s+\d+(\.\d+)*\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    var lettersOnly: String {
        self.filter { $0.isLetter }.lowercased()
    }

    var bundleCompanyName: String? {
        let components = self.components(separatedBy: ".")
        guard components.count == 3 else { return nil }
        let company = components[1]
        return company.isEmpty ? nil : company.normalizedForMatching()
    }

    var bundleLastTwoComponents: String {
        let components = self.components(separatedBy: ".")
            .compactMap { $0 != "-" ? $0.lowercased() : nil }
        return components.suffix(2).joined()
    }

    var baseBundleIdentifier: String? {
        let components = self.components(separatedBy: ".")
        let suffixes: Set<String> = [
            "helper", "agent", "daemon", "service", "xpc",
            "launcher", "updater", "installer", "uninstaller",
            "login", "extension", "plugin"
        ]
        guard components.count >= 4,
              let last = components.last?.lowercased(),
              suffixes.contains(last) else { return nil }
        return components.dropLast().joined(separator: ".")
    }
}
