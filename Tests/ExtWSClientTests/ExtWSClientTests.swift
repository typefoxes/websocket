//
//  ExtWSTests.swift
//  ExtWSClient
//
//  Created by d.kotina on 15.08.2025.
//

import XCTest
@testable import ExtWSClient

actor Counter {
    private var value: Int = 0
    func inc() { value += 1 }
    func get() -> Int { value }
}

actor StatesBox {
    private var arr: [ExtWSState] = []
    func append(_ s: ExtWSState) { arr.append(s) }
    func snapshot() -> [ExtWSState] { arr }
}

actor ValueBox<T: Sendable> {
    private var value: T?
    func set(_ v: T?) { value = v }
    func get() -> T? { value }
}

final class ExtWSClientTests: XCTestCase {

    private func makeWS(
        transport: FakeTransport = FakeTransport(),
        pingInterval: TimeInterval? = nil,
        suppress2and3: Bool = true
    ) -> (ExtWSClient, FakeTransport) {
        let url = URL(string: "wss://example.com/ws")!
        let cfg = ExtWSConfig(
            url: url,
            moduleName: "ChatWS",
            pingPong: .init(
                enabled: true,
                pingFrame: "2",
                pongFrame: "3",
                clientPingInterval: pingInterval,
                autoReplyServerPing: true,
                suppressForwardingToOnText: suppress2and3
            ),
            initialBackoff: 0.05,
            maxBackoff: 0.1,
            suspendOnBackground: false,
            logTrimLimit: 200
        )
        let ws = ExtWSClient(config: cfg, transport: transport)
        return (ws, transport)
    }

    func testConnectOnceAndState() async {
        let (ws, fake) = makeWS()
        let states = StatesBox()

        let openExp = expectation(description: "open")
        ws.onStateChange = { s in Task { await states.append(s) } }
        ws.onConnect = { openExp.fulfill() }

        ws.connect()
        ws.connect() // вторая попытка должна быть проигнорирована

        await fulfillment(of: [openExp], timeout: 1.0)
        let snapshot = await states.snapshot()
        XCTAssertEqual(fake.connectCalls, 1, "должен быть один вызов connect у транспорта")
        XCTAssertTrue(snapshot.contains(.connecting) && snapshot.contains(.open))
    }

    func testBeforeConnectHeadersApplied() async {
        let (ws, fake) = makeWS()
        ws.beforeConnect = { req in
            var h = req.allHTTPHeaderFields ?? [:]
            h["Cookie"] = "__m1_trust=ios:token; web_token=abc"
            req.allHTTPHeaderFields = h
        }
        let exp = expectation(description: "open")
        ws.onConnect = { exp.fulfill() }
        ws.connect()
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(fake.lastRequest?.allHTTPHeaderFields?["Cookie"], "__m1_trust=ios:token; web_token=abc")
    }

    func testQueueFlushedAfterOpen() async {
        let (ws, fake) = makeWS()
        // отправляем ДО connect — должно попасть в очередь
        let payload = #"4api["im.sync",{"id_last":-1}]"#
        ws.send(payload)

        let exp = expectation(description: "open")
        ws.onConnect = { exp.fulfill() }
        ws.connect()
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertTrue(fake.sentTexts.contains(payload), "очередь должна была отправиться после открытия")
    }

    func testSendWhenOpen() async {
        let (ws, fake) = makeWS()
        let exp = expectation(description: "open")
        ws.onConnect = { exp.fulfill() }
        ws.connect()
        await fulfillment(of: [exp], timeout: 1.0)

        ws.send("4ping{}")
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        XCTAssertTrue(fake.sentTexts.contains("4ping{}"))
    }

    func testPingAutoReplyAndSuppression() async {
        let (ws, fake) = makeWS(suppress2and3: true)
        let textCounter = Counter()

        ws.onText = { _ in Task { await textCounter.inc() } }
        let exp = expectation(description: "open")
        ws.onConnect = { exp.fulfill() }
        ws.connect()
        await fulfillment(of: [exp], timeout: 1.0)

        // сервер прислал PING "2"
        fake.serverPush("2")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(fake.sentTexts.contains("3"), "должны автоматически ответить PONG='3'")
        let count = await textCounter.get()
        XCTAssertEqual(count, 0, "кадры 2/3 не должны попадать в onText при suppress=true")
    }

