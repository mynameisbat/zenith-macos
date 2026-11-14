import Testing
import Foundation
import Darwin
@testable import ZenithCore

/// A process table that exists only in the test: signals are recorded and change the table, nothing real is touched.
final class FakeProcessControl: ProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int32: ProcessIdentity]
    private var _signals: [(signal: Int32, pid: Int32)] = []
    /// PIDs that ignore SIGTERM (they still die on SIGKILL unless also in `unkillable`).
    var ignoresTerm: Set<Int32> = []
    var unkillable: Set<Int32> = []
    /// errno returned by `send` for these PIDs.
    var sendErrors: [Int32: Int32] = [:]

    init(_ table: [Int32: ProcessIdentity]) {
        self.table = table
    }

    var signals: [(signal: Int32, pid: Int32)] { lock.withLock { _signals } }

    func replace(_ pid: Int32, with identity: ProcessIdentity?) {
        lock.withLock { table[pid] = identity }
    }

    func identity(of pid: Int32) -> ProcessIdentity? {
        lock.withLock { table[pid] }
    }

    func send(_ signal: Int32, to pid: Int32) -> Int32 {
        lock.withLock {
            _signals.append((signal, pid))
            if let error = sendErrors[pid] { return error }
            guard table[pid] != nil else { return ESRCH }
            switch signal {
            case SIGTERM where !ignoresTerm.contains(pid):
                table[pid] = nil
            case SIGKILL where !unkillable.contains(pid):
                table[pid] = nil
            default:
                break
            }
            return 0
        }
    }
}

/// `lsof -F pcuLftPnT` output recorded on a Mac (user names and PIDs changed).
private let recordedLsof = """
p821
cidentityservicesd
u501
Ltester
f7
tIPv4
PUDP
n*:*
f38
tIPv4
PUDP
n*:61126
p829
crapportd
u501
Ltester
f11
tIPv4
PTCP
n*:61779
TST=LISTEN
TQR=0
TQS=0
f12
tIPv6
PTCP
n*:61779
TST=LISTEN
TQR=0
TQS=0
p4242
cnode
u501
Ltester
f23
tIPv6
PTCP
n[::1]:3000
TST=LISTEN
f24
tIPv4
PTCP
n127.0.0.1:3000
TST=LISTEN
f25
tIPv4
PTCP
n127.0.0.1:3000->127.0.0.1:52100
TST=ESTABLISHED
p5150
cpostgres
u501
Ltester
f7
tIPv4
PTCP
n192.168.1.20:5432
TST=LISTEN
f9
tIPv4
PUDP
n127.0.0.1:61000->127.0.0.1:61000
p6000
cGoogle Chrome Helper
u501
Ltester
f30
tIPv6
PTCP
n[fe80::1%lo0]:9222
TST=LISTEN
"""

private let userUID: UInt32 = 501
private let zenithPID: Int32 = 777

private func identity(_ path: String?, uid: UInt32 = userUID, start: UInt64 = 1_000) -> ProcessIdentity {
    ProcessIdentity(uid: uid, executablePath: path, startTime: start)
}

private func port(_ pid: Int32, _ name: String, _ number: UInt16, path: String? = "/opt/homebrew/bin/node", uid: UInt32 = userUID) -> ListeningPort {
    ListeningPort(
        pid: pid, processName: name, uid: uid, user: "tester", proto: .tcp, address: "127.0.0.1", port: number,
        identity: identity(path, uid: uid)
    )
}

@MainActor
private func makeModel(control: FakeProcessControl, lsof: String = "") -> PortManagerModel {
    PortManagerModel(
        runner: { _, _ in SystemCommandResult(status: 0, output: lsof) },
        control: control,
        currentUID: userUID,
        ownPID: zenithPID,
        gracePeriod: 1,
        sleep: { _ in }
    )
}

@Suite("Port manager")
struct PortManagerTests {
    // MARK: Parser

