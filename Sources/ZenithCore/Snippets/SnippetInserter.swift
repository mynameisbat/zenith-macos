import Foundation
import AppKit
import CoreGraphics

// MARK: - Key posting seam

/// Presses keys for the inserter: delete to remove a typed trigger, the left arrow to place the caret. The app uses
/// `SystemSnippetKeyPoster`; tests use `RecordingSnippetKeyPoster`, so no real key is ever pressed.
public protocol SnippetKeyPosting: Sendable {
    func press(keyCode: CGKeyCode)
}

/// Key codes the inserter presses (Carbon `kVK_*`; the same on every layout).
public enum SnippetKeyCode {
    public static let delete: CGKeyCode = 51
    public static let leftArrow: CGKeyCode = 123
}

/// Marks Zenith's own key events so the snippet event tap does not read them as typing.
public enum SnippetSyntheticEventMarker {
    /// Stored in `CGEventField.eventSourceUserData`.
    public static let userData: Int64 = 0x5A_4E_53_4E   // "ZNSN"
}

/// Posts real key presses to the HID event stream, marked as Zenith's own.
public struct SystemSnippetKeyPoster: SnippetKeyPosting {
    public init() {}

    public func press(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        for event in [down, up] {
            // No modifier the user happens to hold (Shift would select instead of move).
            event.flags = keyCode == SnippetKeyCode.leftArrow ? [.maskNumericPad, .maskSecondaryFn] : []
            event.setIntegerValueField(.eventSourceUserData, value: SnippetSyntheticEventMarker.userData)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Remembers the keys it was asked to press, and presses none.
public final class RecordingSnippetKeyPoster: SnippetKeyPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CGKeyCode] = []

    public init() {}

    public var pressedKeys: [CGKeyCode] { lock.withLock { recorded } }

    public func press(keyCode: CGKeyCode) {
        lock.withLock { recorded.append(keyCode) }
    }
}

// MARK: - Inserter

/// Why an insertion did not happen.
public enum SnippetInsertionResult: Equatable, Sendable {
    case inserted
    /// Zenith may not press keys (Accessibility is not granted).
    case notTrusted
}

/// Puts a snippet's text where the user is typing: deletes the typed trigger, writes the text to the clipboard,
/// presses ⌘V (`AutoPasteService`), moves the caret back for `{cursor}`, and puts the user's clipboard back.
///
/// The text is written with the transient and auto-generated markers, and the write and the restore are reported
/// through `onOwnWrite` (the app marks them in `PasteboardMonitor`), so the clipboard history records neither.
/// The restore only happens if the clipboard still holds the snippet: a copy the user makes meanwhile is kept.
@MainActor
public final class SnippetInserter {
    /// How long the target app gets to read the pasted text before the clipboard is put back.
    public static let restoreDelay: TimeInterval = 0.5
    /// A pause between ⌘V and the caret moves, so the app has inserted the text before the caret moves.
    public static let caretDelay: TimeInterval = 0.05
    /// More left-arrow presses than this would be slow to watch; the caret then stays at the end.
    public static let maximumCaretMoves = 400

    let pasteboard: NSPasteboard
    private let paster: AutoPasteServiceProtocol
    private let keys: SnippetKeyPosting
    private let isTrusted: @Sendable () -> Bool
    private let scheduler: ClipboardScheduling
    private let onOwnWrite: @MainActor (Int) -> Void

    /// The user's clipboard while a snippet sits on it, and the change count of that snippet write.
    private var pending: (snapshot: [[(NSPasteboard.PasteboardType, Data)]], writtenCount: Int, task: ClipboardScheduledTask)?

    public init(
        pasteboard: NSPasteboard = .general,
        paster: AutoPasteServiceProtocol = AutoPasteService.shared,
        keys: SnippetKeyPosting = SystemSnippetKeyPoster(),
        isTrusted: @escaping @Sendable () -> Bool = { SystemPermissions.checkAccessibilityPermission() },
        scheduler: ClipboardScheduling = MainQueueClipboardScheduler(),
        onOwnWrite: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        self.pasteboard = pasteboard
        self.paster = paster
        self.keys = keys
        self.isTrusted = isTrusted
        self.scheduler = scheduler
        self.onOwnWrite = onOwnWrite
    }

    /// Whether the user's clipboard is waiting to be put back.
    public var isRestorePending: Bool { pending != nil }

    /// The text of the user's clipboard while a snippet sits on it; nil when nothing is waiting or it held no text.
    var pendingClipboardText: String? {
        guard let pending, pasteboard.changeCount == pending.writtenCount else { return nil }
        for item in pending.snapshot {
            if let data = item.first(where: { $0.0 == .string })?.1 { return String(data: data, encoding: .utf8) }
        }
        return nil
    }

    @discardableResult
    public func insert(_ expansion: SnippetExpansion, deletingCharacters deleteCount: Int = 0) -> SnippetInsertionResult {
        guard isTrusted() else { return .notTrusted }

        // A second snippet before the first restore: the clipboard holds the first snippet, not the user's copy,
        // so keep the snapshot taken the first time.
        let snapshot: [[(NSPasteboard.PasteboardType, Data)]]
        if let pending, pasteboard.changeCount == pending.writtenCount {
            pending.task.cancel()
            snapshot = pending.snapshot
        } else {
            pending?.task.cancel()
            snapshot = Self.snapshot(of: pasteboard)
        }
        pending = nil

        for _ in 0..<max(0, deleteCount) {
            keys.press(keyCode: SnippetKeyCode.delete)
        }

        pasteboard.clearContents()
        pasteboard.setString(expansion.text, forType: .string)
        // Other clipboard managers skip these too (nspasteboard.org).
        pasteboard.setData(Data(), forType: SensitivePasteboardMarker.transientType)
        pasteboard.setData(Data(), forType: SensitivePasteboardMarker.autoGeneratedType)
        let written = pasteboard.changeCount
        onOwnWrite(written)

        paster.paste()

        let moves = expansion.caretOffsetFromEnd
        if moves > 0, moves <= Self.maximumCaretMoves {
            _ = scheduler.schedule(after: Self.caretDelay) { [keys] in
                for _ in 0..<moves { keys.press(keyCode: SnippetKeyCode.leftArrow) }
            }
        }

        let task = scheduler.schedule(after: Self.restoreDelay) { [weak self] in
            self?.restore()
        }
        pending = (snapshot, written, task)
        return .inserted
    }

    /// Puts the user's clipboard back now, if it still holds the snippet (the app calls this before quitting).
    public func restoreNow() {
        pending?.task.cancel()
        restore()
    }

    private func restore() {
        guard let pending else { return }
        self.pending = nil
        guard pasteboard.changeCount == pending.writtenCount else { return }   // the user copied something since
        pasteboard.clearContents()
        let items = pending.snapshot.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        onOwnWrite(pasteboard.changeCount)
    }

    /// Every type of every item, as data.
    nonisolated static func snapshot(of pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            // In the order the app declared them: readers often take the first type they understand.
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }
}
