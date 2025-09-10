//
//  ExtWSClient.swift
//  ExtWSClient
//
//  Created by d.kotina on 15.08.2025.
//

import Foundation
import Network
import UIKit
import Logging

// MARK: - Error UserInfo Keys

/// Ключи для расширения `NSError.userInfo`, используемые клиентом ExtWS.
public enum ExtWSErrorKey {
    /// Ключ для хранения `HTTPURLResponse` в `userInfo` ошибки апгрейда/рукопожатия.
    public static let httpResponse = "extws.httpResponse"
}

// MARK: - ExtWSClient

/// Высокоуровневый WebSocket-клиент на базе `URLSessionWebSocketTask`.
///
/// Отвечает за:
/// 1) управление жизненным циклом соединения (подключение/закрытие/переподключение с backoff),
/// 2) маршрутизацию входящих сообщений (текст/бинарные, сырые кадры и выделенные кадры ping/pong),
/// 3) проактивный клиентский PING по расписанию,
/// 4) учёт сетевой доступности (`NWPathMonitor`) и переходов приложения фон/фореграунд.
///
/// Потокобезопасность:
/// - Все публичные методы (`connect`, `disconnect`, `send`, `sendPingNow`, `sendPongNow`,
///   `updateClientPingInterval`) сериализуются внутренней очередью `queue`.
/// - Колбэки транспорта перепрыгивают на внутреннюю очередь перед обработкой.
///
/// Интеграционные хуки:
/// - `beforeConnect`: позволяет модифицировать `URLRequest` перед установкой соединения
///   (например, добавить заголовки/куки/подписи). Выполняется асинхронно и блокирует
///   старт подключения до завершения.
/// - `onUpgradeError`: вызывается при ошибке апгрейда (например, `401`), даёт возможность
///   приложению самостоятельно обработать ситуацию (вернуть `true`). Если обработано,
///   автопереподключение не запускается.
public final class ExtWSClient: @unchecked Sendable {

    // MARK: - Callbacks (public)

    public var onStateChange: (@Sendable (ExtWSState) -> Void)?
    public var onText: (@Sendable (String) -> Void)?
    public var onBinary: (@Sendable (Data) -> Void)?
    public var onConnect: (@Sendable () -> Void)?
    public var onDisconnect: (@Sendable (_ code: URLSessionWebSocketTask.CloseCode?, _ error: Error?) -> Void)?
    public var beforeConnect: (@Sendable (_ request: URLRequest) async -> URLRequest)?
    public var onUpgradeError: (@Sendable (HTTPURLResponse) -> Void)?
    public var onFrame: (@Sendable (Frame) -> Void)?
    public var onMessage: (@Sendable (_ payload: String) -> Void)?

    // MARK: - Configuration & Transport

    private let config: ExtWSConfig
    private let transport: WebSocketTransport
    private var logger: Logger

    // MARK: - Serial queue

    private let queue = DispatchQueue(label: "extws.core", qos: .userInitiated)

    // MARK: - State

