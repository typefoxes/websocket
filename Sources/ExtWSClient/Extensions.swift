//
//  Extensions.swift
//  ExtWSClient
//
//  Created by d.kotina on 01.09.2025.
//

import Foundation

extension MainActor {
    /// Гарантированно изолирует выполнение кода в ``operation`` блоке в main-очерени/потоке/акторе.
    static func isolating<Result: Sendable>(
        _ operation: @MainActor @Sendable () throws -> Result,
        file: StaticString = #fileID,
        line: UInt = #line
    ) rethrows -> Result {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(operation, file: file, line: line)
        } else {
            return try DispatchQueue.main.sync(execute: operation)
        }
    }
}

extension URLSessionWebSocketTask.CloseCode {
    var humanLabel: String {
        switch self {
        case .normalClosure: return "normalClosure"
        case .goingAway: return "goingAway"
        case .protocolError: return "protocolError"
        case .unsupportedData: return "unsupportedData"
        case .noStatusReceived: return "noStatus"
        case .abnormalClosure: return "abnormal"
        case .invalidFramePayloadData: return "invalidPayload"
        case .policyViolation: return "policyViolation"
        case .messageTooBig: return "messageTooBig"
        case .mandatoryExtensionMissing: return "extensionMissing"
        case .internalServerError: return "serverError"
        case .tlsHandshakeFailure: return "tlsHandshake"
        case .invalid: return "invalid"
        @unknown default: return "unknown"
        }
    }
}
