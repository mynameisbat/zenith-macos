import Testing
import Foundation
@testable import GoldenGateCore

@Suite("Universal Binary Slimmer Service Suite")
struct BinarySlimmerServiceTests {

    @Test("SLIM-01: Mach-O parser inspects binary headers accurately")
    func testMachOHeaderParsing() throws {
        let service = BinarySlimmerService()

        // Test on an actual installed universal binary if present (e.g. Claude or Chrome)
        let candidatePaths = [
            "/Applications/Claude.app/Contents/MacOS/Claude",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ]

        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            if let binary = service.inspectBinary(atPath: path) {
                #expect(binary.totalSizeBytes > 0)
                if binary.isUniversal {
                    #expect(binary.architectures.contains("arm64"))
                    #expect(binary.architectures.contains("x86_64"))
                    #expect(binary.intelSizeBytes > 0)
                    break
                }
            }
        }

        // System protection verification
        #expect(service.isProtectedSystemApp(atPath: "/System/Applications/Safari.app") == true)
        #expect(service.isProtectedSystemApp(atPath: "/Applications/Claude.app") == false)
    }

    @Test("SLIM-02: Non-Mach-O or text files are rejected safely without crash")
    func testNonMachOFiles() throws {
        let fm = FileManager.default
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_TextFile_\(UUID().uuidString).txt")
        try "Not a binary".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tempFile) }

        let service = BinarySlimmerService()
        let result = service.inspectBinary(atPath: tempFile.path)
        #expect(result == nil)
    }
}