    private var state: ExtWSState = .idle {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    private var shouldStayConnected = false
    private var backoff: TimeInterval
    private var sendQueue: [String] = []
    private var pathMonitor: NWPathMonitor?
    private var isNetworkAvailable = true
#if DEBUG
    private var testNetworkOverride: Bool?
#endif

    private var pingTimer: DispatchSourceTimer?

    // MARK: - Reconnect control

    private var reconnectTimer: DispatchSourceTimer?
    private var connectNonce: UInt64 = 0

    private var isConnectingOrOpen: Bool {
        switch state {
            case .connecting, .open, .retrying, .waitingNetwork:
                return true
            default:
                return false
        }
    }

    // MARK: - Init

    public init(
        config: ExtWSConfig,
        transport: WebSocketTransport = URLSessionWSTransport(),
        logger: Logger = Logger(label: "ExtWSClient")
    ) {
        self.config = config
        self.transport = transport
        self.backoff = config.initialBackoff
        self.logger = logger

        setupTransportCallbacks()
        setupReachability()
        setupLifecycle()
    }

    deinit {
        stopReachability()
        invalidatePingTimer()
        cancelReconnectTimer()
    }

    // MARK: - Public API
    public func connect() {
        queue.async {
            self.logger.info("WS запрошено подключение (текущий статус: \(self.state))")

            guard !self.isConnectingOrOpen else {
                self.logger.info("WS подключение проигнорировано (текущий статус: \(self.state))")
                self.shouldStayConnected = true
                return
            }

            self.shouldStayConnected = true
            self.openNow()
        }
    }

    public func disconnect() {
        queue.async {
            self.logger.info("WS запрошено отключение")
            self.shouldStayConnected = false
            self.cancelReconnectTimer()
            self.connectNonce &+= 1
            self.state = .closing
            self.transport.close(code: .normalClosure, reason: nil)
        }
    }

    public func send(_ text: String) {
        queue.async {
            if case .open = self.state {
                self.transport.send(text: text) { [weak self] error in
                    if let error {
                        self?.logger.error("WS ошибка отправки: \(error.localizedDescription)")
                    }
                }
            } else {
                self.sendQueue.append(text)
            }
        }
    }

    public func sendPingNow() {
        send(config.pingPong.pingFrame)
    }

    public func sendPongNow() {
        send(config.pingPong.pongFrame)
    }

    public func updateClientPingInterval(_ interval: TimeInterval?) {
        queue.async {
            self.schedulePingIfNeeded(interval: interval)
        }
    }

    // MARK: - Connection lifecycle
    private func openNow() {
#if DEBUG
        let netUp = testNetworkOverride ?? isNetworkAvailable
#else
        let netUp = isNetworkAvailable
#endif
        guard netUp else {
            state = .waitingNetwork
            logger.warning("WS waiting network")
            return
        }

        guard !isConnectingOrOpen else { return }
        cancelReconnectTimer()
        connectNonce &+= 1

        state = .connecting

        var req = URLRequest(url: config.url, timeoutInterval: 30)

        if let bc = beforeConnect {
            let sem = DispatchSemaphore(value: 0)
            var modified = req

            Task {
                modified = await bc(req)
                sem.signal()
            }

            let timeout: DispatchTime = .now() + .seconds(8)

            if sem.wait(timeout: timeout) == .timedOut {
                logger.warning("beforeConnect timeout — отменяем попытку и попробуем позже")
                state = .closed
                    if shouldStayConnected {
                        scheduleReconnect()
                    }

                return
            }

            req = modified
        }

        logConnectRequest(req)
        transport.connect(request: req)
    }

    private func setupTransportCallbacks() {
        transport.onOpen = { [weak self] in
            guard let self else { return }
            let client = self
            let q = self.queue

            q.async { [client] in
                client.setupOnOpen()
            }
        }

        transport.onText = { [weak self] text in
            guard let self else { return }
            let client = self
            let payload = text
            let q = self.queue
            q.async { [client] in
                client.handleIncoming(text: payload)
            }
        }

        transport.onBinary = { [weak self] data in
            guard let self else { return }
            let client = self
            let bytes = data
            let q = self.queue

            q.async { [client] in
                client.onBinary?(bytes)
            }
        }

        transport.onClose = { [weak self] code, reason, error in
            guard let self else { return }
            let client = self
            let c = code
            let r = reason
            let e = error
            let q = self.queue

            q.async { [client] in
                client.setupOnClose(code: c, reason: r, error: e)
            }
        }
    }

    private func setupOnOpen() {
        state = .open
        backoff = config.initialBackoff
        logger.info("WS успешно открыт ✓")
        onConnect?()
        flushQueue()
        schedulePingIfNeeded(interval: config.pingPong.clientPingInterval)
        cancelReconnectTimer()
    }

    private func setupOnClose(code: URLSessionWebSocketTask.CloseCode?, reason: Data?, error: Error?) {
        invalidatePingTimer()

        state = .closed
        onDisconnect?(code, error)

        if let nsErr = error as NSError?,
           let http = nsErr.userInfo[ExtWSErrorKey.httpResponse] as? HTTPURLResponse,

            http.statusCode == 401 {
            if let hook = onUpgradeError {
                logger.error("WS ошибка 401 пробуем переподключение")
                hook(http)
                return
            }
        }

        let ns = error as NSError?
        let isCancelled = (ns?.domain == NSURLErrorDomain && ns?.code == NSURLErrorCancelled)
        || (ns?.localizedDescription.lowercased().contains("cancelled") == true)

        if isCancelled {
            logger.info("WS закрыт - игнорируем")
            return
        }

        let pretty = formatClose(code: code, reason: reason, error: error)
        logger.warning("WS закрыт \(pretty)")

        if shouldStayConnected {
            scheduleReconnect()
        }
    }

    // MARK: - Inbound

    private func handleIncoming(text: String) {
        let frame = classify(text)

        switch frame.type {
            case .ping:
                handlePing(frame)
                return
            case .pong:
                handlePong(frame)
                return
            case .timeout:
                handleTimeout(frame)
                onFrame?(frame)
                onMessage?(text)
            case .message:
                onMessage?(frame.payload)
                onFrame?(frame)
            case .error, .unknown:
                onFrame?(frame)
        }

        onText?(text)
    }

    private func handlePing(_ frame: Frame) {
        if
            config.pingPong.enabled && config.pingPong.autoReplyServerPing,
            case .open = state {

            transport.send(text: config.pingPong.pongFrame) { _ in }
        }

        onFrame?(frame)
    }

    private func handlePong(_ frame: Frame) {
        onFrame?(frame)
    }

    private func handleTimeout(_ frame: Frame) {
        if let idle = extractIdleTimeoutSeconds(from: frame.payload) {
            let interval = max(1.0, Double(idle) - 5.0)
            logger.notice("WS установил idle-лог \(idle)сек → client ping \(Int(interval))сек")
            schedulePingIfNeeded(interval: interval)
        } else {
            logger.warning("WS инициализируется без idle-логов")
        }
    }

    // MARK: - Outbound queue

    private func flushQueue() {
        guard !sendQueue.isEmpty else { return }
        let batch = sendQueue
        sendQueue.removeAll()

        for msg in batch {
            transport.send(text: msg) { [weak self] error in
                if let error {
                    self?.logger.error("Ошибка отправки очереди: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Reconnect & Backoff

    private func scheduleReconnect() {
        cancelReconnectTimer()
        let jitter = Double.random(in: 0...(backoff / 2))
        let delay = min(backoff + jitter, config.maxBackoff)
        state = .retrying(after: delay)
        logger.warning("WS переподключится через \(String(format: "%.2f", delay))сек...")

        let nonce = connectNonce
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, repeating: .never)

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.shouldStayConnected, nonce == self.connectNonce else { return }
            self.backoff = min(self.backoff * 2, self.config.maxBackoff)
            self.openNow()
        }

        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.setEventHandler(handler: nil)
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Ping/Pong timer

    private func schedulePingIfNeeded(interval: TimeInterval?) {
        invalidatePingTimer()
        guard config.pingPong.enabled, let interval, interval > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)

        timer.setEventHandler { [weak self] in
            guard let self, case .open = self.state else { return }
            self.transport.send(text: self.config.pingPong.pingFrame) { _ in }
        }

        timer.resume()
        pingTimer = timer
    }

    private func invalidatePingTimer() {
        pingTimer?.setEventHandler(handler: nil)
        pingTimer?.cancel()
        pingTimer = nil
    }

    // MARK: - Reachability / Lifecycle

    private func setupReachability() {
        let monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {

#if DEBUG
                if self.testNetworkOverride != nil { return }
#endif

                let up = (path.status == .satisfied)

                if up != self.isNetworkAvailable {
                    self.isNetworkAvailable = up
                    self.logger.info("Сеть: \(up ? "↑" : "↓")")

                    if
                        up,
                        self.shouldStayConnected,
                        !self.isConnectingOrOpen
                    {
                        self.backoff = self.config.initialBackoff
                        self.openNow()
                    }
                }
            }
        }

        monitor.start(queue: DispatchQueue(label: "extws.reach"))
        pathMonitor = monitor
    }

    private func stopReachability() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func setupLifecycle() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in

            guard let self else { return }

            self.queue.async {
                guard self.config.suspendOnBackground else { return }
                self.shouldStayConnected = false
                self.cancelReconnectTimer()
                self.transport.close(code: .goingAway, reason: nil)
            }
        }

        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in

            guard let self else { return }

            self.queue.async {
                guard self.config.suspendOnBackground else { return }
                self.shouldStayConnected = true

                if !self.isConnectingOrOpen && self.isNetworkAvailable {
                    self.backoff = self.config.initialBackoff
                    self.openNow()
                }
            }
        }
    }

