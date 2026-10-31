import Foundation
import Testing
@testable import LuxtableCore

// The string tables in app/Resources/Localization (docs/LOCALIZATION.md): every
// translation has every English key with the same format specifiers, the bundle the app
// ships resolves them per language, and the test host itself stays English.

private let localizationDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Localization", isDirectory: true)

private let tables = ["Localizable", "InfoPlist"]

private func languages() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: localizationDir.path)
        .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }.sorted()
}

private func table(_ lang: String, _ name: String) throws -> [String: String] {
    let url = localizationDir.appendingPathComponent("\(lang).lproj/\(name).strings")
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(plist as? [String: String], "\(lang)/\(name).strings is not a string table")
}

/// Argument position → conversion (%@, %lld, …), positional (%2$@) or sequential.
private func specifiers(_ s: String) -> [Int: String] {
    let pattern = #"%(?:(\d+)\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfeEgGcCsSpaAF%])"#
    let re = try! NSRegularExpression(pattern: pattern)
    var out: [Int: String] = [:]
    var next = 1
    let ns = s as NSString
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        func group(_ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        let conversion = group(3)!
        if conversion == "%" { continue }
        let position: Int
        if let p = group(1).flatMap(Int.init) { position = p } else { position = next; next += 1 }
        let kind = (group(2) ?? "") + conversion
        out[position] = ["i": "d", "lli": "lld", "li": "ld", "lf": "f"][kind] ?? kind
    }
    return out
}

@Suite("Localization")
struct LocalizationTests {
    @Test func shipsTheDeclaredLanguages() throws {
        #expect(try languages() == ["de", "en", "es", "fr", "ja", "zh-Hans"])
        let plist = try String(contentsOf: localizationDir.deletingLastPathComponent()
            .appendingPathComponent("Info.plist.in"), encoding: .utf8)
        for lang in try languages() {
            #expect(plist.contains("<string>\(lang)</string>"), "CFBundleLocalizations lacks \(lang)")
        }
    }

    /// The privacy prompts in InfoPlist.strings are the ones Info.plist.in declares.
    @Test func infoPlistStringsMatchThePlist() throws {
        let url = localizationDir.deletingLastPathComponent().appendingPathComponent("Info.plist.in")
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any])
        let prompts = plist.compactMapValues { $0 as? String }.filter { $0.key.hasSuffix("UsageDescription") }
        #expect(!prompts.isEmpty)
        #expect(try table("en", "InfoPlist") == prompts)
    }

    @Test func theEnglishTableIsTheSource() throws {
        let base = try table("en", "Localizable")
        #expect(base.count > 500)
        for (key, value) in base { #expect(key == value, "en: \(key) is translated") }
    }

    @Test(arguments: ["de", "fr", "es", "ja", "zh-Hans"])
    func everyKeyIsTranslated(_ lang: String) throws {
        for name in tables {
            let base = try table("en", name)
            let tr = try table(lang, name)
            #expect(Set(base.keys).subtracting(tr.keys).sorted() == [], "\(lang)/\(name): missing")
            #expect(Set(tr.keys).subtracting(base.keys).sorted() == [], "\(lang)/\(name): not in English")
            for (key, english) in base {
                guard let value = tr[key] else { continue }
                #expect(specifiers(value) == specifiers(english), "\(lang)/\(name): \(key) → \(value)")
                #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty || english.isEmpty, "\(lang): \(key) empty")
            }
        }
    }

    @Test func specifierParsing() {
        #expect(specifiers("Moved %lld photos to %@") == [1: "lld", 2: "@"])
        #expect(specifiers("%2$@ に %1$lld 枚") == [1: "lld", 2: "@"])
        #expect(specifiers("100%% at %.1f and %i") == [1: "f", 2: "d"])
        #expect(specifiers("%lf") == specifiers("%f"))
        #expect(specifiers("%@ %@") != specifiers("%@"))
    }

    /// The tables as the app ships them (Contents/Resources/<lang>.lproj) resolve per language.
    @Test func theShippedBundleResolvesEachLanguage() throws {
        let bundle = try #require(Bundle(url: localizationDir))
        #expect(Set(bundle.localizations).isSuperset(of: ["en", "de", "fr", "es", "ja", "zh-Hans"]))
        let key = "Import from Card…"
        let expected = ["en": key, "de": try table("de", "Localizable")[key]]
        for (lang, value) in expected {
            let path = try #require(bundle.path(forResource: "Localizable", ofType: "strings",
                                                inDirectory: nil, forLocalization: lang))
            let lproj = try #require(Bundle(path: (path as NSString).deletingLastPathComponent))
            #expect(lproj.localizedString(forKey: key, value: "?", table: nil) == value)
        }
        #expect(expected["de"] != key, "German is not translated")
        #expect(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["de-CH"]) == ["de"])
        #expect(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["zh-Hans-CN"]) == ["zh-Hans"])
    }

    /// The test host has no string tables: models and views resolve to the English source,
    /// which is what every other test asserts.
    @Test func theTestHostIsEnglish() {
        #expect(EmptyState.Action.importCard.title == "Import from Card…")
        #expect(String(localized: "Import from Card…") == "Import from Card…")
        // Colour tags: `title` is shown, `name` stays the English identifier.
        #expect(ColorTag.allCases.map(\.title) == ColorTag.allCases.map(\.name))
    }
}
