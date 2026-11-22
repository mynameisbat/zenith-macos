import Testing
import Foundation
@testable import ZenithCore

@Suite("Command Hub gauges and tiles")
struct HubStatusTests {

    @Test("HUBS-01: CPU, memory, disk and process levels follow their thresholds")
    func levels() {
        #expect(HubGaugeLevel.cpu(percent: 40) == .normal)
        #expect(HubGaugeLevel.cpu(percent: 40.5) == .warning)
        #expect(HubGaugeLevel.cpu(percent: 75) == .warning)
        #expect(HubGaugeLevel.cpu(percent: 76) == .critical)
        #expect(HubGaugeLevel.memory(pressure: .normal) == .normal)
        #expect(HubGaugeLevel.memory(pressure: .warning) == .warning)
        #expect(HubGaugeLevel.memory(pressure: .critical) == .critical)
        #expect(HubGaugeLevel.disk(usedPercent: 90) == .normal)
        #expect(HubGaugeLevel.disk(usedPercent: 91) == .critical)
        #expect(HubGaugeLevel.process(cpuPercent: 20) == .normal)
        #expect(HubGaugeLevel.process(cpuPercent: 21) == .warning)
        #expect(HubGaugeLevel.process(cpuPercent: 51) == .critical)
    }

    @Test("HUBS-02: ring and bar fractions are clamped to 0...1 and survive bad numbers")
    func fractions() {
        #expect(HubStatus.ringFraction(percent: 31) == 0.31)
        #expect(HubStatus.ringFraction(percent: -5) == 0)
        #expect(HubStatus.ringFraction(percent: 240) == 1)
        #expect(HubStatus.ringFraction(percent: .nan) == 0)
        #expect(HubStatus.processBarFraction(cpuPercent: 38.5) == 0.1925)
        #expect(HubStatus.processBarFraction(cpuPercent: 800) == 1)
        #expect(HubStatus.processBarFraction(cpuPercent: .infinity) == 0)
    }

    @Test("HUBS-03: the Privacy Shield line is Off, On, or the real blocked count")
    func shieldStatus() {
        #expect(HubStatus.privacyShieldStatus(isOn: false, blockedRequests: 99) == "Off")
        #expect(HubStatus.privacyShieldStatus(isOn: true, blockedRequests: 0) == "On")
        #expect(HubStatus.privacyShieldStatus(isOn: true, blockedRequests: 128).contains("128"))
    }

    @Test("HUBS-04: the Keep Awake line is Off, or the service's own status")
    func awakeStatus() {
        #expect(HubStatus.keepAwakeStatus(nil) == "Off")
        let snapshot = KeepAwakeSnapshot(mode: .indefinite, isHoldingAssertion: true, keepsDisplayOn: false, remaining: nil)
        #expect(HubStatus.keepAwakeStatus(snapshot) == snapshot.statusText)
    }

    @Test("HUBS-20: a running app's CPU figure drops the decimal from 100 % and always reads as one short token")
    func processCPUText() {
        let en = Locale(identifier: "en_US"), vi = Locale(identifier: "vi_VN")
        #expect(HubStatus.processCPUText(percent: 0, locale: en) == "0%")
        #expect(HubStatus.processCPUText(percent: 9.5, locale: en) == "9.5%")
        #expect(HubStatus.processCPUText(percent: 99.94, locale: en) == "99.9%")
        #expect(HubStatus.processCPUText(percent: 99.96, locale: en) == "100%")
        #expect(HubStatus.processCPUText(percent: 155.5, locale: en) == "156%")
        #expect(HubStatus.processCPUText(percent: 1234.6, locale: en) == "1235%")
        #expect(HubStatus.processCPUText(percent: .nan, locale: en) == "0%")
        #expect(HubStatus.processCPUText(percent: -3, locale: en) == "0%")
        let viSmall = HubStatus.processCPUText(percent: 9.5, locale: vi)
        #expect(viSmall.hasPrefix("9,5"))
        #expect(HubStatus.processCPUText(percent: 155.5, locale: vi).hasPrefix("156"))
        #expect(!HubStatus.processCPUText(percent: 155.5, locale: vi).contains(","))
        #expect(HubStatus.processBarFraction(cpuPercent: 800) == 1)
    }
}