    // MARK: - Helpers

    @inline(__always)
    private func classify(_ text: String) -> Frame {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return Frame(type: .unknown, payload: "", raw: text)
        }

        if trimmed == config.pingPong.pingFrame {
            return Frame(type: .ping, payload: "", raw: text)
        }

        if trimmed == config.pingPong.pongFrame {
            return Frame(type: .pong, payload: "", raw: text)
        }

        var idx = trimmed.startIndex; var numStr = ""

        if trimmed.first == "-" {
            numStr.append("-")
            idx = trimmed.index(after: idx)
        }

        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            numStr.append(trimmed[idx])
            idx = trimmed.index(after: idx)
        }

        let type = Int(numStr).flatMap(FrameType.init(rawValue:)) ?? .unknown
        let payload = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)

        return Frame(type: type, payload: payload, raw: text)
    }

    private func extractIdleTimeoutSeconds(from payload: String) -> Int? {
        guard let data = payload.data(using: .utf8) else { return nil }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let idle = obj["idle_timeout"] as? Int {
                return idle
            }

            if let idleD = obj["idle_timeout"] as? Double {
                return Int(idleD)
            }
        }

        return nil
    }
}


#if DEBUG
// MARK: - Testing Utilities (DEBUG)

extension ExtWSClient {

    /// Тестовая имитация оповещения об изменении сети.
    public func __test_setNetwork(up: Bool) {
        queue.async {
            let was = self.isNetworkAvailable
            self.isNetworkAvailable = up
            if was != up {
                self.logger.debug("Network \(up ? "up" : "down") [TEST]")

                if up, self.shouldStayConnected, !(self.state == .open || self.state == .connecting) {
                    self.backoff = self.config.initialBackoff
                    self.openNow()
                }
            }
        }
    }