    func testPongSuppression() async {
        let (ws, fake) = makeWS(suppress2and3: true)
        let textCounter = Counter()
        ws.onText = { _ in Task { await textCounter.inc() } }
        let exp = expectation(description: "open")
        ws.onConnect = { exp.fulfill() }
        ws.connect()
        await fulfillment(of: [exp], timeout: 1.0)

        // сервер прислал PONG "3"
        fake.serverPush("3")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let count = await textCounter.get()
        XCTAssertEqual(count, 0, "PONG '3' должен быть подавлен в onText при suppress=true")
    }

    func testTimeoutInitSchedulesPingFromIdle() async {
        let (ws, fake) = makeWS(pingInterval: nil) // интервал возьмём из INIT
        let exp = expectation(description: "open")
        ws.onConnect = { exp.fulfill() }
        ws.connect()
        await fulfillment(of: [exp], timeout: 1.0)

        // сервер прислал INIT/timeout: idle_timeout=6 → клиентский ping каждые max(1, 6-5)=1 сек
        fake.serverPush(#"1{"id":"abc","idle_timeout":6}"#)

        // ждём чуть больше 1 секунды, чтобы поймать отправку "2"
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(fake.sentTexts.contains(where: { $0 == "2" }), "ожидали автоматический клиентский PING '2' после INIT")
    }

    func testMessageDeliveredToOnMessage() async {
        let (ws, fake) = makeWS()
        let exp = expectation(description: "open")
        ws.onConnect = { exp.fulfill() }

        let box = ValueBox<String>()
        ws.onMessage = { payload in Task { await box.set(payload) } }

        ws.connect()
        await fulfillment(of: [exp], timeout: 1.0)

        // сервер прислал "4events{...}" (как в протоколе)
        let raw = #"4events{"foo":1}"#
        fake.serverPush(raw)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let got = await box.get()
        XCTAssertNotNil(got, "payload сообщения должен доставляться в onMessage")
        XCTAssertTrue(got?.hasPrefix("events") == true, "payload должен быть 'events{...}', без ведущего '4'")
    }

    func testDisconnectStopsReconnection() async {
        let (ws, fake) = makeWS()
        let open = expectation(description: "open")
        ws.onConnect = { open.fulfill() }
        ws.connect()
        await fulfillment(of: [open], timeout: 1.0)

        let closed = expectation(description: "closed")
        ws.onDisconnect = { _, _ in closed.fulfill() }
        ws.disconnect()
        await fulfillment(of: [closed], timeout: 1.0)

        let calls = fake.connectCalls
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.connectCalls, calls, "после disconnect() не должно быть реконнектов")
    }

    func testSendPingNowAndPongNow() async {
        let (ws, fake) = makeWS()
        let open = expectation(description: "open")
        ws.onConnect = { open.fulfill() }
        ws.connect()
        await fulfillment(of: [open], timeout: 1.0)

        ws.sendPingNow()
        ws.sendPongNow()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(fake.sentTexts.contains("2"))
        XCTAssertTrue(fake.sentTexts.contains("3"))
    }

    func testUpdateClientPingIntervalSchedulesTimer() async {
        let (ws, fake) = makeWS(pingInterval: nil) // начально нет таймера
        let open = expectation(description: "open")
        ws.onConnect = { open.fulfill() }
        ws.connect()
        await fulfillment(of: [open], timeout: 1.0)

        // включаем таймер на 0.1с
        ws.updateClientPingInterval(0.1)
        try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s
        XCTAssertTrue(fake.sentTexts.contains("2"), "ожидали PING от таймера после updateClientPingInterval")
    }

    func testOpenWaitsWhenNetworkDown() async {
        let (ws, fake) = makeWS()

        // Жёстко фиксируем сеть вниз, синхронно
        ws.__test_overrideNetwork(up: false)

        let states = StatesBox()
        ws.onStateChange = { s in Task { await states.append(s) } }
        ws.connect()

        // даём очереди обработать состояние
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = await states.snapshot()
        XCTAssertTrue(snapshot.contains(.waitingNetwork), "ожидали состояние waitingNetwork при отсутствии сети")
        XCTAssertEqual(fake.connectCalls, 0, "не должно выполняться подключение при сети down")
    }

    func testOnBinaryForwarded() async {
        let (ws, fake) = makeWS()
        let open = expectation(description: "open")
        ws.onConnect = { open.fulfill() }
        let bytes = Counter()
        ws.onBinary = { _ in Task { await bytes.inc() } }
        ws.connect()
        await fulfillment(of: [open], timeout: 1.0)

        fake.serverPushBinary(Data([0x01, 0x02, 0x03]))
        try? await Task.sleep(nanoseconds: 30_000_000)

        let c = await bytes.get()
        XCTAssertEqual(c, 1, "binary событие должно быть доставлено")
    }
}

