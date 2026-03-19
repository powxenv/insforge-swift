import Foundation

// MARK: - HTTPRequestExecutable

/// A protocol for types that can execute HTTP requests with optional automatic token refresh.
///
/// Conforming types must expose an `HTTPClient` and an optional `TokenRefreshHandler`.
/// The protocol extension provides a default `executeRequest` implementation that
/// delegates to `executeWithAutoRefresh` when a handler is present, and `execute` otherwise.
/// A protocol for types that can execute HTTP requests with optional automatic token refresh.
///
/// `httpClient` and `tokenRefreshHandler` are intentionally **not** part of the public API —
/// conforming types expose them as `internal let` (structs) or `nonisolated let` (actors),
/// so they remain invisible to SDK consumers even though the protocol itself is public.
public protocol HTTPRequestExecutable {
    var httpClient: HTTPClient { get }
    var tokenRefreshHandler: (any TokenRefreshHandler)? { get }
}

extension HTTPRequestExecutable {
    /// Executes an HTTP request with optional automatic token refresh on 401 errors.
    func executeRequest(
        _ method: HTTPMethod,
        url: URL,
        headers: [String: String],
        body: Data? = nil
    ) async throws -> HTTPResponse {
        if let handler = tokenRefreshHandler {
            return try await httpClient.executeWithAutoRefresh(
                method,
                url: url,
                headers: headers,
                body: body,
                refreshHandler: handler
            )
        } else {
            return try await httpClient.execute(
                method,
                url: url,
                headers: headers,
                body: body
            )
        }
    }
}