    /// Синхронный (по внутренней очереди) оверрайд статуса сети.
    /// - Parameter up: true/false — зафиксировать статус; nil — снять оверрайд.
    public func __test_overrideNetwork(up: Bool?) {
        queue.sync {
            let prev = self.testNetworkOverride
            self.testNetworkOverride = up

            if let up = up {
                self.isNetworkAvailable = up
                logger.info("Network \(up ? "up" : "down") [TEST OVERRIDE]")

                if up, self.shouldStayConnected, !(self.state == .open || self.state == .connecting) {
                    self.backoff = self.config.initialBackoff
                    self.openNow()
                } else if !up, self.state == .connecting {
                    self.state = .waitingNetwork
                }
            } else if prev != nil {
                logger.debug("Network override cleared [TEST]")
            }
        }
    }
}
#endif

// MARK: - Sensitive logging helpers

private extension ExtWSClient {

    func logConnectRequest(_ req: URLRequest) {
        let headers: [String:String] = req.allHTTPHeaderFields ?? [:]
        let cookieHeader = headers["Cookie"] ?? ""
        let hasWebToken = cookieHeader.contains("web_token=")

        if hasWebToken {
            logger.notice("WS подключается с Webtoken")
        } else {
            logger.notice("WS подключается БЕЗ Webtoken")
        }
    }

    func codeHint(_ code: URLSessionWebSocketTask.CloseCode) -> String {
        switch code {
            case .normalClosure:
                return "нормальное закрытие"
            case .goingAway:
                return "узел закрывает соединение "
            case .protocolError:
                return "протокольная ошибка"
            case .unsupportedData:
                return "неподдерживаемые данные"
            case .noStatusReceived:
                return "статус не получен"
            case .abnormalClosure:
                return "ненормальное закрытие (обрыв)"
            case .invalidFramePayloadData:
                return "битый payload"
            case .policyViolation:
                return "нарушение политики"
            case .messageTooBig:
                return "слишком большое сообщение"
            case .mandatoryExtensionMissing:
                return "нет обязательного расширения"
            case .internalServerError:
                return "ошибка сервера"
            case .tlsHandshakeFailure:
                return "ошибка TLS рукопожатия"
            case .invalid:
                return "invalid"
        @unknown default:
                return "неизвестный код"
        }
    }

    func decodeReason(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }

        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s.count > 200 ? String(s.prefix(200)) + "…" : s
        }

        return data.map { String(format: "%02hhx", $0) }.joined()
    }

    func describeError(_ error: Error) -> String {
        if let urlErr = error as? URLError {
            return "URLError(\(urlErr.code.rawValue)) \(urlErr.code)"
        }

        let ns = error as NSError
        var s = "\(ns.domain)#\(ns.code): \(ns.localizedDescription)"
        if ns.domain == NSPOSIXErrorDomain, ns.code == 57 { s += " [ENOTCONN]" }
        return s
    }

    func formatClose(code: URLSessionWebSocketTask.CloseCode?, reason: Data?, error: Error?) -> String {
        var parts: [String] = []

        if let code {
            parts.append("code:\(code.rawValue)(\(code.humanLabel)) — \(codeHint(code))")
        } else {
            parts.append("")
        }

        if let r = decodeReason(reason) { parts.append("reason: \(r)") }

        if let error {
            parts.append("error: \(describeError(error))")

            if let http = (error as NSError).userInfo[ExtWSErrorKey.httpResponse] as? HTTPURLResponse {
                parts.append("http=\(http.statusCode)")
            }
        }

        return parts.joined(separator: " | ")
    }
}
