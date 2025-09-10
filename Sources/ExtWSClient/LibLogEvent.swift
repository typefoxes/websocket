//
//  LibLogEvent.swift
//  ExtWSClient
//
//  Created by d.kotina on 10.09.2025.
//

import Foundation

public enum LibLogLevel: Int, Sendable {
    case debug = 10
    case info = 20
    case warning = 30
    case error = 40
}

public struct LibLogEvent: Sendable {
    public let date: Date
    public let level: LibLogLevel
    public let message: String
    public let file: String
    public let function: String
    public let line: UInt
    public let module: String

    public init(
        date: Date = Date(),
        level: LibLogLevel,
        message: String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line,
        module: String = "ExtWSClient"
    ) {
        self.date = date
        self.level = level
        self.message = message
        self.file = file
        self.function = function
        self.line = line
        self.module = module
    }
}

public typealias LogHandler = (_ event: LibLogEvent) -> Void

