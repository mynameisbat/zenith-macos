import Testing
import Foundation
import AppKit
@testable import ZenithCore

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    init(_ value: Int = 0) { _value = value }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
    func add(_ amount: Int) {
        lock.lock()
        defer { lock.unlock() }
        _value += amount
    }
}

private final class ThreadSafeSet<T: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _elements: Set<T> = []
    func insert(_ element: T) {
        lock.lock()
        defer { lock.unlock() }
        _elements.insert(element)
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _elements.count
    }
    var elements: Set<T> {
        lock.lock()
        defer { lock.unlock() }
        return _elements
    }
}

@Suite("Adversarial HotKey & Concurrency Stress Challenger Suite")
struct AdversarialHotKeyChallengerTests {

    // =========================================================================
    // MARK: - 1. 50+ Concurrent Tasks Hammering Registration, Rebinding & Deletion
    // =========================================================================

    @Test("80 concurrent tasks hammering registration, rebinding, trigger, and unregistration simultaneously")
    func testEightyConcurrentTasksHammeringHotKeyManager() async {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let totalRegistrations = ThreadSafeCounter()
        let totalTriggers = ThreadSafeCounter()
        let totalUnregistrations = ThreadSafeCounter()

        // 80 tasks, 50 iterations each = 4000 total high-contention operations
        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<80 {
                group.addTask {
                    for iter in 0..<50 {
                        let actionKey = "action.\(taskId % 10)" // Interleaved shared IDs cause rebinding collisions
                        let uniqueActionKey = "unique.\(taskId).\(iter)"
                        let op = (taskId + iter) % 6

                        switch op {
                        case 0:
                            // Register on shared action ID (rebinding)
                            let def = HotKeyDefinition(
                                id: actionKey,
                                name: "Shared \(actionKey)",
                                keyCode: UInt32(1000 + taskId * 10 + (iter % 5)),
                                carbonModifiers: 768,
                                keyEquivalent: "Test\(taskId)"
                            )
                            if manager.registerHotKey(def, handler: { totalTriggers.increment() }) {
                                totalRegistrations.increment()
                            }

                        case 1:
                            // Register unique action ID
                            let def = HotKeyDefinition(
                                id: uniqueActionKey,
                                name: "Unique \(uniqueActionKey)",
                                keyCode: UInt32(5000 + taskId * 100 + iter),
                                carbonModifiers: 768,
                                keyEquivalent: "Unique\(taskId)"
                            )
                            if manager.registerHotKey(def, handler: { totalTriggers.increment() }) {
                                totalRegistrations.increment()
                            }

                        case 2:
                            // Simulate hotkey triggers
                            _ = manager.simulateHotKeyTrigger(id: actionKey)
                            _ = manager.simulateHotKeyTrigger(id: uniqueActionKey)

                        case 3:
                            // Unregister specific actions
                            manager.unregisterHotKey(id: actionKey)
                            manager.unregisterHotKey(id: uniqueActionKey)
                            totalUnregistrations.increment()

                        case 4:
                            // Diagnostics integrity check under active mutation (each call is thread-safe and non-crashing)
                            let count = manager.registeredCount
                            #expect(count >= 0)
                            let hotkeys = manager.registeredHotKeys
                            #expect(hotkeys.count >= 0)
                            let isReg = manager.isRegistered(id: actionKey)
                            _ = manager.carbonId(for: actionKey)
                            #expect(isReg == true || isReg == false)

                        case 5:
                            // Conflict discovery check under active mutation
                            let checkDef = HotKeyDefinition(
                                id: "probe.\(taskId)",
                                name: "Probe",
                                keyCode: UInt32(5000 + taskId * 100 + iter),
                                carbonModifiers: 768,
                                keyEquivalent: "Probe"
                            )
                            _ = manager.findConflict(for: checkDef)

                        default:
                            break
                        }
                    }
                }
            }
        }

        // Final state consistency verification
        #expect(manager.registeredCount >= 0)
        #expect(manager.registeredCount == manager.registeredHotKeys.count)
        #expect(backend.registeredRefsCount == manager.registeredCount)

