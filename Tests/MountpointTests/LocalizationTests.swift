import Foundation
import Testing
@testable import Mountpoint

/// Every language has every text, with the same placeholders – a missing key would show English in the middle of French.
struct LocalizationTests {
    private func strings(_ code: String) -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(code).lproj/Localizable.strings")
        return NSDictionary(contentsOf: url) as? [String: String] ?? [:]
    }

    @Test func allLanguagesHaveTheSameTexts() {
        let reference = strings("de")
        #expect(!reference.isEmpty)
        for (code, _) in languages where code != "en" {
            let other = strings(code)
            #expect(Set(other.keys) == Set(reference.keys), "\(code): missing \(Set(reference.keys).subtracting(other.keys)), extra \(Set(other.keys).subtracting(reference.keys))")
            for (key, value) in other {
                let marks = { (s: String) in [s.components(separatedBy: "%@").count, s.components(separatedBy: "%lld").count] }
                #expect(marks(key) == marks(value), "\(code): placeholders differ in \(key)")
            }
        }
    }
}
