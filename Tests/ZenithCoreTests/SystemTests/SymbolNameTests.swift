import Testing
import AppKit
@testable import ZenithCore

@Suite("SymbolName: SF Symbols that need a newer macOS")
struct SymbolNameTests {
    @Test("A symbol this macOS has is used as it is")
    func presentSymbolIsKept() {
        #expect(SymbolName.available("star", fallback: "circle") == "star")
    }

    @Test("A symbol this macOS lacks is replaced by the fallback")
    func missingSymbolFallsBack() {
        #expect(SymbolName.available("zenith.no.such.symbol", fallback: "circle") == "circle")
    }

    @Test("Every name the app can show exists on this macOS, so a typo shows up here")
    func namesResolve() {
        for name in [SymbolName.shieldProtected, SymbolName.noTextFound, SymbolName.accessibility] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "no symbol named \(name)")
        }
    }

}
