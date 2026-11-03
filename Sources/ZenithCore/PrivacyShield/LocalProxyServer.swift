import Foundation
import Network

/// Lightweight native local proxy server that intercepts client requests, resolves targets via DoH,
/// and fragments TLS ClientHello handshakes to circumvent ISP DPI firewalls.
public final class LocalProxyServer: @unchecked Sendable {
    public static let shared = LocalProxyServer()

    private let lock = NSLock()
    private var _listener: NWListener?
    private var _isRunning: Bool = false
    private let queue = DispatchQueue(label: "com.zenith.privacyshield.proxy", qos: .userInitiated)
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var lastActivity: [ObjectIdentifier: Date] = [:]
    private var awaitingRequestHead: Set<ObjectIdentifier> = []
    private var startedTunnels: Set<ObjectIdentifier> = []
    private var sweepTimer: DispatchSourceTimer?

    /// Limits below are read from connection callbacks; tests lower them before calling `start`.
    /// Total open connections (each tunnel uses two: client side and upstream side).
    var maxConnections = 1024
    /// How long a client may take to send a complete request head before it is dropped.
    var requestHeaderTimeout: TimeInterval = 10
    /// How long an established connection may stay silent in both directions before it is closed.
    var idleTimeout: TimeInterval = 600

    private static let maxRequestHeadBytes = 16 * 1024
    private static let headTerminator = Data("\r\n\r\n".utf8)

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }
    private var _provider: DoHProvider = .cloudflare
    private var _port: UInt16 = 8080

    public var provider: DoHProvider {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _provider
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _provider = newValue
        }
    }

    public var port: UInt16 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _port
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _port = newValue
        }
    }

    private var _hasBeenReady = false
    private var _onUnexpectedStop: (@Sendable () -> Void)?

    /// Called when a listener that was already accepting connections fails on its own (not through `stop()`),
    /// so the owner can undo anything that depends on it, such as the system proxy.
    public var onUnexpectedStop: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onUnexpectedStop
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onUnexpectedStop = newValue
        }
    }

    public init() {}

    /// Starts listening on 127.0.0.1:<port>. Binding completes asynchronously; use `startAndAwaitReady`
    /// when something must only be wired up once the port is really accepting connections.
    public func start(port: UInt16 = 8080, provider: DoHProvider = .cloudflare) throws {
        try startListener(port: port, provider: provider, onTransition: nil)
    }

    /// Starts listening and returns only once the listener is bound and accepting connections.
    /// Throws (and leaves the server stopped) if the port is unavailable or binding takes longer than `timeout`.
    public func startAndAwaitReady(
        port: UInt16 = 8080,
        provider: DoHProvider = .cloudflare,
        timeout: TimeInterval = 3
    ) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = ReadinessGate(continuation)
                do {
                    try startListener(port: port, provider: provider) { gate.resolve($0) }
                } catch {
                    gate.resolve(.failure(error))
                    return
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    gate.resolve(.failure(NSError(
                        domain: "LocalProxyServer",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Proxy listener did not become ready on port \(port)"]
                    )))
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Resumes its continuation exactly once, whichever of ready / failed / timeout arrives first.
    private final class ReadinessGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resolve(_ result: Result<Void, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    private func startListener(
        port: UInt16,
        provider: DoHProvider,
        onTransition: (@Sendable (Result<Void, Error>) -> Void)?
    ) throws {
        lock.lock()
        if _isRunning {
            lock.unlock()
            onTransition?(.success(()))
            return
        }
        self._port = port
        self._provider = provider
        self._hasBeenReady = false
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "LocalProxyServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        let newListener = try NWListener(using: parameters, on: nwPort)
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            if case let .hostPort(remoteHost, _) = connection.endpoint {
                let hostStr = "\(remoteHost)".components(separatedBy: "%")[0].lowercased()
                let isLoopback = hostStr == "127.0.0.1" ||
                                 hostStr == "::1" ||
                                 hostStr == "localhost" ||
                                 hostStr == "::ffff:127.0.0.1" ||
                                 hostStr.hasPrefix("127.") ||
                                 hostStr.hasPrefix("::ffff:127.")
                guard isLoopback else {
                    NSLog("[PrivacyShield] Rejecting unauthorized non-loopback connection from %@", hostStr)
                    connection.cancel()
                    return
                }
            } else {
                connection.cancel()
                return
            }

            self.lock.lock()
            let isFull = self.activeConnections.count >= self.maxConnections
            self.lock.unlock()
            guard !isFull else {
                NSLog("[PrivacyShield] Rejecting connection: %d open connections", self.maxConnections)
                connection.cancel()
                return
            }
            self.handleInboundConnection(connection)
        }

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.lock.lock()
            switch state {
            case .ready:
                self._isRunning = true
                self._hasBeenReady = true
                self.lock.unlock()
                onTransition?(.success(()))
            case .failed(let error):
                let wasAccepting = self._hasBeenReady
                let onUnexpectedStop = self._onUnexpectedStop
                self.lock.unlock()
                NSLog("[PrivacyShield] Listener failed with error: \(error)")
                self.stop()
                onTransition?(.failure(error))
                if wasAccepting {
                    onUnexpectedStop?()
                }
            case .cancelled:
                self._isRunning = false
                self.lock.unlock()
                onTransition?(.failure(CancellationError()))
            default:
                self.lock.unlock()
            }
        }

        // Record the listener before starting it, so a bind failure reported on `queue` can always find and stop it.
        lock.lock()
        self._listener = newListener
        self._isRunning = true
        lock.unlock()
        newListener.start(queue: queue)
        startIdleSweep()
    }

    /// Stops listening and terminates all active connections.
    public func stop() {
        lock.lock()
        guard _isRunning || _listener != nil else {
            lock.unlock()
            return
        }
        let currentListener = _listener
        _listener = nil
        _isRunning = false

        let conns = Array(activeConnections.values)
        activeConnections.removeAll()
        lastActivity.removeAll()
        awaitingRequestHead.removeAll()
        startedTunnels.removeAll()
        let timer = sweepTimer
        sweepTimer = nil
        lock.unlock()

        timer?.cancel()
        currentListener?.cancel()
        for conn in conns {
            conn.cancel()
        }
    }

    // MARK: - Connection Lifetime Management

    private func registerConnection(_ conn: NWConnection) {
        lock.lock()
        let id = ObjectIdentifier(conn)
        activeConnections[id] = conn
        lastActivity[id] = Date()
        lock.unlock()
    }

    private func unregisterConnection(_ conn: NWConnection) {
        lock.lock()
        let id = ObjectIdentifier(conn)
        activeConnections.removeValue(forKey: id)
        lastActivity.removeValue(forKey: id)
        awaitingRequestHead.remove(id)
        startedTunnels.remove(id)
        lock.unlock()
    }

    private func isTunnelStarted(_ remoteConn: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedTunnels.contains(ObjectIdentifier(remoteConn))
    }

    private func closePair(_ conn1: NWConnection, _ conn2: NWConnection) {
        unregisterConnection(conn1)
        unregisterConnection(conn2)
        conn1.cancel()
        conn2.cancel()
    }

    private func touch(_ conn: NWConnection) {
        lock.lock()
        let id = ObjectIdentifier(conn)
        if lastActivity[id] != nil {
            lastActivity[id] = Date()
        }
        lock.unlock()
    }

    /// Periodically closes connections that have been silent for longer than `idleTimeout`.
    private func startIdleSweep() {
        let interval = min(30, max(0.05, idleTimeout / 4))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.closeIdleConnections()
        }
        lock.lock()
        let previous = sweepTimer
        sweepTimer = timer
        lock.unlock()
        previous?.cancel()
        timer.resume()
    }

    private func closeIdleConnections() {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        lock.lock()
        let staleIDs = activeConnections.keys.filter { (lastActivity[$0] ?? .distantPast) < cutoff }
        let stale = staleIDs.compactMap { activeConnections[$0] }
        for id in staleIDs {
            activeConnections.removeValue(forKey: id)
            lastActivity.removeValue(forKey: id)
        }
        lock.unlock()
        for conn in stale {
            conn.cancel()
        }
    }

    private func respondAndClose(_ clientConn: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        clientConn.send(
            content: Data(response.utf8),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.unregisterConnection(clientConn)
                clientConn.cancel()
            }
        )
    }

    // MARK: - Inbound Connection Routing

    private func handleInboundConnection(_ clientConn: NWConnection) {
        registerConnection(clientConn)
        clientConn.start(queue: queue)

        // A client that never finishes its request must not hold a connection slot forever.
        let id = ObjectIdentifier(clientConn)
        lock.lock()
        awaitingRequestHead.insert(id)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + requestHeaderTimeout) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let stillWaiting = self.awaitingRequestHead.remove(id) != nil
            self.lock.unlock()
            if stillWaiting {
                self.unregisterConnection(clientConn)
                clientConn.cancel()
            }
        }

        receiveRequestHead(clientConn, accumulated: Data())
    }

    /// Reads until the blank line that ends the request head, however many TCP segments it arrives in.
    private func receiveRequestHead(_ clientConn: NWConnection, accumulated: Data) {
        clientConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard error == nil, let data = data, !data.isEmpty else {
                self.unregisterConnection(clientConn)
                clientConn.cancel()
                return
            }

            self.touch(clientConn)
            var buffer = accumulated
            buffer.append(data)

            if let terminator = buffer.range(of: Self.headTerminator) {
                self.lock.lock()
                let stillWaiting = self.awaitingRequestHead.remove(ObjectIdentifier(clientConn)) != nil
                self.lock.unlock()
                guard stillWaiting else { return } // already dropped by the head timeout

                let head = Data(buffer[..<terminator.lowerBound])
                let leftover = Data(buffer[terminator.upperBound...])
                self.routeRequest(head: head, leftover: leftover, clientEnded: isComplete, clientConn: clientConn)
            } else if buffer.count > Self.maxRequestHeadBytes {
                self.respondAndClose(clientConn, status: "431 Request Header Fields Too Large")
            } else {
                self.receiveRequestHead(clientConn, accumulated: buffer)
            }
        }
    }

    /// `clientEnded` means the client already sent its end-of-stream along with this data; the connection must not be
    /// read again, only its end passed on.
    private func routeRequest(head: Data, leftover: Data, clientEnded: Bool, clientConn: NWConnection) {
        // ISO Latin-1 maps every byte to one character, so header bytes survive the round trip unchanged.
        let headString = String(data: head, encoding: .isoLatin1) ?? ""
        if headString.hasPrefix("CONNECT ") {
            handleConnectRequest(requestString: headString, leftover: leftover, clientEnded: clientEnded, clientConn: clientConn)
        } else {
            handlePlainHttpRequest(headString: headString, leftover: leftover, clientEnded: clientEnded, clientConn: clientConn)
        }
    }

    public static func isPermittedTarget(resolvedIP: String, targetPort: UInt16, proxyPort: UInt16) -> Bool {
        let cleanIP = resolvedIP.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()

        // 1. Strict loopback guard on proxy port (prevent recursive proxy connection loop / DoS)
        if targetPort == proxyPort {
            if cleanIP == "127.0.0.1" ||
               cleanIP == "::1" ||
               cleanIP == "0.0.0.0" ||
               cleanIP == "::" ||
               cleanIP == "localhost" ||
               cleanIP.hasPrefix("127.") ||
               cleanIP.hasPrefix("::ffff:127.") {
                return false
            }
        }

        // 2. Block Cloud metadata service & IPv4 Link-Local (SSRF protection)
        // Blocks 169.254.169.254 (AWS/Azure/GCP/OpenStack IMDS), 169.254.170.2 (AWS ECS),
        // all IPv4 link-local (169.254.0.0/16), IPv6 link-local metadata (fd00:ec2::254)
        if cleanIP == "169.254.169.254" ||
           cleanIP.hasPrefix("169.254.") ||
           cleanIP.hasPrefix("::ffff:169.254.") ||
           cleanIP == "fd00:ec2::254" {
            return false
        }

        return true
    }

    /// Splits "host", "host:port" or "[v6]:port" into host and port; an unparsable port falls back to `defaultPort`.
    static func parseHostPort(_ value: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), let closingBracket = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            var port = defaultPort
            let afterBracket = trimmed[closingBracket...]
            if let colonIndex = afterBracket.firstIndex(of: ":") {
                port = UInt16(afterBracket[afterBracket.index(after: colonIndex)...]) ?? defaultPort
            }
            return host.isEmpty ? nil : (host, port)
        }
        let components = trimmed.components(separatedBy: ":")
        let host = components[0]
        let port = components.count > 1 ? (UInt16(components[1]) ?? defaultPort) : defaultPort
        return host.isEmpty ? nil : (host, port)
    }

    /// True for hosts that name this machine, used to refuse requests that would loop back into the proxy.
    private static func isLocalHostName(_ host: String) -> Bool {
        let clean = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return clean == "127.0.0.1" ||
               clean == "localhost" ||
               clean == "::1" ||
               clean == "0.0.0.0" ||
               clean == "::" ||
               clean.hasPrefix("127.") ||
               clean.hasPrefix("::ffff:127.")
    }

    // MARK: - HTTPS CONNECT Tunnel Handling

    private func handleConnectRequest(requestString: String, leftover: Data, clientEnded: Bool, clientConn: NWConnection) {
        // Parse host and port from "CONNECT domain.com:443 HTTP/1.1" or "CONNECT [::1]:8080 HTTP/1.1"
        let parts = requestString.components(separatedBy: " ")
        guard parts.count >= 2, let (targetHost, targetPortRaw) = Self.parseHostPort(parts[1], defaultPort: 443) else {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        guard let targetPort = NWEndpoint.Port(rawValue: targetPortRaw) else {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        // Pre-resolution loop guard: prevent connection to the local proxy itself
        if Self.isLocalHostName(targetHost) && targetPortRaw == self.port {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let startTime = Date()
                let resolvedIP = try await DoHResolver.shared.resolve(domain: targetHost, provider: self.provider)
                let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

                // Post-resolution security validation:
                guard Self.isPermittedTarget(resolvedIP: resolvedIP, targetPort: targetPortRaw, proxyPort: self.port) else {
                    NSLog("[PrivacyShield] Prohibited connection to port %d", targetPortRaw)
                    Task { @MainActor in
                        PrivacyShieldStatistics.shared.recordFailedRequest(
                            domain: targetHost,
                            port: targetPortRaw,
                            protocolType: "HTTPS"
                        )
                    }
                    self.respondAndClose(clientConn, status: "403 Forbidden")
                    return
                }

                await MainActor.run {
                    PrivacyShieldStatistics.shared.updateLatency(elapsedMs)
                }

                // Connect to remote destination bypassing system proxies to prevent infinite loop
                let remoteEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(resolvedIP), port: targetPort)
                let tcpParams = NWParameters.tcp
                tcpParams.preferNoProxies = true
                let remoteConn = NWConnection(to: remoteEndpoint, using: tcpParams)
                self.registerConnection(remoteConn)

                remoteConn.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    if case .ready = state {
                        // Respond 200 Connection Established to client
                        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
                        clientConn.send(
                            content: response.data(using: .utf8),
                            contentContext: .defaultMessage,
                            isComplete: false,
                            completion: .contentProcessed { [weak self] sendError in
                                if sendError == nil {
                                    self?.beginMangledTunnel(
                                        clientConn: clientConn,
                                        remoteConn: remoteConn,
                                        domain: targetHost,
                                        port: targetPortRaw,
                                        resolvedIP: resolvedIP,
                                        initialPayload: leftover,
                                        clientEnded: clientEnded
                                    )
                                } else {
                                    self?.closePair(clientConn, remoteConn)
                                }
                            }
                        )
                    } else if case .failed = state {
                        // Once data is flowing the pipes end the tunnel themselves, after the bytes already received
                        // from upstream have been written to the client; cancelling here would drop them.
                        if !self.isTunnelStarted(remoteConn) {
                            self.closePair(clientConn, remoteConn)
                        }
                    }
                }

                remoteConn.start(queue: self.queue)
            } catch {
                // Log the error class only: its description can embed the queried hostname.
                NSLog("[PrivacyShield] DoH resolution failed (code %d)", (error as NSError).code)
                Task { @MainActor in
                    PrivacyShieldStatistics.shared.recordFailedRequest(
                        domain: targetHost,
                        port: targetPortRaw,
                        protocolType: "HTTPS"
                    )
                }
                self.respondAndClose(clientConn, status: "502 Bad Gateway")
            }
        }
    }

    // MARK: - Plain HTTP Request Handling (Port 80 / OCSP / Captive / Redirects)

    /// Rewrites a proxy-form request into the origin-form request an origin server expects.
    ///
    /// The upstream connection is dedicated to this one request (`Connection: close`), so a client that reuses its
    /// proxy connection for a different host gets a fresh upstream instead of having its bytes sent to the first host.
    /// Header bytes are preserved exactly and any body bytes already read are appended unchanged.
    static func rewritePlainHttpRequest(headString: String, leftover: Data) -> (host: String, port: UInt16, payload: Data)? {
        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }

        let method = parts[0]
        let uri = parts[1]
        let version = parts.count > 2 ? parts[2] : "HTTP/1.1"
        let headerLines = lines.dropFirst().filter { !$0.isEmpty }

        func headerName(_ line: String) -> String {
            (line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }

        var authority: String?
        var originPath = uri
        if uri.lowercased().hasPrefix("http://") {
            let rest = String(uri.dropFirst(7))
            let pathStart = rest.firstIndex(where: { $0 == "/" || $0 == "?" })
            var rawAuthority = pathStart.map { String(rest[..<$0]) } ?? rest
            if let at = rawAuthority.lastIndex(of: "@") {
                rawAuthority = String(rawAuthority[rawAuthority.index(after: at)...])
            }
            authority = rawAuthority
            let path = pathStart.map { String(rest[$0...]) } ?? "/"
            originPath = path.hasPrefix("?") ? "/" + path : path
        } else if let hostLine = headerLines.first(where: { headerName($0) == "host" }) {
            authority = String(hostLine.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        guard let authority = authority, let target = parseHostPort(authority, defaultPort: 80) else { return nil }

        // An upgraded connection (e.g. WebSocket) is dedicated to its origin anyway, so keep its handshake headers.
        let isUpgrade = headerLines.contains { headerName($0) == "upgrade" }
        let hopByHop: Set<String> = isUpgrade
            ? ["proxy-connection", "proxy-authorization"]
            : ["proxy-connection", "proxy-authorization", "connection", "keep-alive"]

        var forwarded = headerLines.filter { !hopByHop.contains(headerName($0)) }
        if !forwarded.contains(where: { headerName($0) == "host" }) {
            forwarded.insert("Host: \(authority)", at: 0)
        }
        if !isUpgrade {
            forwarded.append("Connection: close")
        }

        let head = ([ "\(method) \(originPath) \(version)" ] + forwarded).joined(separator: "\r\n") + "\r\n\r\n"
        var payload = head.data(using: .isoLatin1) ?? Data(head.utf8)
        payload.append(leftover)
        return (target.host, target.port, payload)
    }

    private func handlePlainHttpRequest(headString: String, leftover: Data, clientEnded: Bool, clientConn: NWConnection) {
        guard let request = Self.rewritePlainHttpRequest(headString: headString, leftover: leftover),
              let nwPort = NWEndpoint.Port(rawValue: request.port) else {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        let host = request.host
        let resolvedPort = request.port
        let payload = request.payload

        // Pre-resolution loop guard: prevent connection to the local proxy itself
        if Self.isLocalHostName(host) && resolvedPort == self.port {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let resolvedIP = try await DoHResolver.shared.resolve(domain: host, provider: self.provider)

                // Post-resolution security validation:
                guard Self.isPermittedTarget(resolvedIP: resolvedIP, targetPort: resolvedPort, proxyPort: self.port) else {
                    NSLog("[PrivacyShield] Prohibited connection to port %d", resolvedPort)
                    Task { @MainActor in
                        PrivacyShieldStatistics.shared.recordFailedRequest(
                            domain: host,
                            port: resolvedPort,
                            protocolType: "HTTP"
                        )
                    }
                    self.respondAndClose(clientConn, status: "403 Forbidden")
                    return
                }

                let remoteEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(resolvedIP), port: nwPort)
                let tcpParams = NWParameters.tcp
                tcpParams.preferNoProxies = true
                let remoteConn = NWConnection(to: remoteEndpoint, using: tcpParams)
                self.registerConnection(remoteConn)

                remoteConn.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    if case .ready = state {
                        remoteConn.send(
                            content: payload,
                            contentContext: .defaultMessage,
                            isComplete: false,
                            completion: .contentProcessed { [weak self] sendError in
                                if sendError == nil {
                                    Task { @MainActor in
                                        PrivacyShieldStatistics.shared.recordProtectedRequest(
                                            domain: host,
                                            bytes: Int64(payload.count),
                                            chunkSize: 0,
                                            port: resolvedPort,
                                            protocolType: "HTTP",
                                            resolvedIP: resolvedIP,
                                            status: .plain
                                        )
                                    }
                                    self?.startPiping(clientConn: clientConn, remoteConn: remoteConn, clientEnded: clientEnded, state: TunnelState())
                                } else {
                                    self?.closePair(clientConn, remoteConn)
                                }
                            }
                        )
                    } else if case .failed = state {
                        // Once data is flowing the pipes end the tunnel themselves, after the bytes already received
                        // from upstream have been written to the client; cancelling here would drop them.
                        if !self.isTunnelStarted(remoteConn) {
                            self.closePair(clientConn, remoteConn)
                        }
                    }
                }
                remoteConn.start(queue: self.queue)
            } catch {
                NSLog("[PrivacyShield] DoH resolution failed (code %d)", (error as NSError).code)
                Task { @MainActor in
                    PrivacyShieldStatistics.shared.recordFailedRequest(
                        domain: host,
                        port: resolvedPort,
                        protocolType: "HTTP"
                    )
                }
                self.respondAndClose(clientConn, status: "502 Bad Gateway")
            }
        }
    }

    // MARK: - DPI Bypass Mangled Tunnel

    private func beginMangledTunnel(
        clientConn: NWConnection,
        remoteConn: NWConnection,
        domain: String,
        port: UInt16 = 443,
        resolvedIP: String? = nil,
        initialPayload: Data = Data(),
        clientEnded: Bool = false
    ) {
        // Bytes the client sent right behind its CONNECT are already in hand; otherwise wait for the first payload.
        if !initialPayload.isEmpty {
            forwardFirstPayload(initialPayload, clientEnded: clientEnded, clientConn: clientConn, remoteConn: remoteConn, domain: domain, port: port, resolvedIP: resolvedIP)
            return
        }
        if clientEnded {
            closePair(clientConn, remoteConn)
            return
        }

        // Read the first payload from client (TLS ClientHello)
        clientConn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, _ in
            guard let self = self, let data = data, !data.isEmpty else {
                self?.closePair(clientConn, remoteConn)
                return
            }
            self.forwardFirstPayload(data, clientEnded: isComplete, clientConn: clientConn, remoteConn: remoteConn, domain: domain, port: port, resolvedIP: resolvedIP)
        }
    }

    private func forwardFirstPayload(
        _ data: Data,
        clientEnded: Bool,
        clientConn: NWConnection,
        remoteConn: NWConnection,
        domain: String,
        port: UInt16,
        resolvedIP: String?
    ) {
        touch(clientConn)
        let chunkResult = TLSClientHelloChunker.chunkPayload(data)
        let state = TunnelState()

        if chunkResult.isTLSClientHello, let secondChunk = chunkResult.secondChunk {
            // Mangled DPI bypass: send chunk 1, delay, then chunk 2
            remoteConn.send(
                content: chunkResult.firstChunk,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak self] firstError in
                    guard let self = self, firstError == nil else {
                        self?.closePair(clientConn, remoteConn)
                        return
                    }

                    // 5ms inter-chunk delay to guarantee separate TCP packet transmission
                    self.queue.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                        remoteConn.send(
                            content: secondChunk,
                            contentContext: .defaultMessage,
                            isComplete: false,
                            completion: .contentProcessed { [weak self] secondError in
                                guard let self = self, secondError == nil else {
                                    self?.closePair(clientConn, remoteConn)
                                    return
                                }

                                Task { @MainActor in
                                    PrivacyShieldStatistics.shared.recordProtectedRequest(
                                        domain: domain,
                                        bytes: Int64(data.count),
                                        chunkSize: chunkResult.firstChunk.count,
                                        port: port,
                                        protocolType: "HTTPS",
                                        resolvedIP: resolvedIP,
                                        status: .shielded
                                    )
                                }

                                // Enter transparent bidirectional streaming
                                self.startPiping(clientConn: clientConn, remoteConn: remoteConn, clientEnded: clientEnded, state: state)
                            }
                        )
                    }
                }
            )
        } else {
            // Non-ClientHello payload: send as-is
            remoteConn.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak self] sendError in
                    guard let self = self, sendError == nil else {
                        self?.closePair(clientConn, remoteConn)
                        return
                    }
                    Task { @MainActor in
                        PrivacyShieldStatistics.shared.recordProtectedRequest(
                            domain: domain,
                            bytes: Int64(data.count),
                            chunkSize: 0,
                            port: port,
                            protocolType: "HTTPS",
                            resolvedIP: resolvedIP,
                            status: .plain
                        )
                    }
                    self.startPiping(clientConn: clientConn, remoteConn: remoteConn, clientEnded: clientEnded, state: state)
                }
            )
        }
    }

    // MARK: - Bidirectional Streaming Pipe

    /// Starts both directions of a tunnel. A client that already sent its end-of-stream is not read again
    /// (a second read after EOF fails and would tear the tunnel down before the response arrives).
    private func startPiping(clientConn: NWConnection, remoteConn: NWConnection, clientEnded: Bool, state: TunnelState) {
        lock.lock()
        startedTunnels.insert(ObjectIdentifier(remoteConn))
        lock.unlock()
        if clientEnded {
            finishDirection(from: clientConn, to: remoteConn, state: state)
        } else {
            pipe(from: clientConn, to: remoteConn, state: state)
        }
        pipe(from: remoteConn, to: clientConn, state: state)
    }

    /// Counts the directions of one tunnel that have reached end-of-stream.
    private final class TunnelState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = 0

        /// Records one finished direction; returns `true` once both have finished.
        func finishDirection() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            finished += 1
            return finished >= 2
        }
    }

    private func pipe(from source: NWConnection, to destination: NWConnection, state: TunnelState) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                self.closePair(source, destination)
                return
            }
            self.touch(source)

            if let data = data, !data.isEmpty {
                destination.send(
                    content: data,
                    contentContext: .defaultMessage,
                    isComplete: false,
                    completion: .contentProcessed { [weak self] sendError in
                        guard let self = self, sendError == nil else {
                            self?.closePair(source, destination)
                            return
                        }
                        self.touch(destination)
                        if isComplete {
                            self.finishDirection(from: source, to: destination, state: state)
                        } else {
                            self.pipe(from: source, to: destination, state: state)
                        }
                    }
                )
            } else if isComplete {
                self.finishDirection(from: source, to: destination, state: state)
            } else {
                self.closePair(source, destination)
            }
        }
    }

    /// Passes end-of-stream to the peer. The opposite direction keeps flowing (half-close) until it ends too,
    /// so a client that finishes sending still receives the whole response.
    private func finishDirection(from source: NWConnection, to destination: NWConnection, state: TunnelState) {
        destination.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                if state.finishDirection() {
                    self?.closePair(source, destination)
                }
            }
        )
    }
}
