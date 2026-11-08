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

    @Test("Every name the app can show exists on this macOS, so a typo in a fallback shows up here")
    func namesResolve() {
        for name in [SymbolName.shieldProtected, SymbolName.noTextFound, SymbolName.accessibility] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "no symbol named \(name)")
        }
    }

    @Test("The fallbacks are symbols macOS 13 has (checked on a macOS 13.7 virtual machine)")
    func fallbacksAreTheMacOS13Ones() {
        // On a Mac that has the newer symbols these names are not the ones in use, so check them directly.
        for name in ["checkmark.shield", "magnifyingglass", "figure.stand"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "no symbol named \(name)")
        }
    }
}
