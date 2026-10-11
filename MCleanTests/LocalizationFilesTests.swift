import XCTest

final class LocalizationFilesTests: XCTestCase {
    func testTranslationsPreserveFormatArgumentTypes() throws {
        let files = try localizableStringsFiles()
        func dictionary(_ url: URL) throws -> [String: String] {
            try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
        }
        let english = try dictionary(XCTUnwrap(files["en"]))
        let pattern = #"%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|h|l|L|z|j|t)?[@diuoxXfFeEgGaAcCsSp%]"#
        let regex = try NSRegularExpression(pattern: pattern)
        func arguments(_ string: String) -> [String] {
            regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
                .compactMap { Range($0.range, in: string).map { String(string[$0]) } }
                .filter { $0 != "%%" }.sorted()
        }
        for (language, url) in files {
            for (key, value) in try dictionary(url) {
                XCTAssertEqual(arguments(value), arguments(english[key] ?? key), "\(language): \(key)")
            }
        }
    }
    func testAllLocalizableStringsFilesHaveEnglishKeyParity() throws {
        let localizationFiles = try localizableStringsFiles()
        let englishURL = try XCTUnwrap(
            localizationFiles["en"],
            "Expected en.lproj/Localizable.strings to exist"
        )
        let englishKeys = try localizedKeys(in: englishURL)

        for (language, fileURL) in localizationFiles where language != "en" {
            let languageKeys = try localizedKeys(in: fileURL)
            let missingKeys = englishKeys.subtracting(languageKeys).sorted()
            let extraKeys = languageKeys.subtracting(englishKeys).sorted()

            XCTAssertTrue(
                missingKeys.isEmpty,
                "\(language).lproj/Localizable.strings is missing keys:\n\(missingKeys.joined(separator: "\n"))"
            )
            XCTAssertTrue(
                extraKeys.isEmpty,
                "\(language).lproj/Localizable.strings has extra keys:\n\(extraKeys.joined(separator: "\n"))"
            )
        }
    }

    private func localizableStringsFiles() throws -> [String: URL] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSourceDirectory = sourceRoot.appendingPathComponent("MClean")
        let contents = try FileManager.default.contentsOfDirectory(
            at: appSourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        return contents.reduce(into: [String: URL]()) { result, url in
            guard url.pathExtension == "lproj",
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("Localizable.strings").path)
            else {
                return
            }

            result[url.deletingPathExtension().lastPathComponent] = url.appendingPathComponent("Localizable.strings")
        }
    }

    private func localizedKeys(in fileURL: URL) throws -> Set<String> {
        let data = try Data(contentsOf: fileURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let strings = plist as? [String: String] else {
            XCTFail("\(fileURL.path) is not a valid Localizable.strings dictionary")
            return []
        }

        return Set(strings.keys)
    }
}