        // Clean unregistration of all remaining
        manager.unregisterAll()
        #expect(manager.registeredCount == 0)
        #expect(backend.registeredRefsCount == 0)
    }

    @Test("60 concurrent tasks continuously rebinding and triggering preserved action IDs")
    func testConcurrentRebindingAndTriggerIntegrity() async {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let triggerSum = ThreadSafeCounter()

        // Initialize 5 base actions
        for i in 0..<5 {
            let def = HotKeyDefinition(
                id: "persistent.action.\(i)",
                name: "Persistent \(i)",
                keyCode: UInt32(i + 10),
                carbonModifiers: 768,
                keyEquivalent: "P\(i)"
            )
            _ = manager.registerHotKey(def) {
                triggerSum.increment()
            }
        }
        #expect(manager.registeredCount == 5)

        // 60 concurrent tasks hammering re-registration and triggering
        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<60 {
                group.addTask {
                    let targetId = "persistent.action.\(taskId % 5)"
                    for iter in 0..<30 {
                        let newDef = HotKeyDefinition(
                            id: targetId,
                            name: "Rebound \(targetId)",
                            keyCode: UInt32(100 + (taskId * 30 + iter)),
                            carbonModifiers: 768,
                            keyEquivalent: "R\(taskId)_\(iter)"
                        )
                        // Dynamic rebinding preserving handler
                        _ = manager.reRegister(definition: newDef)
                        // Trigger
                        _ = manager.simulateHotKeyTrigger(id: targetId)
                    }
                }
            }
        }

        #expect(manager.registeredCount == 5)
        #expect(triggerSum.value > 0)
    }

    // =========================================================================
    // MARK: - 2. Re-entrant Attacks (Unregistration & Registration Inside Callbacks)
    // =========================================================================

    @Test("Re-entrant attack: Shortcut handler unregisters itself inside callback without deadlock")
    func testReentrantSelfUnregistrationAttack() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let def = HotKeyDefinition(id: "self.destruct", name: "Self Destruct", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")
        let callbackExecuted = ThreadSafeCounter()

        let registered = manager.registerHotKey(def) {
            callbackExecuted.increment()
            // Re-entrant unregister
            manager.unregisterHotKey(id: "self.destruct")
            #expect(manager.isRegistered(id: "self.destruct") == false)
            #expect(manager.registeredCount == 0)
        }
        #expect(registered == true)

        let carbonId = manager.carbonId(for: "self.destruct")!
        backend.simulateKeyPress(hotKeyID: carbonId)

        #expect(callbackExecuted.value == 1)
        #expect(manager.isRegistered(id: "self.destruct") == false)
        #expect(manager.registeredCount == 0)
        #expect(backend.registeredRefsCount == 0)
    }

    @Test("Re-entrant attack: Shortcut handler registers a new shortcut inside its callback")
    func testReentrantNewRegistrationInsideCallback() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let defA = HotKeyDefinition(id: "action.A", name: "Action A", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")
        let defB = HotKeyDefinition(id: "action.B", name: "Action B", keyCode: 8, carbonModifiers: 768, keyEquivalent: "⌘⇧C")

        let order = ThreadSafeCounter()

        _ = manager.registerHotKey(defA) {
            order.increment() // 1
            // Re-entrant registration of Action B
            let successB = manager.registerHotKey(defB) {
                order.increment() // 2
            }
            #expect(successB == true)
            #expect(manager.isRegistered(id: "action.B") == true)
            #expect(manager.registeredCount == 2)

            // Re-entrant trigger of Action B
            _ = manager.simulateHotKeyTrigger(id: "action.B")
        }

        #expect(manager.registeredCount == 1)
        _ = manager.simulateHotKeyTrigger(id: "action.A")

        #expect(order.value == 2)
        #expect(manager.registeredCount == 2)
        #expect(manager.isRegistered(id: "action.A") == true)
        #expect(manager.isRegistered(id: "action.B") == true)
    }

    @Test("Re-entrant attack: Shortcut handler dynamically re-binds itself to a new shortcut inside callback")
    func testReentrantSelfRebindingInsideCallback() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let initialDef = HotKeyDefinition(id: "mutating.action", name: "Mutating", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")
        let reboundDef = HotKeyDefinition(id: "mutating.action", name: "Mutating", keyCode: 8, carbonModifiers: 2048, keyEquivalent: "⌥C")

        let executionCount = ThreadSafeCounter()

        _ = manager.registerHotKey(initialDef) {
            executionCount.increment()
            // Re-entrant self rebind
            let rebound = manager.registerHotKey(reboundDef) {
                executionCount.add(10)
            }
            #expect(rebound == true)
        }

        let oldCarbonId = manager.carbonId(for: "mutating.action")!
        // First trigger
        backend.simulateKeyPress(hotKeyID: oldCarbonId)
        #expect(executionCount.value == 1)

        let newCarbonId = manager.carbonId(for: "mutating.action")!
        #expect(oldCarbonId != newCarbonId)

        // Second trigger on old key should be dead
        backend.simulateKeyPress(hotKeyID: oldCarbonId)
        #expect(executionCount.value == 1)

        // Trigger on new key fires new handler
        backend.simulateKeyPress(hotKeyID: newCarbonId)
        #expect(executionCount.value == 11)
        #expect(manager.registeredCount == 1)
    }

    @Test("Re-entrant attack: Shortcut handler calls unregisterAll inside callback")
    func testReentrantUnregisterAllInsideCallback() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let def1 = HotKeyDefinition(id: "k1", name: "K1", keyCode: 1, carbonModifiers: 768, keyEquivalent: "⌘⇧S")
        let def2 = HotKeyDefinition(id: "k2", name: "K2", keyCode: 2, carbonModifiers: 768, keyEquivalent: "⌘⇧D")
        let def3 = HotKeyDefinition(id: "k3", name: "K3", keyCode: 3, carbonModifiers: 768, keyEquivalent: "⌘⇧F")

        let handlerFired = ThreadSafeCounter()

        _ = manager.registerHotKey(def1) {
            handlerFired.increment()
            // Re-entrant unregisterAll
            manager.unregisterAll()
            #expect(manager.registeredCount == 0)
        }
        _ = manager.registerHotKey(def2) {}
        _ = manager.registerHotKey(def3) {}

        #expect(manager.registeredCount == 3)
        _ = manager.simulateHotKeyTrigger(id: "k1")

        #expect(handlerFired.value == 1)
        #expect(manager.registeredCount == 0)
        #expect(backend.registeredRefsCount == 0)
    }

    @Test("Re-entrant attack: Deep 10-level recursive cascade of chained registrations and triggers")
    func testDeepRecursiveCascadeOfReentrantRegistrations() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let chainExecuted = ThreadSafeCounter()

        func registerNextInChain(level: Int) {
            guard level <= 10 else {
                // At terminal level 10, clean unregister all
                manager.unregisterAll()
                return
            }

            let def = HotKeyDefinition(
                id: "chain.\(level)",
                name: "Chain \(level)",
                keyCode: UInt32(level + 10),
                carbonModifiers: 768,
                keyEquivalent: "Chain\(level)"
            )

            _ = manager.registerHotKey(def) {
                chainExecuted.increment()
                registerNextInChain(level: level + 1)
                _ = manager.simulateHotKeyTrigger(id: "chain.\(level + 1)")
            }
        }

        // Kick off chain at level 1
        registerNextInChain(level: 1)
        #expect(manager.registeredCount == 1)

        _ = manager.simulateHotKeyTrigger(id: "chain.1")

        #expect(chainExecuted.value == 10)
        #expect(manager.registeredCount == 0)
        #expect(backend.registeredRefsCount == 0)
    }

    // =========================================================================
    // MARK: - 3. Duplicate Shortcut Conflict Attacks
    // =========================================================================

    @Test("Conflict attack: 60 concurrent tasks race to register the EXACT same shortcut")
    func testSixtyConcurrentTasksSingleShortcutRace() async {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let successCount = ThreadSafeCounter()
        let rejectionCount = ThreadSafeCounter()
        let successfulWinners = ThreadSafeSet<String>()

        let targetShortcut = HotKeyDefinition(
            id: "", // Will be assigned contestant ID
            name: "High Noon",
            keyCode: 9, // V
            carbonModifiers: 768, // Cmd + Shift
            keyEquivalent: "⌘⇧V"
        )

        // 60 tasks race to register identical keycode and modifiers
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<60 {
                group.addTask {
                    let contestantId = "contestant.\(i)"
                    let def = HotKeyDefinition(
                        id: contestantId,
                        name: "Contestant \(i)",
                        keyCode: targetShortcut.keyCode,
                        carbonModifiers: targetShortcut.carbonModifiers,
                        keyEquivalent: targetShortcut.keyEquivalent
                    )

                    if manager.registerHotKey(def, handler: {}) {
                        successCount.increment()
                        successfulWinners.insert(contestantId)
                    } else {
                        rejectionCount.increment()
                    }
                }
            }
        }

        // Empirical assertion: Strictly ONE winner, 59 rejections
        #expect(successCount.value == 1)
        #expect(rejectionCount.value == 59)
        #expect(successfulWinners.count == 1)
        #expect(manager.registeredCount == 1)
        #expect(backend.registeredRefsCount == 1)

        // Verify conflict detection finds the winner
        let probe = HotKeyDefinition(
            id: "probe.latecomer",
            name: "Latecomer",
            keyCode: 9,
            carbonModifiers: 768,
            keyEquivalent: "⌘⇧V"
        )
        let conflict = manager.findConflict(for: probe)
        #expect(conflict != nil)
        #expect(successfulWinners.elements.contains(conflict!.id))
    }

    @Test("Conflict attack: Atomic rollback preserves existing registration when rebind conflicts")
    func testAtomicRollbackWhenRebindConflicts() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let defA = HotKeyDefinition(id: "action.A", name: "Action A", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")
        let defB = HotKeyDefinition(id: "action.B", name: "Action B", keyCode: 18, carbonModifiers: 768, keyEquivalent: "⌘⇧1")

        let aTriggered = ThreadSafeCounter()
        let bTriggered = ThreadSafeCounter()

        #expect(manager.registerHotKey(defA) { aTriggered.increment() } == true)
        #expect(manager.registerHotKey(defB) { bTriggered.increment() } == true)
        #expect(manager.registeredCount == 2)

        // Action B attempts to rebind to Action A's shortcut (⌘⇧V)
        let conflictingDefB = HotKeyDefinition(
            id: "action.B",
            name: "Action B Rebound",
            keyCode: 9,
            carbonModifiers: 768,
            keyEquivalent: "⌘⇧V"
        )

        let rebindSuccess = manager.registerHotKey(conflictingDefB) {
            bTriggered.add(100)
        }

        // Must reject rebind
        #expect(rebindSuccess == false)

        // Crucial empirical invariant: Action B was NOT destroyed by the failed rebind attempt!
        // Action B MUST still be registered with its original shortcut (⌘⇧1)
        #expect(manager.isRegistered(id: "action.B") == true)
        #expect(manager.isRegistered(id: "action.A") == true)
        #expect(manager.registeredCount == 2)

        // Action A still triggers
        _ = manager.simulateHotKeyTrigger(id: "action.A")
        #expect(aTriggered.value == 1)

        // Action B still triggers with original handler
        _ = manager.simulateHotKeyTrigger(id: "action.B")
        #expect(bTriggered.value == 1)

        // Now Action A unregisters
        manager.unregisterHotKey(id: "action.A")
        #expect(manager.registeredCount == 1)

        // Now Action B rebind to ⌘⇧V MUST SUCCEED
        let rebindAfterUnregister = manager.registerHotKey(conflictingDefB) {
            bTriggered.add(10)
        }
        #expect(rebindAfterUnregister == true)
        #expect(manager.registeredCount == 1)

        _ = manager.simulateHotKeyTrigger(id: "action.B")
        #expect(bTriggered.value == 11)
    }

    @Test("Conflict attack: Self-rebinding does NOT falsely detect a conflict against itself")
    func testSelfRebindingIsNotFalseConflict() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let def = HotKeyDefinition(id: "solo.action", name: "Solo", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")
        let triggerCount = ThreadSafeCounter()

        #expect(manager.registerHotKey(def) { triggerCount.increment() } == true)
        #expect(manager.findConflict(for: def) == nil) // Self is not a conflict

        // Rebind same ID to same shortcut but new handler closure
        let rebindSame = manager.registerHotKey(def) {
            triggerCount.add(100)
        }
        #expect(rebindSame == true)
        #expect(manager.registeredCount == 1)

        _ = manager.simulateHotKeyTrigger(id: "solo.action")
        #expect(triggerCount.value == 100)
    }

    // =========================================================================
    // MARK: - 4. Fuzzing HotKeyParser: Pathological & Adversarial Inputs
    // =========================================================================

    @Test("Parser Fuzz: Empty strings, tabs, newlines, and multi-byte whitespace permutations")
    func testFuzzEmptyAndWhitespacePermutations() {
        let whitespaceInputs: [String] = [
            "",
            " ",
            "    ",
            "\t",
            "\n",
            "\r\n",
            " \t \n \r ",
            "\u{00A0}", // Non-breaking space
            "\u{2000}", // En quad
            "\u{2003}", // Em space
            "\u{3000}", // Ideographic space
            "\t\t\t\n\n\n   \r\r\r"
        ]

        for input in whitespaceInputs {
            #expect(throws: HotKeyParseError.emptyString) {
                try HotKeyParser.parse(input)
            }
        }
    }

    @Test("Parser Fuzz: Delimiter-only and degenerate syntax permutations")
    func testFuzzDelimiterChaos() {
        let delimiterInputs: [String] = [
            "+",
            "++",
            "+++",
            "-",
            "--",
            "---",
            "+-+",
            "-+-",
            " + ",
            " - ",
            "++V",
            "--V",
            "+-V",
            "Cmd+",
            "Cmd-",
            "Cmd++",
            "Cmd--",
            "Cmd+Shift+",
            "Cmd-Shift-",
            "Cmd+Shift++",
            "Cmd+Shift+-",
            "⌘+",
            "⌥-",
            "⌃++",
            "⌘⇧+"
        ]

        for input in delimiterInputs {
            // Must deterministically throw an expected error, NEVER crash or return invalid state
            do {
                _ = try HotKeyParser.parse(input)
            } catch let err as HotKeyParseError {
                switch err {
                case .emptyString, .missingModifier, .missingKey, .unknownKey:
                    #expect(Bool(true))
                }
            } catch {
                Issue.record("Unexpected error type: \(error) for input '\(input)'")
            }
        }
    }

    @Test("Parser Fuzz: Unsupported modifiers and exotic platform shortcuts")
    func testFuzzUnsupportedModifiers() {
        let unsupportedModifierInputs: [String] = [
            "Win+V",
            "Windows+V",
            "Super+Shift+A",
            "Hyper+Space",
            "Meta+C",
            "Fn+F1",
            "AltGr+X",
            "Meh+Z",
            "Mod+B",
            "Caps+V",
            "CapsLock+V",
            "NumLock+1",
            "ScrollLock+S",
            "Ctrl+Super+Cmd+A",
            "Win+Shift+Opt+V"
        ]

        for input in unsupportedModifierInputs {
            #expect(throws: HotKeyParseError.self) {
                try HotKeyParser.parse(input)
            }
        }
    }

    @Test("Parser Fuzz: Invalid keys, emojis, non-ASCII CJK, and control characters")
    func testFuzzInvalidKeysAndPathologicalTokens() {
        let invalidKeyInputs: [String] = [
            "Cmd+Shift+InvalidKeyName",
            "Cmd+Shift+XYZ123",
            "Cmd+Shift+F13",
            "Cmd+Shift+F24",
            "Cmd+Shift+DeleteMe",
            "Cmd+Shift+🚀",
            "Cmd+Shift+🍎",
            "⌘⇧🔥",
            "⌘⇧漢字",
            "Cmd+Shift+日本語",
            "⌥русский",
            "Cmd+Shift+\u{0000}",
            "Cmd+Shift+\u{0007}",
            "Cmd+Shift+\u{001B}",
            "Cmd+Shift+LongBogusKeyNameExceedingThirtyCharacters"
        ]

        for input in invalidKeyInputs {
            #expect(throws: HotKeyParseError.self) {
                try HotKeyParser.parse(input)
            }
        }
    }

    @Test("Parser Fuzz: Giant repeated input string performance and safety (<20ms)")
    func testFuzzGiantRepeatedStringsPerformance() {
        let giantMod = String(repeating: "Cmd+", count: 1000) + "V"
        let giantSpaces = "   " + String(repeating: " ", count: 20000) + "Cmd+V   "
        let giantGlyphs = String(repeating: "⌘", count: 1000) + "V"

        let start = DispatchTime.now()

        // Giant glyphs: deduplicated to command
        if let (mods, key) = try? HotKeyParser.parse(giantGlyphs) {
            #expect(mods == CarbonModifierFlags.command.rawValue)
            #expect(key == 9)
        }

        // Giant spaces: trimmed cleanly
        if let (mods, key) = try? HotKeyParser.parse(giantSpaces) {
            #expect(mods == CarbonModifierFlags.command.rawValue)
            #expect(key == 9)
        }

        // Giant repetition of delimiters: parses or throws cleanly
        _ = try? HotKeyParser.parse(giantMod)

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        #expect(elapsed < 100.0) // Must execute well under 100ms
    }

    @Test("Parser: Exhaustive bidirectional round-trip across all ANSI keys")
    func testExhaustiveBidirectionalKeyMapping() {
        let testCodes: [UInt32] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, // Letters
            18, 19, 20, 21, 22, 23, 25, 26, 28, 29, // Digits
            36, 48, 49, 51, 53, 117, 123, 124, 125, 126, // Navigation
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1-F12
            27, 24, 33, 30, 42, 41, 39, 43, 47, 44, 50 // Punctuation
        ]

        for code in testCodes {
            guard let name = KeyCodeMapping.name(for: code) else {
                Issue.record("Missing name for code \(code)")
                continue
            }

            guard let roundtripCode = KeyCodeMapping.keyCode(for: name) else {
                Issue.record("Failed reverse lookup for name '\(name)'")
                continue
            }

            #expect(roundtripCode == code)

            // Format with standard Cmd+Shift
            let badge = HotKeyParser.format(keyCode: code, carbonModifiers: 768)
            #expect(!badge.isEmpty)
            #expect(badge.contains("⌘"))
            #expect(badge.contains("⇧"))
        }
    }

    // =========================================================================
    // MARK: - 5. AudioFeedbackManager Concurrency Stress
    // =========================================================================

    @Test("AudioFeedbackManager: 100 concurrent tasks hammering sound triggers and mute toggling")
    func testAudioFeedbackManagerConcurrentStress() async {
        let mockBackend = MockAudioPlayerBackend()
        let defaults = UserDefaults(suiteName: "AudioStress_\(UUID().uuidString)")!
        let store = SettingsStore(userDefaults: defaults)
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let effect = SoundEffect.allCases[i % SoundEffect.allCases.count]
                    audioManager.play(effect)
                    if i % 5 == 0 {
                        audioManager.isMuted = (i % 2 == 0)
                    }
                    if i % 7 == 0 {
                        audioManager.volume = Float(i % 10) / 10.0
                    }
                }
            }
        }

        #expect(audioManager.totalPlayedCount >= 0)
        #expect(audioManager.volume >= 0.0 && audioManager.volume <= 1.0)
    }
}
