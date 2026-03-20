import Foundation
import InsForgeCore
import Logging

/// Configuration options for the functions client.
public struct FunctionsOptions: Sendable {
    /// Direct functions/subhosting URL to try before the proxy URL.
    public let url: URL?

    /// Whether to derive and try the default `.functions.insforge.app` host when no explicit URL is provided.
    public let useSubhosting: Bool

    public init(
        url: URL? = nil,
        useSubhosting: Bool = true
    ) {
        self.url = url
        self.useSubhosting = useSubhosting
    }
}

/// Per-request options for function invocation.
public struct FunctionInvokeOptions: Sendable {
    /// HTTP method to use when invoking the function.
    public let method: HTTPMethod

    /// Additional headers to include with the request.
    public let headers: [String: String]

    public init(
        method: HTTPMethod = .post,
        headers: [String: String] = [:]
    ) {
        self.method = method
        self.headers = headers
    }
}

/// Functions client for invoking serverless functions
public actor FunctionsClient {
    private let url: URL
    private let directURL: URL?
    private let headersProvider: LockIsolated<[String: String]>
    private let httpClient: HTTPClient
    private let tokenRefreshHandler: (any TokenRefreshHandler)?
    private var logger: Logging.Logger { InsForgeLoggerFactory.shared }

    /// Get current headers (dynamically fetched to reflect auth state changes)
    private var headers: [String: String] {
        headersProvider.value
    }

    public init(
        url: URL,
        directURL: URL? = nil,
        headersProvider: LockIsolated<[String: String]>,
        tokenRefreshHandler: (any TokenRefreshHandler)? = nil
    ) {
        self.url = url
        self.directURL = directURL
        self.headersProvider = headersProvider
        self.httpClient = HTTPClient()
        self.tokenRefreshHandler = tokenRefreshHandler
    }

    /// Helper to execute HTTP request with optional auto-refresh
    private func executeRequest(
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

    private func makeRequestHeaders(options: FunctionInvokeOptions, hasBody: Bool) -> [String: String] {
        var requestHeaders = headers.merging(options.headers) { _, newValue in newValue }
        if hasBody, requestHeaders["Content-Type"] == nil {
            requestHeaders["Content-Type"] = "application/json"
        }
        return requestHeaders
    }

    private func performInvocationRequest(
        method: HTTPMethod,
        url endpoint: URL,
        headers: [String: String],
        body: Data?
    ) async throws -> HTTPResponse {
        logger.debug("\(method.rawValue) \(endpoint.absoluteString)")
        logger.trace("Request headers: \(headers.filter { $0.key != "Authorization" })")
        if let body, let bodyString = String(data: body, encoding: .utf8) {
            logger.trace("Request body: \(bodyString)")
        }

        let response = try await executeRequest(
            method,
            url: endpoint,
            headers: headers,
            body: body
        )

        logger.debug("Response: \(response.response.statusCode)")
        if let responseString = String(data: response.data, encoding: .utf8), !responseString.isEmpty {
            logger.trace("Response body: \(responseString)")
        }

        return response
    }

    private func invokeFunction(
        _ slug: String,
        options: FunctionInvokeOptions,
        body: Data?
    ) async throws -> HTTPResponse {
        let requestHeaders = makeRequestHeaders(options: options, hasBody: body != nil)

        if let directURL {
            let directEndpoint = directURL.appendingPathComponent(slug)
            do {
                return try await performInvocationRequest(
                    method: options.method,
                    url: directEndpoint,
                    headers: requestHeaders,
                    body: body
                )
            } catch let error as InsForgeError {
                if case .httpError(let statusCode, _, _, _) = error, statusCode == 404 {
                    logger.debug("Direct function route returned 404, falling back to proxy URL")
                } else {
                    throw error
                }
            }
        }

        let proxyEndpoint = url.appendingPathComponent(slug)
        return try await performInvocationRequest(
            method: options.method,
            url: proxyEndpoint,
            headers: requestHeaders,
            body: body
        )
    }

    /// Invoke a function
    public func invoke<T: Decodable>(
        _ slug: String,
        options: FunctionInvokeOptions = FunctionInvokeOptions(),
        body: [String: Any]? = nil
    ) async throws -> T {
        var requestBody: Data?
        if let body = body {
            requestBody = try JSONSerialization.data(withJSONObject: body)
        }

        let response = try await invokeFunction(slug, options: options, body: requestBody)
        return try response.decode(T.self)
    }

    /// Invoke a function with Encodable body
    public func invoke<I: Encodable, O: Decodable>(
        _ slug: String,
        options: FunctionInvokeOptions = FunctionInvokeOptions(),
        body: I
    ) async throws -> O {
        let encoder = JSONEncoder()
        let requestBody = try encoder.encode(body)

        let response = try await invokeFunction(slug, options: options, body: requestBody)
        let decoder = JSONDecoder()
        return try decoder.decode(O.self, from: response.data)
    }

    /// Invoke a function without expecting a response body
    public func invoke(
        _ slug: String,
        options: FunctionInvokeOptions = FunctionInvokeOptions(),
        body: [String: Any]? = nil
    ) async throws {
        var requestBody: Data?
        if let body = body {
            requestBody = try JSONSerialization.data(withJSONObject: body)
        }

        _ = try await invokeFunction(slug, options: options, body: requestBody)
    }
}
