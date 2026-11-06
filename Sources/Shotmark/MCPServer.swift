import Foundation
import Network

/// MCP по Streamable HTTP: POST /mcp, ответы обычным JSON. Только 127.0.0.1, токен в заголовке.
@MainActor
final class MCPServer {
    static let port: UInt16 = 47830
    let token: String
    private var listener: NWListener?

    init() {
        let url = Store.shared.root.appendingPathComponent("token")
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            token = t
        } else {
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            token = bytes.map { String(format: "%02x", $0) }.joined()
            FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    var addCommand: String {
        "claude mcp add --scope user --transport http shotmark http://127.0.0.1:\(MCPServer.port)/mcp --header \"Authorization: Bearer \(token)\""
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: MCPServer.port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { st in if case .failed(let e) = st { NSLog("Shotmark MCP: \(e)") } }
            l.start(queue: .main)
            listener = l
        } catch {
            NSLog("Shotmark MCP: не удалось открыть порт \(MCPServer.port): \(error)")
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        read(conn, Data())
    }

    private func read(_ conn: NWConnection, _ buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, eof, err in
            Task { @MainActor in
                guard let self else { return }
                var buf = buf
                if let data { buf.append(data) }
                if let req = HTTPRequest(buf) {
                    await self.handle(req, conn)
                } else if eof || err != nil || buf.count > 50 << 20 {
                    conn.cancel()
                } else {
                    self.read(conn, buf)
                }
            }
        }
    }

    private func reply(_ conn: NWConnection, _ code: Int, _ body: Data = Data(), extra: String = "") {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed"][code] ?? "Error"
        var head = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ req: HTTPRequest, _ conn: NWConnection) async {
        // защита от веб-страниц: браузер всегда шлёт Origin, а Host проверяем против DNS-rebinding
        let host = req.headers["host"] ?? ""
        guard req.headers["origin"] == nil, host.hasPrefix("127.0.0.1:") || host.hasPrefix("localhost:") else { return reply(conn, 403) }
        guard req.headers["authorization"] == "Bearer \(token)" else { return reply(conn, 401) }
        guard req.path.hasPrefix("/mcp") else { return reply(conn, 404) }
        guard req.method == "POST" else { return reply(conn, 405, extra: "Allow: POST\r\n") }
        guard let msg = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let method = msg["method"] as? String else {
            return reply(conn, 400, json(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]]))
        }
        guard let id = msg["id"] else { return reply(conn, 202) }   // уведомление
        let params = msg["params"] as? [String: Any] ?? [:]
        var out: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            out["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                             "capabilities": ["tools": [String: Any]()],
                             "serverInfo": ["name": "shotmark", "version": "0.1.0"],
                             "instructions": Tools.instructions]
        case "ping":
            out["result"] = [String: Any]()
        case "tools/list":
            out["result"] = ["tools": Tools.list]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                out["result"] = ["content": try await Tools.call(name, args)]
            } catch {
                out["result"] = ["content": [["type": "text", "text": "Ошибка: \(error.localizedDescription)"]], "isError": true]
            }
        default:
            out["error"] = ["code": -32601, "message": "method not found: \(method)"]
        }
        reply(conn, 200, json(out))
    }

    private func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
}

struct HTTPRequest {
    let method: String, path: String
    let headers: [String: String]
    let body: Data

    /// nil — запрос ещё не дочитан.
    init?(_ buf: Data) {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buf[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        var h: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(h["content-length"] ?? "0") ?? 0
        guard buf.count - sep.upperBound >= len else { return nil }
        method = first.count > 0 ? String(first[0]) : ""
        path = first.count > 1 ? String(first[1]) : ""
        headers = h
        body = buf[sep.upperBound..<sep.upperBound + len]
    }
}
