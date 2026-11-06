import Foundation
import Network

@MainActor
final class LocalMCPServer: ObservableObject {
    static let shared = LocalMCPServer()
    @Published private(set) var endpoint: String?
    @Published private(set) var token: String?
    @Published private(set) var error: String?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var session = UUID()
    private var store: SQLiteHistoryStore?
    private let queue = DispatchQueue(label: "PasteLite.local-mcp")

    func start(store: SQLiteHistoryStore) {
        guard listener == nil else { return }
        self.store = store; error = nil
        token = UUID().uuidString + UUID().uuidString
        let currentSession = UUID(); session = currentSession
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.session == currentSession else { return }
                    switch state {
                    case .ready: if let port = self.listener?.port { self.endpoint = "http://127.0.0.1:\(port.rawValue)/mcp" }
                    case let .failed(error): self.error = error.localizedDescription; self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.session == currentSession, self.connections.count < 20 else { connection.cancel(); return }
                    let id = UUID(); self.connections[id] = connection
                    connection.start(queue: self.queue)
                    self.receive(connection, id: id, accumulated: Data(), session: currentSession)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard let self, self.session == currentSession else { return }
                        self.connections.removeValue(forKey: id)?.cancel()
                    }
                }
            }
            listener.start(queue: queue)
        } catch { self.error = error.localizedDescription; stop() }
    }

    func stop() {
        session = UUID()
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]; endpoint = nil; token = nil; store = nil
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data, session: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, receiveError in
            let combined = accumulated + (data ?? Data())
            Task { @MainActor in
                guard let self, self.session == session, self.connections[id] != nil else { connection.cancel(); return }
                if combined.count > 1024 * 1024 { self.send(connection, id: id, status: 413, body: Data()); return }
                guard let separator = combined.range(of: Data("\r\n\r\n".utf8)),
                      let header = String(data: combined[..<separator.lowerBound], encoding: .utf8) else {
                    if complete || receiveError != nil { self.send(connection, id: id, status: 400, body: Data()) }
                    else { self.receive(connection, id: id, accumulated: combined, session: session) }
                    return
                }
                var headers: [String: String] = [:]
                for line in header.components(separatedBy: "\r\n").dropFirst() {
                    if let colon = line.firstIndex(of: ":") { headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                }
                guard headers["origin"] == nil, headers["transfer-encoding"] == nil,
                      headers["authorization"] == "Bearer \(self.token ?? "")" else { self.send(connection, id: id, status: 403, body: Data()); return }
                let firstLine = header.components(separatedBy: "\r\n").first
                if firstLine == "GET /mcp HTTP/1.1" || firstLine == "DELETE /mcp HTTP/1.1" {
                    self.send(connection, id: id, status: 405, body: Data()); return
                }
                guard firstLine == "POST /mcp HTTP/1.1" else { self.send(connection, id: id, status: 404, body: Data()); return }
                guard let length = headers["content-length"].flatMap(Int.init), (0...1048576).contains(length) else { self.send(connection, id: id, status: 400, body: Data()); return }
                let body = Data(combined[separator.upperBound...])
                guard body.count >= length else {
                    if complete || receiveError != nil { self.send(connection, id: id, status: 400, body: Data()) }
                    else { self.receive(connection, id: id, accumulated: combined, session: session) }
                    return
                }
                do {
                    let value = try JSONSerialization.jsonObject(with: body.prefix(length))
                    if let batch = value as? [[String: Any]], !batch.isEmpty, batch.count <= 20 {
                        let responses = try batch.compactMap { try self.rpcResponse($0) }
                        self.send(connection, id: id, status: responses.isEmpty ? 202 : 200,
                                  body: responses.isEmpty ? Data() : try JSONSerialization.data(withJSONObject: responses))
                    } else {
                        guard let request = value as? [String: Any] else { throw LibraryError.invalid("Invalid JSON-RPC request.") }
                        let response = try self.rpcResponse(request)
                        self.send(connection, id: id, status: response == nil ? 202 : 200,
                                  body: try response.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
                    }
                } catch {
                    let request = (try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: Any]
                    let response: [String: Any] = ["jsonrpc": "2.0", "id": request?["id"] ?? NSNull(), "error": ["code": -32602, "message": error.localizedDescription]]
                    self.send(connection, id: id, status: 200, body: (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
                }
            }
        }
    }

    private func rpcResponse(_ request: [String: Any]) throws -> [String: Any]? {
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { throw LibraryError.invalid("Invalid JSON-RPC request.") }
        guard let id = request["id"] else { return nil }
        do {
            return ["jsonrpc": "2.0", "id": id, "result": try result(method: method, params: request["params"] as? [String: Any] ?? [:])]
        } catch {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": error.localizedDescription]]
        }
    }

    func result(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-03-26"
            let version = ["2025-03-26", "2025-06-18"].contains(requested) ? requested : "2025-03-26"
            return ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "PasteLite", "version": AppInfo.version]]
        case "ping": return [:]
        case "tools/list":
            let schema: [String: Any] = ["type": "object", "properties": ["query": ["type": "string", "maxLength": 256], "limit": ["type": "integer", "minimum": 1, "maximum": 30]], "additionalProperties": false]
            return ["tools": [
                ["name": "search_history", "description": "Read non-concealed clipboard history metadata and text. No write or paste operations.", "inputSchema": schema, "annotations": ["readOnlyHint": true]],
                ["name": "search_saved", "description": "Read saved-library names and text. No write or paste operations.", "inputSchema": schema, "annotations": ["readOnlyHint": true]]]]
        case "tools/call":
            guard let store else { throw LibraryError.unavailable }
            let name = params["name"] as? String
            guard name == "search_history" || name == "search_saved" else { throw LibraryError.invalid("Only read-only search tools are available.") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let query = arguments["query"] as? String ?? ""
            let limit = arguments["limit"] as? Int ?? 10
            guard query.count <= 256, (1...30).contains(limit) else { throw LibraryError.invalid("Query or limit is out of range.") }
            let candidates = name == "search_history" ? store.items : store.libraryItems.map(\.displayItem)
            let matches = candidates.filter {
                $0.kind != .concealed && !$0.isExpired && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.previewText.localizedCaseInsensitiveContains(query) || $0.recognizedText.localizedCaseInsensitiveContains(query))
            }.prefix(limit).map { item -> [String: Any] in
                ["id": item.id.uuidString, "name": item.title, "kind": item.kind.rawValue,
                 "source": item.sourceAppName ?? "", "text": String((item.kind == .image ? item.recognizedText : item.previewText).prefix(10000))]
            }
            let data = try JSONSerialization.data(withJSONObject: matches, options: [.sortedKeys])
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
        default: throw LibraryError.invalid("This MCP method is not supported.")
        }
    }

    private func send(_ connection: NWConnection, id: UUID, status: Int, body: Data) {
        let reason = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 403 ? "Forbidden" : status == 405 ? "Method Not Allowed" : status == 404 ? "Not Found" : status == 413 ? "Content Too Large" : "Bad Request"
        let allow = status == 405 ? "Allow: POST\r\n" : ""
        let response = Data("HTTP/1.1 \(status) \(reason)\r\n\(allow)Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections[id] = nil }
        })
    }
}
