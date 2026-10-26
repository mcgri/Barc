// Modified for Barc: loopback-only pages and a controllable real download, 2026-10-26.
import Foundation
import Network

/// All mutable networking state is confined to queue. Tests only read immutable
/// port data or schedule operations. The server never accepts remote clients.
final class MemoryHTTPFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "barc.memory.fixture")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var downloads: [NWConnection] = []
    static let downloadBytes = 1024 * 1024

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                receive(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [self] data, _, complete, error in
            let request = bytes + (data ?? Data())
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if !complete && error == nil && request.count < 65536 { receive(connection, bytes: request) }
                else { connection.cancel() }
                return
            }
            if text.hasPrefix("GET /download ") {
                downloads.append(connection)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=fixture.bin\r\nContent-Length: \(Self.downloadBytes)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + Data(repeating: 65, count: 1024), completion: .contentProcessed { _ in })
            } else {
                let draft = text.hasPrefix("GET /dirty ") ? "<textarea id='childDraft'></textarea><script>childDraft.value='A cross-origin draft';childDraft.dispatchEvent(new Event('input',{bubbles:true}));</script>" : ""
                let html = "<!doctype html><html><head><title>Memory HTTP fixture</title></head><body style='height:12000px'><p id='httpReady'>Loopback fixture</p>\(draft)</body></html>"
                let body = Data(html.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func finishDownloads() {
        queue.async { [self] in
            for connection in downloads {
                connection.send(content: Data(repeating: 65, count: Self.downloadBytes - 1024), completion: .contentProcessed { _ in connection.cancel() })
            }
            downloads.removeAll()
        }
    }
    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll(); downloads.removeAll()
        }
    }
}
