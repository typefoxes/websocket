//
//  WebSocketTransport.swift
//  M1App
//
//  Created by d.kotina on 15.08.2025.
//

import Foundation

// MARK: - WebSocketTransport Protocol

/// Протокол транспорта WebSocket поверх `URLSession`.
///
/// Этот протокол абстрагирует отправку/приём сообщений и события жизненного цикла
/// соединения. Реализации должны обеспечить потокобезопасность вызовов и доставку
/// событий колбэков на предсказуемой очереди (в данной реализации — на
/// внутренней последовательной очереди).
///
/// - Примечания:
///   - Все обработчики событий (`onOpen`, `onClose`, `onText`, `onBinary`) являются
///     опциональными. Если обработчик не установлен, соответствующее событие
///     игнорируется.
///   - Сетевые ошибки и ошибки уровня задачи (`URLSessionTask`) передаются в
///     `onClose(_,_,_)`.
///   - Протокол ориентирован на клиентов, которым достаточно высокоуровневого API
///     для обмена строковыми и бинарными сообщениями.
public protocol WebSocketTransport: AnyObject {
    /// Колбэк об успешном открытии WebSocket-соединения.
    ///
    /// Вызывается после установления TCP/TLS и успешного рукопожатия WebSocket.
    var onOpen: (() -> Void)? { get set }

    /// Колбэк о закрытии WebSocket-соединения.
    ///
    /// Вызывается в следующих случаях:
    /// - удалённая сторона закрыла соединение и был получен код закрытия (`closeCode`) и `reason`;
    /// - либо произошла ошибка (`error`) на уровне `URLSession` / `URLSessionTask`.
    ///
    /// - Parameters:
    ///   - closeCode: Код закрытия, если он доступен (может быть `nil` при ошибках сети).
    ///   - reason: Причина закрытия в формате `Data`, если была передана удалённой стороной.
    ///   - error: Ошибка, если закрытие инициировано ошибкой стека URLSession/HTTP.
    var onClose: ((URLSessionWebSocketTask.CloseCode?, Data?, Error?) -> Void)? { get set }

    /// Колбэк при получении текстового сообщения.
    ///
    /// - Parameter String: Полный текст сообщения (UTF-8).
    var onText: ((String) -> Void)? { get set }

    /// Колбэк при получении бинарного сообщения.
    ///
    /// - Parameter Data: Непрозрачные бинарные данные сообщения.
    var onBinary: ((Data) -> Void)? { get set }

    /// Устанавливает WebSocket-соединение по заданному запросу.
    ///
    /// Если ранее существовала активная задача, она будет отменена перед созданием новой.
    /// Метод потокобезопасен.
    ///
    /// - Important: После вызова `connect(request:)` приём сообщений запускается автоматически.
    ///
    /// - Parameter request: `URLRequest` на `ws://` или `wss://` URL c необходимыми заголовками.
    func connect(request: URLRequest)

    /// Отправляет текстовое сообщение через активное WebSocket-соединение.
    ///
    /// - Parameters:
    ///   - text: Строка для отправки (UTF-8).
    ///   - completion: Замыкание, вызываемое по завершении отправки.
    ///     В случае ошибки возвращается ненулевая `Error`.
    ///
    /// - Note: Если задача ещё не создана, `completion` будет вызван с ошибкой
    ///   домена `"extws"` и кодом `-1`.
    func send(text: String, completion: @escaping @Sendable (Error?) -> Void)

    /// Закрывает активное WebSocket-соединение с указанным кодом и причиной.
    ///
    /// - Parameters:
    ///   - code: Код закрытия, отправляемый удалённой стороне.
    ///   - reason: Необязательная причина закрытия (будет передана удалённой стороне).
    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

// MARK: - URLSessionWSTransport

/// Реализация `WebSocketTransport` на базе `URLSessionWebSocketTask`.
///
/// Особенности:
/// - Поддерживает автоматический бесконечный цикл приёма (`receiveLoop()`), пока задача активна.
/// - Использует внутреннюю последовательную очередь для синхронизации (`extws.transport`).
/// - Доставляет события (`onOpen`, `onClose`, `onText`, `onBinary`) из контекста колбэков
///   `URLSession` и обработчика приёма. Гарантия конкретной очереди доставки обработчиков
///   пользователю не предоставляется; при необходимости переключайтесь на нужную очередь сами.
///
/// Диагностика:
/// - При завершении `URLSessionTask` с ошибкой, ошибка оборачивается в `NSError` с сохранением
///   исходного `domain`/`code`, а в `userInfo` (ключ `ExtWSErrorKey.httpResponse`) добавляется
///   полученный `HTTPURLResponse`, если доступен. Это упрощает доступ к HTTP-коду рукопожатия.
///
/// Потокобезопасность:
/// - Доступ к `task` и сетевым операциям сериализован через приватную очередь `queue`.
public final class URLSessionWSTransport: NSObject, WebSocketTransport, @unchecked Sendable {

    private lazy var session: URLSession = {
        let conf = URLSessionConfiguration.default
        conf.waitsForConnectivity = false
        return URLSession(configuration: conf, delegate: self, delegateQueue: nil)
    }()

    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "extws.transport")

    public var onOpen: (() -> Void)?
    public var onClose: ((URLSessionWebSocketTask.CloseCode?, Data?, Error?) -> Void)?
    public var onText: ((String) -> Void)?
    public var onBinary: ((Data) -> Void)?

    public func connect(request: URLRequest) {
        queue.async {
            // отменяем старую, создаём новую
            self.task?.cancel()
            let t = self.session.webSocketTask(with: request)
            self.task = t
            t.resume()
            self.receiveLoop(task: t)
        }
    }

    public func send(text: String, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async {
            guard let t = self.task else {
                completion(NSError(
                    domain: "extws",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No task"]
                ))
                return
            }

            t.send(.string(text), completionHandler: completion)
        }
    }


    public func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            self.task?.cancel(with: code, reason: reason)
        }
    }

    // MARK: - Receive loop (bound to specific task)

    private func deliverClose(_ code: URLSessionWebSocketTask.CloseCode?, _ reason: Data?, _ error: Error?) {
        guard self.task != nil else { return }
        self.task = nil
        self.onClose?(code, reason, error)
    }

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
                case .failure(let error):

                    self.queue.async {
                        guard task == self.task else { return }
                        self.deliverClose(nil, nil, error)
                    }
                case .success(let message):
                    self.queue.async {
                        guard task == self.task else { return }

                        switch message {
                            case .string(let s):
                                self.onText?(s)
                            case .data(let d):
                                self.onBinary?(d)
                            @unknown default:
                                break
                        }

                        if task == self.task {
                            self.receiveLoop(task: task)
                        }
                    }
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
extension URLSessionWSTransport: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        queue.async {
            if webSocketTask == self.task { self.onOpen?()
            }
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            if webSocketTask == self.task {
                self.deliverClose(code, reason, nil)
            }
        }
    }
}

// MARK: - URLSessionTaskDelegate
extension URLSessionWSTransport: URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        var userInfo = (error as NSError).userInfo

        if let http = task.response as? HTTPURLResponse {
            userInfo[ExtWSErrorKey.httpResponse] = http
        }

        let wrapped = NSError(domain: (error as NSError).domain, code: (error as NSError).code, userInfo: userInfo)

        queue.async {
            if task == self.task {
                self.deliverClose(nil, nil, wrapped)
            }
        }
    }
}
