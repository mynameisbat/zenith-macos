import Testing
import Foundation
@testable import ZenithCore

@Suite("Command Hub compact sizes")
struct HubCompactSizeTests {
    private let en = Locale(identifier: "en_US")
    private let vi = Locale(identifier: "vi_VN")
    private func gb(_ v: Double) -> Int64 { Int64(v * 1_000_000_000) }

    @Test("HUBC-01: sizes are short, rounded by magnitude and use the locale's separator")
    func formats() {
        let cases: [(Int64, String, String)] = [
            (gb(0.5), "0.5 GB", "0,5 GB"),
            (gb(9.87), "9.9 GB", "9,9 GB"),
            (gb(212), "212 GB", "212 GB"),
            (gb(389.08), "389 GB", "389 GB"),
            (gb(999.9), "1.0 TB", "1,0 TB"),
            (gb(1200), "1.2 TB", "1,2 TB"),
            (gb(12340), "12 TB", "12 TB"),
            (gb(9.96), "10 GB", "10 GB"),
            (50_000_000, "50 MB", "50 MB"),
            (0, "0 MB", "0 MB"),
            (-5, "0 MB", "0 MB"),
        ]
        for (bytes, english, vietnamese) in cases {
            #expect(HubStatus.compactSize(bytes: bytes, locale: en) == english)
            #expect(HubStatus.compactSize(bytes: bytes, locale: vi) == vietnamese)
        }
    }

    @Test("HUBC-02: no result is longer than 7 characters, up to 100 TB")
    func short() {
        for exponent in stride(from: 0.0, through: 14.0, by: 0.37) {
            let text = HubStatus.compactSize(bytes: Int64(pow(10, exponent)), locale: vi)
            #expect(text.count <= 7, "\(text)")
        }
    }
}
