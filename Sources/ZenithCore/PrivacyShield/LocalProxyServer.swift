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

    public init() {}

    /// Starts listening on 127.0.0.1:<port>.
    public func start(port: UInt16 = 8080, provider: DoHProvider = .cloudflare) throws {
        lock.lock()
        if _isRunning {
            lock.unlock()
            return
        }
        self._port = port
        self._provider = provider
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
            self.handleInboundConnection(connection)
        }

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.lock.lock()
            switch state {
            case .ready:
                self._isRunning = true
                self.lock.unlock()
            case .failed(let error):
                self.lock.unlock()
                NSLog("[PrivacyShield] Listener failed with error: \(error)")
                self.stop()
            case .cancelled:
                self._isRunning = false
                self.lock.unlock()
            default:
                self.lock.unlock()
            }
        }

        newListener.start(queue: queue)
        lock.lock()
        self._listener = newListener
        self._isRunning = true
        lock.unlock()
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
        lock.unlock()

        currentListener?.cancel()
        for conn in conns {
            conn.cancel()
        }
    }

    // MARK: - Connection Lifetime Management

    private func registerConnection(_ conn: NWConnection) {
        lock.lock()
        activeConnections[ObjectIdentifier(conn)] = conn
        lock.unlock()
    }

    private func unregisterConnection(_ conn: NWConnection) {
        lock.lock()
        activeConnections.removeValue(forKey: ObjectIdentifier(conn))
        lock.unlock()
    }

    private func closePair(_ conn1: NWConnection, _ conn2: NWConnection) {
        lock.lock()
        activeConnections.removeValue(forKey: ObjectIdentifier(conn1))
        activeConnections.removeValue(forKey: ObjectIdentifier(conn2))
        lock.unlock()
        conn1.cancel()
        conn2.cancel()
    }

    // MARK: - Inbound Connection Routing

    private func handleInboundConnection(_ clientConn: NWConnection) {
        registerConnection(clientConn)
        clientConn.start(queue: queue)

        // Read initial HTTP request (CONNECT or plain HTTP)
        clientConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, context, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                self?.unregisterConnection(clientConn)
                clientConn.cancel()
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                self.unregisterConnection(clientConn)
                clientConn.cancel()
                return
            }

            if requestString.hasPrefix("CONNECT ") {
                self.handleConnectRequest(requestString: requestString, clientConn: clientConn)
            } else {
                self.handlePlainHttpRequest(data: data, requestString: requestString, clientConn: clientConn)
            }
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

    // MARK: - HTTPS CONNECT Tunnel Handling

    private func handleConnectRequest(requestString: String, clientConn: NWConnection) {
        // Parse host and port from "CONNECT domain.com:443 HTTP/1.1" or "CONNECT [::1]:8080 HTTP/1.1"
        let parts = requestString.components(separatedBy: " ")
        guard parts.count >= 2 else {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        let hostPort = parts[1]
        let targetHost: String
        let targetPortRaw: UInt16

        if hostPort.hasPrefix("["), let closingBracket = hostPort.firstIndex(of: "]") {
            targetHost = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closingBracket])
            let afterBracket = hostPort[closingBracket...]
            if let colonIndex = afterBracket.firstIndex(of: ":") {
                let portSubstring = afterBracket[afterBracket.index(after: colonIndex)...]
                targetPortRaw = UInt16(portSubstring) ?? 443
            } else {
                targetPortRaw = 443
            }
        } else {
            let hostComponents = hostPort.components(separatedBy: ":")
            targetHost = hostComponents[0]
            targetPortRaw = hostComponents.count > 1 ? (UInt16(hostComponents[1]) ?? 443) : 443
        }

        guard let targetPort = NWEndpoint.Port(rawValue: targetPortRaw) else {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        // Pre-resolution loop guard: prevent connection to the local proxy itself
        let cleanTargetHost = targetHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if (cleanTargetHost == "127.0.0.1" ||
            cleanTargetHost == "localhost" ||
            cleanTargetHost == "::1" ||
            cleanTargetHost == "0.0.0.0" ||
            cleanTargetHost == "::" ||
            cleanTargetHost.hasPrefix("127.") ||
            cleanTargetHost.hasPrefix("::ffff:127.")) && targetPortRaw == self.port {
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
                    NSLog("[PrivacyShield] Prohibited connection to %@ -> %@:%d", targetHost, resolvedIP, targetPortRaw)
                    Task { @MainActor in
                        PrivacyShieldStatistics.shared.recordFailedRequest(
                            domain: targetHost,
                            port: targetPortRaw,
                            protocolType: "HTTPS"
                        )
                    }
                    let failureResponse = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
                    clientConn.send(
                        content: failureResponse.data(using: .utf8),
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
                            self?.unregisterConnection(clientConn)
                            clientConn.cancel()
                        }
                    )
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
                                        resolvedIP: resolvedIP
                                    )
                                } else {
                                    self?.closePair(clientConn, remoteConn)
                                }
                            }
                        )
                    } else if case .failed = state {
                        self.closePair(clientConn, remoteConn)
                    }
                }

                remoteConn.start(queue: self.queue)
            } catch {
                NSLog("[PrivacyShield] DoH resolution failed for \(targetHost): \(error)")
                Task { @MainActor in
                    PrivacyShieldStatistics.shared.recordFailedRequest(
                        domain: targetHost,
                        port: targetPortRaw,
                        protocolType: "HTTPS"
                    )
                }
                let failureResponse = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
                clientConn.send(
                    content: failureResponse.data(using: .utf8),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] _ in
                        self?.unregisterConnection(clientConn)
                        clientConn.cancel()
                    }
                )
            }
        }
    }

    // MARK: - Plain HTTP Request Handling (Port 80 / OCSP / Captive / Redirects)

    private func handlePlainHttpRequest(data: Data, requestString: String, clientConn: NWConnection) {
        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        let uri = parts[1]
        var targetHost: String? = nil
        var targetPort: UInt16 = 80

        if uri.hasPrefix("http://") {
            let withoutScheme = String(uri.dropFirst(7))
            let hostAndPath = withoutScheme.components(separatedBy: "/")
            let hostPort = hostAndPath[0]
            if hostPort.hasPrefix("["), let closingBracket = hostPort.firstIndex(of: "]") {
                targetHost = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closingBracket])
                let afterBracket = hostPort[closingBracket...]
                if let colonIndex = afterBracket.firstIndex(of: ":") {
                    let portSubstring = afterBracket[afterBracket.index(after: colonIndex)...]
                    targetPort = UInt16(portSubstring) ?? 80
                }
            } else {
                let hostComponents = hostPort.components(separatedBy: ":")
                targetHost = hostComponents[0]
                if hostComponents.count > 1, let p = UInt16(hostComponents[1]) {
                    targetPort = p
                }
            }
        } else {
            for line in lines.dropFirst() {
                if line.lowercased().hasPrefix("host:") {
                    let hostVal = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if hostVal.hasPrefix("["), let closingBracket = hostVal.firstIndex(of: "]") {
                        targetHost = String(hostVal[hostVal.index(after: hostVal.startIndex)..<closingBracket])
                        let afterBracket = hostVal[closingBracket...]
                        if let colonIndex = afterBracket.firstIndex(of: ":") {
                            let portSubstring = afterBracket[afterBracket.index(after: colonIndex)...]
                            targetPort = UInt16(portSubstring) ?? 80
                        }
                    } else {
                        let hostComponents = hostVal.components(separatedBy: ":")
                        targetHost = hostComponents[0]
                        if hostComponents.count > 1, let p = UInt16(hostComponents[1]) {
                            targetPort = p
                        }
                    }
                    break
                }
            }
        }

        guard let host = targetHost, !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: targetPort) else {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        // Pre-resolution loop guard: prevent connection to the local proxy itself
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if (cleanHost == "127.0.0.1" ||
            cleanHost == "localhost" ||
            cleanHost == "::1" ||
            cleanHost == "0.0.0.0" ||
            cleanHost == "::" ||
            cleanHost.hasPrefix("127.") ||
            cleanHost.hasPrefix("::ffff:127.")) && targetPort == self.port {
            unregisterConnection(clientConn)
            clientConn.cancel()
            return
        }

        let resolvedPort = targetPort

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let resolvedIP = try await DoHResolver.shared.resolve(domain: host, provider: self.provider)

                // Post-resolution security validation:
                guard Self.isPermittedTarget(resolvedIP: resolvedIP, targetPort: resolvedPort, proxyPort: self.port) else {
                    NSLog("[PrivacyShield] Prohibited connection to %@ -> %@:%d", host, resolvedIP, resolvedPort)
                    Task { @MainActor in
                        PrivacyShieldStatistics.shared.recordFailedRequest(
                            domain: host,
                            port: resolvedPort,
                            protocolType: "HTTP"
                        )
                    }
                    let failureResponse = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
                    clientConn.send(
                        content: failureResponse.data(using: .utf8),
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
                            self?.unregisterConnection(clientConn)
                            clientConn.cancel()
                        }
                    )
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
                            content: data,
                            contentContext: .defaultMessage,
                            isComplete: false,
                            completion: .contentProcessed { [weak self] sendError in
                                if sendError == nil {
                                    Task { @MainActor in
                                        PrivacyShieldStatistics.shared.recordProtectedRequest(
                                            domain: host,
                                            bytes: Int64(data.count),
                                            chunkSize: 0,
                                            port: resolvedPort,
                                            protocolType: "HTTP",
                                            resolvedIP: resolvedIP,
                                            status: .plain
                                        )
                                    }
                                    self?.pipe(from: clientConn, to: remoteConn)
                                    self?.pipe(from: remoteConn, to: clientConn)
                                } else {
                                    self?.closePair(clientConn, remoteConn)
                                }
                            }
                        )
                    } else if case .failed = state {
                        self.closePair(clientConn, remoteConn)
                    }
                }
                remoteConn.start(queue: self.queue)
            } catch {
                Task { @MainActor in
                    PrivacyShieldStatistics.shared.recordFailedRequest(
                        domain: host,
                        port: resolvedPort,
                        protocolType: "HTTP"
                    )
                }
                let failureResponse = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
                clientConn.send(
                    content: failureResponse.data(using: .utf8),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] _ in
                        self?.unregisterConnection(clientConn)
                        clientConn.cancel()
                    }
                )
            }
        }
    }

    // MARK: - DPI Bypass Mangled Tunnel

    private func beginMangledTunnel(
        clientConn: NWConnection,
        remoteConn: NWConnection,
        domain: String,
        port: UInt16 = 443,
        resolvedIP: String? = nil
    ) {
        // Read the first payload from client (TLS ClientHello)
        clientConn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, context, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                self?.closePair(clientConn, remoteConn)
                return
            }

            let chunkResult = TLSClientHelloChunker.chunkPayload(data)

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
                                    self.pipe(from: clientConn, to: remoteConn)
                                    self.pipe(from: remoteConn, to: clientConn)
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
                        self.pipe(from: clientConn, to: remoteConn)
                        self.pipe(from: remoteConn, to: clientConn)
                    }
                )
            }
        }
    }

    // MARK: - Bidirectional Streaming Pipe

    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                destination.send(
                    content: data,
                    contentContext: .defaultMessage,
                    isComplete: isComplete,
                    completion: .contentProcessed { [weak self] sendError in
                        if sendError == nil && !isComplete {
                            self?.pipe(from: source, to: destination)
                        } else {
                            self?.closePair(source, destination)
                        }
                    }
                )
            } else if isComplete {
                destination.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] _ in
                        self?.closePair(source, destination)
                    }
                )
            } else {
                self.closePair(source, destination)
            }
        }
    }
}
