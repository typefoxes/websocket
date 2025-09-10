//
//  Logger.swift
//  ExtWSClient
//
//  Created by d.kotina on 30.04.2025.
//

import Foundation

public protocol LoggerProtocol {
    func log(_ message: String, isError: Bool?, file: String, function: String)
    func clearLogs()
    var messages: [String] { get }
    var delegate: LoggerDelegate? { get set }
}

public protocol LoggerDelegate: AnyObject {
    func loggerDidAddMessages(_ newMessage: String)
    func loggerDidClear()
}

public extension LoggerProtocol {
    func log(_ message: String, isError: Bool? = nil, file: String = #fileID, function: String = #function) {
        self.log(message, isError: isError, file: file, function: function)
    }

    func info(_ message: String, file: String = #fileID, function: String = #function) {
        log(message, isError: nil, file: file, function: function)
    }

    func warning(_ message: String, file: String = #fileID, function: String = #function) {
        log(message, isError: false, file: file, function: function)
    }

    func error(_ message: String, file: String = #fileID, function: String = #function) {
        log(message, isError: true, file: file, function: function)
    }
}

public final class Logger: LoggerProtocol, @unchecked Sendable {
    public weak var delegate: LoggerDelegate?

    private let isolationQueue = DispatchQueue(label: "com.youapp.logger.isolation", attributes: .concurrent)
    private var _messages: [String] = []

    public var messages: [String] {
        isolationQueue.sync {
            return _messages
        }
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public func log(_ message: String, isError: Bool?, file: String, function: String) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = extractFileName(from: file)

        let formattedMessage = formatMessage(
            message,
            timestamp: timestamp,
            fileName: fileName,
            function: function,
            isError: isError
        )

        isolationQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            self._messages.append(formattedMessage)
            self.trimMessageBuffer()

            // Уведомление делегата и вывод в консоль на главном потоке
            DispatchQueue.main.async {
                self.delegate?.loggerDidAddMessages(formattedMessage)
                self.printToConsole(formattedMessage)
            }
        }
    }

    public func clearLogs() {
        isolationQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            self._messages.removeAll()

            DispatchQueue.main.async {
                self.delegate?.loggerDidClear()
            }
        }
    }

    private func extractFileName(from filePath: String) -> String {
        let fileURL = URL(fileURLWithPath: filePath)
        return fileURL.deletingPathExtension().lastPathComponent
    }

    private func formatMessage(
        _ message: String,
        timestamp: String,
        fileName: String,
        function: String,
        isError: Bool?
    ) -> String {
        let symbol: String

        switch isError {
        case true: symbol = "🔴"
        case false: symbol = "🟡"
        default: symbol = "💡"
        }

        return "\(symbol) [\(timestamp)] - [\(fileName)] - [\(function)]: \(message)"
    }

    private func printToConsole(_ message: String) {
        debugPrint(message)
    }

    private func trimMessageBuffer() {
        if _messages.count > 150 {
            _messages.removeFirst()
        }
    }
}
