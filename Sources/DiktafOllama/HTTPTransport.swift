import Foundation

/// Sending one request, behind a protocol so the tests never open a socket.
///
/// The same arrangement as `ProcessRunner` in DiktafClaude: everything above
/// this line — the request body, the reading of the reply, the mapping of each
/// way the server can refuse onto a failure — is then testable offline.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real one.
struct URLSessionTransport: HTTPTransport {
    /// Ephemeral: nothing about a request to a server on this machine is worth
    /// a cookie or a cache entry on disk.
    private static let session = URLSession(configuration: .ephemeral)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
