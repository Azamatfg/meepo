import Foundation
import Network

/// Minimal HTTP/1.1 request, enough for the bridge's single POST.
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    /// Lowercased names.
    var headers: [String: String]
    var body: Data

    /// Nil until the whole request (headers + Content-Length body) has arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: Data(body.prefix(length)))
    }
}

/// Receives hook events from meepo-bridge.sh on 127.0.0.1 (SPEC §4, §8).
@MainActor
final class EventServer {
    nonisolated static let defaultPort: UInt16 = 47800
    private static let maxRequestSize = 1_000_000

    private let token: String
    private let onEvent: (Int64, Data) -> Void
    private var listener: NWListener?
    var onFailure: ((String) -> Void)?

    /// `onEvent` gets the Meepo session id (from the bridge's header) and the raw hook JSON.
    init(token: String, onEvent: @escaping (Int64, Data) -> Void) {
        self.token = token
        self.onEvent = onEvent
    }

    func start(port: UInt16 = defaultPort) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            MainActor.assumeIsolated {
                self?.onFailure?("Порт \(port) недоступен: \(error.localizedDescription)")
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// HTTP status for a request, plus the session it belongs to when accepted.
    nonisolated static func route(_ request: HTTPRequest, token: String) -> (status: Int, sessionId: Int64?) {
        guard request.method == "POST", request.path == "/event" else { return (404, nil) }
        guard request.headers["x-meepo-token"] == token else { return (401, nil) }
        guard let id = request.headers["x-meepo-session"].flatMap({ Int64($0) }) else { return (400, nil) }
        return (204, id)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest.parse(buffer) {
                    self?.respond(connection, to: request)
                } else if isComplete || error != nil || buffer.count > Self.maxRequestSize {
                    connection.cancel()
                } else {
                    self?.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, to request: HTTPRequest) {
        let (status, sessionId) = Self.route(request, token: token)
        let head = "HTTP/1.1 \(status) \(status == 204 ? "No Content" : "Error")\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
        if let sessionId { onEvent(sessionId, request.body) }
    }
}
