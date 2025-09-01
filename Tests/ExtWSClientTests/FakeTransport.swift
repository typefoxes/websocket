//
//  MockTransport.swift
//  ExtWSClient
//
//  Created by d.kotina on 15.08.2025.
//

import XCTest
@testable import ExtWSClient

final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode?, Data?, Error?) -> Void)?
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?

    private(set) var lastRequest: URLRequest?
    private(set) var connectCalls = 0
    private(set) var sentTexts: [String] = []

    func connect(request: URLRequest) {
        connectCalls += 1
        lastRequest = request

        DispatchQueue.main.async {
            self.onOpen?()
        }
    }

    func send(text: String, completion: @escaping (Error?) -> Void) {
        sentTexts.append(text)
        completion(nil)
    }

    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.onClose?(code, nil, nil)
        }
    }

    func serverPush(_ s: String) {
        onText?(s)
    }

    func serverPushBinary(_ d: Data) {
        onBinary?(d)
    }
}