    @Test("PM-01: recorded lsof output becomes one entry per listening socket")
    func parsesRecordedOutput() {
        let ports = LsofPortParser.parse(recordedLsof)
        let summary = ports.map { "\($0.processName) \($0.proto.rawValue) \($0.address) \($0.port)" }
        #expect(summary == [
            "node TCP 127.0.0.1 3000",
            "node TCP ::1 3000",
            "postgres TCP 192.168.1.20 5432",
            "Google Chrome Helper TCP fe80::1%lo0 9222",
            "identityservicesd UDP * 61126",
            "rapportd TCP * 61779",
        ])
        let node = ports.first { $0.pid == 4242 }
        #expect(node?.uid == 501)
        #expect(node?.user == "tester")
    }

    @Test("PM-02: connected sockets, a port of *, and non-LISTEN TCP are dropped; IPv4+IPv6 wildcards merge")
    func dropsNonListening() {
        let ports = LsofPortParser.parse(recordedLsof)
        #expect(!ports.contains { $0.port == 52100 || $0.port == 61000 })
        #expect(ports.filter { $0.port == 61779 }.count == 1)
        #expect(LsofPortParser.splitEndpoint("*:*") == nil)
        #expect(LsofPortParser.splitEndpoint("1.2.3.4:5->6.7.8.9:10") == nil)
        #expect(LsofPortParser.splitEndpoint("0.0.0.0:80")?.address == "*")
        #expect(LsofPortParser.splitEndpoint("[::]:80")?.address == "*")
        #expect(LsofPortParser.splitEndpoint("*:70000") == nil)
    }

    @Test("PM-03: empty or garbage output parses to nothing without crashing")
    func toleratesGarbage() {
        #expect(LsofPortParser.parse("").isEmpty)
        #expect(LsofPortParser.parse("n*:80\nPTCP\nf3\n").isEmpty) // no process line first
        #expect(LsofPortParser.parse("pabc\nf1\nPTCP\nn*:80\n").isEmpty)
        #expect(LsofPortParser.parse("p12\r\nf1\r\nPTCP\r\nn*:80\r\nTST=LISTEN\r\n").map(\.port) == [80])
    }

    @Test("PM-04: lsof is asked for numeric listening TCP, UDP only when wanted")
    func lsofArguments() {
        let tcp = LsofPortParser.arguments(includeUDP: false)
        #expect(tcp.contains("-nP") && tcp.contains("-iTCP") && tcp.contains("-sTCP:LISTEN") && tcp.contains("-F"))
        #expect(!tcp.contains("-iUDP"))
        #expect(LsofPortParser.arguments(includeUDP: true).contains("-iUDP"))
    }

    @Test("PM-05: reach of an address")
    func reach() {
        #expect(PortReach.of(address: "*") == .allInterfaces)
        #expect(PortReach.of(address: "127.0.0.1") == .thisMacOnly)
        #expect(PortReach.of(address: "::1") == .thisMacOnly)
        #expect(PortReach.of(address: "192.168.1.20") == .specificAddress)
    }

    @Test("PM-06: the lister adds identities and reports lsof failures")
    func listerAddsIdentity() {
        let control = FakeProcessControl([4242: identity("/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")])
        let result = PortLister.list(includeUDP: false, runner: { _, _ in SystemCommandResult(status: 0, output: recordedLsof) }, control: control)
        let ports = (try? result.get()) ?? []
        let node = ports.first { $0.pid == 4242 }
        #expect(node?.identity != nil)
        #expect(node?.appBundlePath == "/Applications/Code.app")
        #expect(ports.first { $0.pid == 5150 }?.identity == nil)

        let none = PortLister.list(includeUDP: false, runner: { _, _ in SystemCommandResult(status: 1, output: "") }, control: control)
        #expect((try? none.get())?.isEmpty == true)
        let broken = PortLister.list(includeUDP: false, runner: { _, _ in SystemCommandResult(status: 1, output: "", errorOutput: "lsof: boom") }, control: control)
        #expect(broken == .failure(.failed("lsof: boom")))
        #expect(PortLister.list(includeUDP: false, runner: { _, _ in nil }, control: control) == .failure(.couldNotRun))
    }

    // MARK: Filter

    @Test("PM-07: search by port, :port, PID, name and user")
    func filter() {
        let ports = LsofPortParser.parse(recordedLsof)
        #expect(PortManagerModel.filter(ports, query: "3000").map(\.port) == [3000, 3000])
        #expect(PortManagerModel.filter(ports, query: ":54").map(\.port) == [5432])
        #expect(PortManagerModel.filter(ports, query: "5150").map(\.port) == [5432])
        #expect(PortManagerModel.filter(ports, query: "POST").map(\.processName) == ["postgres"])
        #expect(PortManagerModel.filter(ports, query: "chrome").count == 1)
        #expect(PortManagerModel.filter(ports, query: "  ").count == ports.count)
        #expect(PortManagerModel.filter(ports, query: "nothing-like-this").isEmpty)
    }

    // MARK: Safety

    @Test("PM-08: launchd, Zenith, other users, system folders and unreadable processes are refused")
    func safetyRules() {
        func refusal(_ pid: Int32, _ identity: ProcessIdentity?) -> PortStopRefusal? {
            PortProcessSafety.refusal(pid: pid, identity: identity, currentUID: userUID, ownPID: zenithPID)
        }
        #expect(refusal(1, identity("/sbin/launchd", uid: 0)) == .launchd)
        #expect(refusal(0, nil) == .launchd)
        #expect(refusal(zenithPID, identity("/Applications/Zenith.app/Contents/MacOS/Zenith")) == .zenith)
        #expect(refusal(300, identity("/opt/homebrew/bin/nginx", uid: 0)) == .otherUser)
        #expect(refusal(301, identity("/usr/local/bin/redis-server", uid: 502)) == .otherUser)
        #expect(refusal(302, identity("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")) == .systemProcess)
        #expect(refusal(303, identity("/usr/libexec/rapportd")) == .systemProcess)
        #expect(refusal(304, identity("/usr/sbin/cupsd")) == .systemProcess)
        #expect(refusal(305, identity("/usr/local/../sbin/sshd")) == .systemProcess)
        #expect(refusal(306, nil) == .unknownProcess)
        #expect(refusal(307, identity(nil)) == .unknownProcess)
        #expect(refusal(308, identity("relative/path")) == .unknownProcess)
        #expect(refusal(4242, identity("/opt/homebrew/bin/node")) == nil)
        #expect(refusal(4243, identity("/usr/bin/python3")) == nil)
    }

    @Test("PM-09: every refusal has a message")
    func refusalMessages() {
        let all: [PortStopRefusal] = [.launchd, .zenith, .otherUser, .systemProcess, .unknownProcess, .processChanged]
        #expect(all.allSatisfy { !$0.message.isEmpty })
    }

    // MARK: Stop flow

    @Test("PM-10: declining the confirmation sends nothing")
    @MainActor
    func declineSendsNothing() async {
        let control = FakeProcessControl([4242: identity("/opt/homebrew/bin/node")])
        let model = makeModel(control: control)
        var asked: (String, String, String)?
        let outcome = await model.stop(port(4242, "node", 3000)) { title, message, action in
            asked = (title, message, action)
            return false
        }
        #expect(outcome == .cancelled)
        #expect(control.signals.isEmpty)
        #expect(asked?.0.contains("node") == true)
        #expect(asked?.0.contains("3000") == true)
        #expect(asked?.1.contains("4242") == true)
    }

    @Test("PM-11: a refused process is never confirmed nor signalled")
    @MainActor
    func refusedNeverSignalled() async {
        let control = FakeProcessControl([
            1: identity("/sbin/launchd", uid: 0),
            zenithPID: identity("/Applications/Zenith.app/Contents/MacOS/Zenith"),
            300: identity("/opt/homebrew/bin/nginx", uid: 0),
            303: identity("/usr/libexec/rapportd"),
        ])
        let model = makeModel(control: control)
        let cases: [(ListeningPort, PortStopRefusal)] = [
            (port(1, "launchd", 22, path: "/sbin/launchd", uid: 0), .launchd),
            (port(zenithPID, "Zenith", 8080, path: "/Applications/Zenith.app/Contents/MacOS/Zenith"), .zenith),
            (port(300, "nginx", 80, path: "/opt/homebrew/bin/nginx", uid: 0), .otherUser),
            (port(303, "rapportd", 61779, path: "/usr/libexec/rapportd"), .systemProcess),
        ]
        for (entry, expected) in cases {
            var asked = false
            let outcome = await model.stop(entry) { _, _, _ in asked = true; return true }
            #expect(outcome == .refused(expected))
            #expect(!asked)
            #expect(model.refusal(for: entry) == expected)
            let force = await model.forceQuit(entry) { _, _, _ in asked = true; return true }
            #expect(force == .refused(expected))
            #expect(!asked)
        }
        #expect(control.signals.isEmpty)
    }

    @Test("PM-12: SIGTERM, and the process goes away")
    @MainActor
    func stopSendsTerm() async {
        let control = FakeProcessControl([4242: identity("/opt/homebrew/bin/node")])
        let model = makeModel(control: control)
        let outcome = await model.stop(port(4242, "node", 3000)) { _, _, _ in true }
        #expect(outcome == .stopped)
        #expect(control.signals.map(\.signal) == [SIGTERM])
        #expect(control.signals.map(\.pid) == [4242])
        #expect(model.stopStates[4242] == nil)
    }

    @Test("PM-13: still running after the grace period offers Force Quit, which sends SIGKILL after asking")
    @MainActor
    func forceQuitAfterTimeout() async {
        let control = FakeProcessControl([4242: identity("/opt/homebrew/bin/node")])
        control.ignoresTerm = [4242]
        let model = makeModel(control: control)
        let entry = port(4242, "node", 3000)

        let outcome = await model.stop(entry) { _, _, _ in true }
        #expect(outcome == .stillRunning)
        #expect(model.stopStates[4242] == .stillRunning)

        let declined = await model.forceQuit(entry) { _, _, _ in false }
        #expect(declined == .cancelled)
        #expect(control.signals.map(\.signal) == [SIGTERM])

        var forceTitle = ""
        let forced = await model.forceQuit(entry) { title, _, _ in forceTitle = title; return true }
        #expect(forced == .stopped)
        #expect(forceTitle.contains("node"))
        #expect(control.signals.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(model.stopStates[4242] == nil)
    }

    @Test("PM-14: a process that outlives SIGKILL is reported as failed")
    @MainActor
    func survivesKill() async {
        let control = FakeProcessControl([4242: identity("/opt/homebrew/bin/node")])
        control.ignoresTerm = [4242]
        control.unkillable = [4242]
        let model = makeModel(control: control)
        let outcome = await model.forceQuit(port(4242, "node", 3000)) { _, _, _ in true }
        guard case .failed = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        guard case .failed = model.stopStates[4242] else {
            Issue.record("expected a failed state")
            return
        }
    }

    @Test("PM-15: a reused PID (different start time or program) is not signalled")
    @MainActor
    func reusedPID() async {
        let control = FakeProcessControl([4242: identity("/opt/homebrew/bin/node", start: 9_999)])
        let model = makeModel(control: control)
        let outcome = await model.stop(port(4242, "node", 3000)) { _, _, _ in true }
        #expect(outcome == .refused(.processChanged))

        control.replace(4242, with: identity("/usr/libexec/rapportd"))
        let other = await model.stop(port(4242, "node", 3000)) { _, _, _ in true }
        #expect(other == .refused(.processChanged))
        #expect(control.signals.isEmpty)
    }

    @Test("PM-16: a process that already exited counts as stopped and is not signalled")
    @MainActor
    func alreadyGone() async {
        let control = FakeProcessControl([:])
        let model = makeModel(control: control)
        let outcome = await model.stop(port(4242, "node", 3000)) { _, _, _ in true }
        #expect(outcome == .stopped)
        #expect(control.signals.isEmpty)
    }

    @Test("PM-17: a signal the system refuses is reported, not retried")
    @MainActor
    func signalError() async {
        let control = FakeProcessControl([4242: identity("/opt/homebrew/bin/node")])
        control.sendErrors = [4242: EPERM]
        let model = makeModel(control: control)
        let outcome = await model.stop(port(4242, "node", 3000)) { _, _, _ in true }
        guard case .failed(let message) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(message.contains("node"))
        #expect(control.signals.count == 1)
    }

    // MARK: Model

    @Test("PM-18: refresh reads lsof through the runner; a pinned list never reads the machine")
    @MainActor
    func refreshAndPin() async {
        let control = FakeProcessControl([:])
        let model = makeModel(control: control, lsof: recordedLsof)
        await model.refreshNow()
        #expect(model.hasLoaded)
        #expect(model.ports.count == 6)
        #expect(model.errorMessage == nil)
        model.searchText = ":3000"
        #expect(model.filteredPorts.count == 2)

        let pinned = PortManagerModel(
            runner: { _, _ in
                Issue.record("a pinned model ran lsof")
                return nil
            },
            control: control
        )
        pinned.pin([port(4242, "node", 3000)])
        await pinned.refreshNow()
        #expect(pinned.ports.count == 1)
    }

    @Test("PM-19: lsof that cannot run shows an error instead of an empty list")
    @MainActor
    func refreshError() async {
        let model = PortManagerModel(runner: { _, _ in nil }, control: FakeProcessControl([:]), sleep: { _ in })
        await model.refreshNow()
        #expect(model.errorMessage != nil)
        #expect(model.ports.isEmpty)
    }

    @Test("PM-20: the real process control reads this test process and refuses PID 1 without signalling")
    func systemControlReadsOnly() {
        let control = SystemProcessControl()
        let me = control.identity(of: getpid())
        #expect(me?.uid == getuid())
        #expect(me?.executablePath?.hasPrefix("/") == true)
        #expect(control.identity(of: -5) == nil)
        // Signal 0 only checks; and PID 1 is refused before kill(2) is called.
        #expect(control.send(0, to: 1) == EPERM)
        #expect(control.send(0, to: getpid()) == 0)
    }
}
