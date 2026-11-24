import AppKit
import CoreGraphics
import Foundation
import IOKit

/// A display the Mac has online, as CoreGraphics names it.
public struct DisplayDescriptor: Equatable, Sendable, Identifiable {
    /// The `CGDirectDisplayID`.
    public let id: UInt32
    public let name: String
    public let isBuiltIn: Bool
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public init(id: UInt32, name: String, isBuiltIn: Bool, vendor: UInt32 = 0, model: UInt32 = 0, serial: UInt32 = 0) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }

    /// What identifies the physical display across reconnections (the DDC chip that worked is remembered by it).
    public var key: String { "\(vendor):\(model):\(serial)" }
}

/// The DDC connection of one external display: the bus, the chip to try first and what the display's EDID says.
public struct DDCLink: Sendable {
    public let transport: any DDCTransport
    public let initialChip: UInt8
    public let edid: EDID?

    public init(transport: any DDCTransport, initialChip: UInt8, edid: EDID?) {
        self.transport = transport
        self.initialChip = initialChip
        self.edid = edid
    }
}

/// Where the displays and their DDC connections come from. The real one reads CoreGraphics and the IO registry; tests
/// and the screenshot renderer use `SimulatedDisplayInventory`.
public protocol DisplayInventory: Sendable {
    /// The displays that are online. Quick; called on the main thread.
    @MainActor func onlineDisplays() -> [DisplayDescriptor]
    /// The DDC connection of each external display among `displays` that has one. Blocks (it reads EDIDs over the
    /// bus): call it off the main thread.
    func ddcLinks(for displays: [DisplayDescriptor]) -> [UInt32: DDCLink]
}

/// Pairs the DDC connections found in the IO registry with the displays CoreGraphics lists.
public enum DDCLinkMatcher {
    /// By EDID first (vendor, model and serial are what CoreGraphics reports too); then, if exactly one external
    /// display and one connection are left over, together. Built-in displays never get a link.
    public static func match(displays: [DisplayDescriptor], links: [DDCLink]) -> [UInt32: DDCLink] {
        var free = links
        var result: [UInt32: DDCLink] = [:]
        let external = displays.filter { !$0.isBuiltIn }
        for display in external {
            let index = free.firstIndex { $0.edid?.matches(vendor: display.vendor, model: display.model, serial: display.serial) == true }
            if let index { result[display.id] = free.remove(at: index) }
        }
        let unmatched = external.filter { result[$0.id] == nil }
        if unmatched.count == 1, free.count == 1 {
            result[unmatched[0].id] = free[0]
        }
        return result
    }
}

/// The real inventory: `CGGetOnlineDisplayList` for the displays, and the `DCPAVServiceProxy` entries marked
/// "External" in the IO registry for their DDC connections (the lookup m1ddc does; MIT, Copyright (c) 2021
/// waydabber, see THIRD_PARTY_NOTICES.md). A proxy whose parent's `EPICProviderClass` is `AppleDCPMCDP29XX` is a
/// DisplayPort-to-HDMI bridge, which answers at chip 0xB7.
public struct SystemDisplayInventory: DisplayInventory {
    public init() {}

    @MainActor
    public func onlineDisplays() -> [DisplayDescriptor] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        let screens = NSScreen.screens
        return ids.prefix(Int(count)).map { id in
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let screenName = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName
            let fallback = isBuiltIn ? String(localized: "Built-in Display") : String(localized: "Display")
            return DisplayDescriptor(
                id: id, name: screenName ?? fallback, isBuiltIn: isBuiltIn,
                vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id)
            )
        }
    }

    public func ddcLinks(for displays: [DisplayDescriptor]) -> [UInt32: DDCLink] {
        guard displays.contains(where: { !$0.isBuiltIn }), IOAVServiceAPI.functions != nil else { return [:] }
        return DDCLinkMatcher.match(displays: displays, links: externalLinks())
    }

    /// One link per external `DCPAVServiceProxy`, with its EDID read.
    private func externalLinks() -> [DDCLink] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var links: [DDCLink] = []
        while case let proxy = IOIteratorNext(iterator), proxy != 0 {
            defer { IOObjectRelease(proxy) }
            guard Self.stringProperty("Location", of: proxy) == "External",
                  let transport = IOAVServiceTransport(proxy: proxy) else { continue }
            let chip = Self.isBridge(proxy) ? DDCChip.bridge : DDCChip.standard
            let edid = transport.read(chip: DDCChip.edid, offset: 0, count: EDID.length).flatMap { EDID(bytes: $0) }
            links.append(DDCLink(transport: transport, initialChip: chip, edid: edid))
        }
        return links
    }

    private static func stringProperty(_ key: String, of entry: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private static func isBridge(_ proxy: io_service_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return stringProperty("EPICProviderClass", of: parent) == "AppleDCPMCDP29XX"
    }
}
