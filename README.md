

# WebSocket клиент для Swift

[![Swift](https://img.shields.io/badge/Swift-5.5+-orange.svg)](https://swift.org)
[![iOS](https://img.shields.io/badge/iOS-13.0+-blue.svg)](https://developer.apple.com/ios/)

Swift-клиент для работы с WebSocket, поддерживающий автоматическое переподключение, сериализацию данных и обработку событий.

## Возможности

- 🚀 **Автоматическое переподключение** с экспоненциальной задержкой
- 📦 **Очередь сообщений** при потере соединения
- 💓 **Ping/Pong** для поддержания активности соединения
- 🎭 **Подписка на события** (подключение, сообщения, ошибки)
- 🧪 **Полная поддержка тестирования**

## Установка

Для интеграции этого WebSocket клиента в Ваш проект на Swift, вы можете либо клонировать репозиторий, либо вручную добавить исходные файлы.

```bash
git clone https://github.com/extws-team/client-swift.git
```

### Swift Package Manager

Добавьте в `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/extws-team/client-swift.git", from: "1.1.0")
]
```

## Быстрый старт

import ExtWSClient

let ws = ExtWSClient(config: .init(
    url: URL(string: "wss://example.com/ws")!,
    moduleName: "ChatWS",
    pingPong: .init(
        enabled: true,
        pingFrame: "2",
        pongFrame: "3",
        clientPingInterval: nil,
        autoReplyServerPing: true,
        suppressForwardingToOnText: true  // кадры 2/3 не попадут в onText
    ),
    suspendOnBackground: true
))

ws.beforeConnect = { req in
    var headers = req.allHTTPHeaderFields ?? [:]
    headers["Cookie"] = [
        "example",
        "web_token=\(exampleToken)"
    ].joined(separator: "; ")
    req.allHTTPHeaderFields = headers
}

// Логер с уровнями и контекстом:
ws.logger = { level, message, ctx in
    print("[\(ctx.module)] [\(level.rawValue.uppercased())] \(ctx.function) @ \(ctx.file):\(ctx.line) — \(message)")
}

// Получаем полезные сообщения (тип 4...), парсинг JSON — на стороне клиента:
ws.onMessage = { payload in
    MyClientParser.handle(payload)
}

// Пример: старт и первая синхронизация
ws.onConnect = {
    ws.send(#"4api["example",{"id":0000}]"#)
}

ws.connect()


## API и колбэки

### Основные методы

```swift
ws.connect()
ws.disconnect()
ws.send("4api[...]")         // отправка произвольной строки
ws.sendPingNow()             // отправить "2"
ws.sendPongNow()             // отправить "3"
ws.updateClientPingInterval(30) // переопределить интервал client PING (сек)
```

### Колбэки

```swift
ws.onStateChange: (ExtWSState) -> Void
ws.onConnect: () -> Void
ws.onDisconnect: (URLSessionWebSocketTask.CloseCode?, Error?) -> Void

ws.onText: (String) -> Void          // сырые тексты (без 2/3/1 при suppress=true)
ws.onBinary: (Data) -> Void

ws.onMessage: (String) -> Void       // для кадров типа 4 (payload без ведущей "4")
ws.onProtoError: (String) -> Void    // для кадров типа -1

ws.beforeConnect: (inout URLRequest) -> Void // добавьте куки/заголовки
ws.onUpgradeError: (UpgradeError) -> Void    // если используете кастомный транспорт
ws.logger: (level, message, context) -> Void
```

## Состояния

```swift
idle → connecting → open → (closing) → closed → retrying(after:) → ...
При отсутствии сети: waitingNetwork
```

## Конфигурация

```swift
public struct ExtWSConfig {
    public var url: URL
    public var moduleName: String = "ExtWS"

    public struct PingPongConfig {
        public var enabled: Bool = true
        public var pingFrame: String = "2"
        public var pongFrame: String = "3"
        public var clientPingInterval: TimeInterval? = nil // если nil — возьмём из INIT
        public var autoReplyServerPing: Bool = true
        public var suppressForwardingToOnText: Bool = true  // 2/3 не идут в onText
    }
    public var pingPong: PingPongConfig = .init()

    public var initialBackoff: TimeInterval = 1
    public var maxBackoff: TimeInterval = 30
    public var suspendOnBackground: Bool = true
    public var logTrimLimit: Int? = 512 // усечение payload в логах
}

```

PING/PONG и idle_timeout
Входящий 2 (PING) → модуль автоматически шлёт 3 (PONG).
При первом timeout-кадре (1{...}) ExtWS извлекает idle_timeout из JSON и настраивает клиентский PING-таймер на max(1, idle_timeout-5) секунд.
Кадры 2/3/1 по умолчанию не попадают в onText (см. suppressForwardingToOnText), но логируются и учитываются внутри.
Модуль не парсит другие поля JSON — только idle_timeout из 1{...}.

## Очередь и переподключение

Все вызовы send(...) до open — складываются в очередь и шлются сразу после подключения.
Переподключение при закрытии/ошибке: экспоненциальный backoff с джиттером до maxBackoff.
Повторные connect() при активном соединении — игнорируются.

## Работа с сетью и фоном

Если сети нет — состояние waitingNetwork, коннект не стартует.
При восстановлении сети ExtWS сам переподключится (если shouldStayConnected == true).
При уходе в фон (если suspendOnBackground == true) сокет закрывается; при возврате — переподключается.

## Логирование

Передайте ws.logger = { level, message, ctx in ... }.
Контекст включает: moduleName, file, function, line.
Полезная нагрузка (payload) усечётся по logTrimLimit.

```swift
ws.logger = { level, message, ctx in
    print("[\(ctx.module)] [\(level.rawValue.uppercased())] \(ctx.function) @ \(ctx.file):\(ctx.line) — \(message)")
}
```

## Транспорт

ExtWS работает через абстракцию:

```swift
public protocol WebSocketTransport: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onClose: ((URLSessionWebSocketTask.CloseCode?, Data?, Error?) -> Void)? { get set }
    var onText: ((String) -> Void)? { get set }
    var onBinary: ((Data) -> Void)? { get set }

    func connect(request: URLRequest)
    func send(text: String, completion: @escaping (Error?) -> Void)
    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
```

В комплекте — реализация на URLSessionWebSocketTask.
Если нужно читать заголовки неудачного апгрейда (например, 401 + Set-Cookie), внедрите альтернативный транспорт (Starscream/NWConnection) и используйте onUpgradeError.

## Лицензия
Проект доступен под лицензией MIT. Подробности см. в файле LICENSE.
