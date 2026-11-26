import Foundation
import Network

/// The companion Chrome extension's view of Chrome: every tab with an
/// `<audio>` or `<video>` playing or paused in it, pushed to the app over a
/// tiny HTTP server on 127.0.0.1. The extension posts its whole list each
/// time something changes, and at least once a second while anything is
/// listed. Commands (play/pause, skip, seek, focus) go back on a held
/// request: the extension keeps `GET /wait` open and it is answered as soon
/// as a command is queued, or empty after 20 seconds — so nothing polls.
///
///   POST http://127.0.0.1:47811/state   {"items": [ {...}, ... ]}
///       → {"commands": [ {"id": "...", "action": "toggle", "value": 0} ]}
final class ChromeBridge: @unchecked Sendable {
    static let shared = ChromeBridge()
    static let port: NWEndpoint.Port = 47811

    private let lock = NSLock()
    /// Each Chrome profile or window set posting, by the id it sends.
    private var lists: [String: (items: [[String: Any]], at: Date)] = [:]
    private var pending: [[String: Any]] = []
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "chrome-bridge")
    /// Held `GET /wait` requests, by instance; touched only on `queue`.
    private var waiting: [String: (connection: NWConnection, origin: String)] = [:]
    /// How long a list stays current without a new post. The extension
    /// posts when something changes and every few seconds besides.
    static let freshFor: TimeInterval = 12
    /// Called on the main thread when a new list comes in.
    var onChange: (@MainActor () -> Void)?
    /// What the card lists right now, for `GET /ping` — a check that the
    /// extension's tabs made it into the menu.
    var shown: [[String: Any]] {
        get { lock.withLock { _shown } }
        set { lock.withLock { _shown = newValue } }
    }
    private var _shown: [[String: Any]] = []
    /// What the menu bar shows, for `GET /ping`.
    var bar: [String: Any] {
        get { lock.withLock { _bar } }
        set { lock.withLock { _bar = newValue } }
    }
    private var _bar: [String: Any] = [:]

    /// Whether the extension has posted lately. While it has, Chrome is not
    /// also read through AppleScript.
    var isConnected: Bool { lock.withLock { lists.values.contains { Date().timeIntervalSince($0.at) < Self.freshFor } } }

    /// The extension's items, or none if it has gone quiet.
    var current: [[String: Any]] {
        lock.withLock {
            lists = lists.filter { Date().timeIntervalSince($0.value.at) < Self.freshFor }
            return lists.sorted { $0.key < $1.key }.flatMap { instance, list in
                list.items.map { item in
                    var item = item
                    item["id"] = "\(instance)|\(item["id"] as? String ?? "")"
                    return item
                }
            }
        }
    }

    func send(id: String, action: String, value: Double) {
        // The id is "instance|extension id"; the command goes to that one.
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        lock.withLock { pending.append(["instance": parts[0], "id": parts[1], "action": action, "value": value]) }
        queue.async { self.answerWaiting(parts[0]) }
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // A request never finished, or a held /wait never answered, is not
        // kept open for ever.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.respond(connection, request)
            } else if done || error != nil || buffer.count > 4 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }

    /// A whole request once headers and `Content-Length` bytes are in.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    /// Hands a held `/wait` its commands, if there are any for it.
    private func answerWaiting(_ instance: String) {
        guard let held = waiting[instance] else { return }
        let mine: [[String: Any]] = lock.withLock {
            let mine = pending.filter { $0["instance"] as? String == instance }
            pending.removeAll { $0["instance"] as? String == instance }
            return mine
        }
        guard !mine.isEmpty else { return }
        waiting[instance] = nil
        reply(held.connection, origin: held.origin, status: "200 OK", ["commands": mine])
    }

    private func reply(_ connection: NWConnection, origin: String, status: String, _ reply: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if origin.hasPrefix("chrome-extension://") { head += "Access-Control-Allow-Origin: \(origin)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond(_ connection: NWConnection, _ request: Request) {
        // Only an extension may talk to it — not any web page the user opens,
        // nor one that has had its name pointed at this Mac (the Host it
        // sends is then its own), nor another program on the Mac.
        let origin = request.headers["origin"] ?? ""
        let host = request.headers["host"]?.lowercased() ?? ""
        let fromExtension = origin.hasPrefix("chrome-extension://")
        var status = "200 OK"
        var reply: [String: Any] = [:]
        if !["127.0.0.1:\(Self.port)", "localhost:\(Self.port)"].contains(host)
            || (!origin.isEmpty && !fromExtension) {
            status = "403 Forbidden"
        } else if request.method == "GET", request.path == "/ping" {
            // Anyone on the Mac may ask whether it runs; what plays, only the extension.
            reply = ["app": "NowPlayingMenu", "connected": isConnected]
            if fromExtension { reply.merge(["items": current, "card": shown, "bar": bar]) { $1 } }
        } else if !fromExtension && request.method == "POST" {
            // Chrome names the extension on its POSTs; a GET /wait from the
            // worker may carry no Origin, and is let through — it only
            // collects the commands for its own instance.
            status = "403 Forbidden"
        } else if request.method == "POST", request.path == "/state",
                  let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
            let list = object["items"] as? [[String: Any]] ?? []
            let instance = object["instance"] as? String ?? "default"
            let commands: [[String: Any]] = lock.withLock {
                lists[instance] = (list, Date())
                let mine = pending.filter { $0["instance"] as? String == instance }
                pending.removeAll { $0["instance"] as? String == instance }
                return mine
            }
            reply = ["commands": commands]
            if let onChange { onMain { onChange() } }
        } else if request.method == "GET", request.path.hasPrefix("/wait?instance=") {
            let instance = String(request.path.dropFirst("/wait?instance=".count))
            // One held request per instance: an older one is let go empty.
            if let old = waiting[instance] { self.reply(old.connection, origin: old.origin, status: "200 OK", ["commands": []]) }
            waiting[instance] = (connection, origin)
            answerWaiting(instance)
            queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, let held = self.waiting[instance], held.connection === connection else { return }
                self.waiting[instance] = nil
                self.reply(connection, origin: origin, status: "200 OK", ["commands": []])
            }
            return
        } else {
            status = "404 Not Found"
        }
        self.reply(connection, origin: origin, status: status, reply)
    }
}
