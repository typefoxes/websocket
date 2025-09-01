//
//  ExtWSConfig.swift
//  ExtWSClient
//
//  Created by d.kotina on 01.09.2025.
//

import Foundation

// MARK: - FrameType

/// Типы фреймов, поддерживаемые протоколом.
/// Используются для интерпретации текстовых сообщений в рамках расширенного WebSocket-протокола.
///
/// - Cases:
///   - `error`: Ошибка при парсинге или обработке.
///   - `timeout`: Событие таймаута.
///   - `ping`: Пинг-кадр (обычно "2").
///   - `pong`: Понг-кадр (обычно "3").
///   - `message`: Пользовательское сообщение.
///   - `unknown`: Неизвестный/неподдерживаемый тип.
public enum FrameType: Int, Sendable {
    case error = -1
    case timeout = 1
    case ping = 2
    case pong = 3
    case message = 4
    case unknown = 0
}

// MARK: - Frame

/// Представление одного текстового WebSocket-фрейма.
///
/// - Properties:
///   - `type`: Тип фрейма (`FrameType`).
///   - `payload`: Полезная нагрузка, часть строки после ведущего типа. Может быть пустой.
///   - `raw`: Исходная строка, полученная из WebSocket.
public struct Frame: Sendable {
    /// Тип фрейма (ping, pong, message и т.д.).
    public let type: FrameType

    /// Полезная нагрузка (часть после ведущего идентификатора типа).
    ///- Note: Может быть пустой строкой.
    public let payload: String

    /// Исходная строка, пришедшая по WebSocket.
    public let raw: String
}

// MARK: - ExtWSConfig

/// Конфигурация расширенного WebSocket-клиента.
/// Содержит параметры соединения, поведения при потере сети, логи и настройки ping/pong.
public struct ExtWSConfig: Sendable {

    /// URL для подключения (формируется заранее, query/headers/куки добавляются в `beforeConnect`).
    public var url: URL

    ///  Имя модуля для логирования.
    public var moduleName: String

    /// Конфигурация ping/pong-кадров (`PingPongConfig`).
    public var pingPong: PingPongConfig

    /// Начальная задержка перед переподключением.
    public var initialBackoff: TimeInterval

    /// Максимальная задержка между попытками переподключения.
    public var maxBackoff: TimeInterval

    /// При `true` соединение будет отключаться в фоне и возобновляться при возврате.
    public var suspendOnBackground: Bool

    /// Ограничение размера полезной нагрузки в логах (nil = не усекать).
    public var logTrimLimit: Int?

    /// Инициализатор с параметрами по умолчанию.
    ///
    /// - Parameters:
    ///   - url: Готовый URL для подключения.
    ///   - moduleName: Имя модуля для логов (по умолчанию "ExtWS").
    ///   - pingPong: Настройки ping/pong (по умолчанию `PingPongConfig()`).
    ///   - initialBackoff: Начальный интервал переподключения (по умолчанию 1 сек).
    ///   - maxBackoff: Максимальный интервал переподключения (по умолчанию 30 сек).
    ///   - suspendOnBackground: Отключение соединения в фоне (по умолчанию true).
    ///   - logTrimLimit: Усечение полезной нагрузки в логах (по умолчанию 512).
    public init(
        url: URL,
        moduleName: String = "ExtWS",
        pingPong: PingPongConfig = PingPongConfig(),
        initialBackoff: TimeInterval = 1.0,
        maxBackoff: TimeInterval = 30.0,
        suspendOnBackground: Bool = true,
        logTrimLimit: Int? = 512
    ) {
        self.url = url
        self.moduleName = moduleName
        self.pingPong = pingPong
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.suspendOnBackground = suspendOnBackground
        self.logTrimLimit = logTrimLimit
    }
}

// MARK: - PingPongConfig

/// Конфигурация поведения ping/pong.
/// Позволяет управлять клиентскими PING-кадрами, автоматическими ответами
/// и логикой проксирования.
public struct PingPongConfig: Sendable {

    /// Включить поддержку ping/pong внутри WebSocket.
    public var enabled: Bool

    /// Строковый кадр для пинга (по умолчанию "2").
    public var pingFrame: String

    ///  Строковый кадр для понга (по умолчанию "3").
    public var pongFrame: String

    /// Интервал проактивных PING со стороны клиента (nil = не слать).
    public var clientPingInterval: TimeInterval?

    /// Автоматически отвечать PONG на входящий PING.
    public var autoReplyServerPing: Bool

    /// Подавлять проксирование кадров "2"/"3" в `onText`
    public var suppressForwardingToOnText: Bool

    /// Инициализатор с параметрами по умолчанию.
    ///
    /// - Parameters:
    ///   - enabled: Включить ping/pong (по умолчанию true).
    ///   - pingFrame: Строка для ping-кадра (по умолчанию "2").
    ///   - pongFrame: Строка для pong-кадра (по умолчанию "3").
    ///   - clientPingInterval: Интервал проактивного PING (по умолчанию nil).
    ///   - autoReplyServerPing: Автоответ на PING сервера (по умолчанию true).
    ///   - suppressForwardingToOnText: Подавлять кадры в `onText` (по умолчанию true).
    public init(
        enabled: Bool = true,
        pingFrame: String = "2",
        pongFrame: String = "3",
        clientPingInterval: TimeInterval? = nil,
        autoReplyServerPing: Bool = true,
        suppressForwardingToOnText: Bool = true
    ) {
        self.enabled = enabled
        self.pingFrame = pingFrame
        self.pongFrame = pongFrame
        self.clientPingInterval = clientPingInterval
        self.autoReplyServerPing = autoReplyServerPing
        self.suppressForwardingToOnText = suppressForwardingToOnText
    }
}
