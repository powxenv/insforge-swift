import Foundation
import InsForgeCore
import Logging

/// Count algorithm options for row counting in queries.
///
/// These options correspond to PostgreSQL's different counting strategies,
/// each with different performance characteristics.
public enum CountOption: String, Sendable {
    /// Exact count using `COUNT(*)`. Most accurate but slowest for large tables.
    case exact
    /// Planned count using PostgreSQL's query planner estimate. Fast but may be inaccurate.
    case planned
    /// Estimated count using statistics. Fastest but least accurate.
    case estimated
}

/// Full-text search operators supported by PostgREST.
public enum TextSearchType: String, Sendable {
    /// Native PostgreSQL full-text search syntax.
    case fullText = "fts"
    /// Plain-to-tsquery parsing.
    case plain = "plfts"
    /// Phrase-to-tsquery parsing.
    case phrase = "phfts"
    /// Websearch-style parsing.
    case websearch = "wfts"
}

/// Result containing both data and count from a query.
public struct QueryResult<T: Decodable>: Sendable where T: Sendable {
    /// The queried data records.
    public let data: [T]
    /// The total count of matching records (if count option was specified).
    public let count: Int?
}

/// Empty record type used for count-only queries.
private struct EmptyRecord: Decodable, Sendable {}

/// Configuration options for the database client.
///
/// Allows customization of JSON encoding and decoding behavior.
public struct DatabaseOptions: Sendable {
    /// The JSON encoder used for serializing requests.
    public let encoder: JSONEncoder
    /// The JSON decoder used for deserializing responses.
    public let decoder: JSONDecoder

    /// Creates database options with custom or default encoders.
    /// - Parameters:
    ///   - encoder: Optional custom JSON encoder. Defaults to ISO 8601 date encoding.
    ///   - decoder: Optional custom JSON decoder. Defaults to ISO 8601 date decoding with fractional seconds.
    public init(
        encoder: JSONEncoder? = nil,
        decoder: JSONDecoder? = nil
    ) {
        if let encoder = encoder {
            self.encoder = encoder
        } else {
            let defaultEncoder = JSONEncoder()
            defaultEncoder.dateEncodingStrategy = .iso8601
            self.encoder = defaultEncoder
        }

        if let decoder = decoder {
            self.decoder = decoder
        } else {
            let defaultDecoder = JSONDecoder()
            defaultDecoder.dateDecodingStrategy = iso8601WithFractionalSecondsDecodingStrategy()
            self.decoder = defaultDecoder
        }
    }
}

private struct DatabaseRequestContext: Sendable {
    let url: URL
    let headersProvider: LockIsolated<[String: String]>
    let httpClient: HTTPClient
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let tokenRefreshHandler: (any TokenRefreshHandler)?

    var logger: Logging.Logger { InsForgeLoggerFactory.shared }
    var headers: [String: String] { headersProvider.value }

    func tableURL(_ table: String) -> URL {
        url.appendingPathComponent("records").appendingPathComponent(table)
    }

    func rpcURL(_ function: String) -> URL {
        url.appendingPathComponent("rpc").appendingPathComponent(function)
    }
}

private struct ReadState: Sendable {
    var queryItems: [URLQueryItem] = []
    var countOption: CountOption?
    var head: Bool = false
}

private struct MutationState: Sendable {
    var queryItems: [URLQueryItem] = []
}

private enum DatabaseBuilderSupport {
    static func cleanSelectColumns(_ columns: String) -> String {
        var quoted = false
        return columns.compactMap { char -> String? in
            if char.isWhitespace, !quoted {
                return nil
            }
            if char == "\"" {
                quoted.toggle()
            }
            return String(char)
        }.joined()
    }

    static func postgresArrayLiteral(from values: [Any]) -> String {
        "{\(values.map { "\($0)" }.joined(separator: ","))}"
    }

    static func parseCount(from response: HTTPURLResponse) -> Int? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let slashIndex = contentRange.lastIndex(of: "/") else {
            return nil
        }

        let countString = String(contentRange[contentRange.index(after: slashIndex)...])
        return Int(countString)
    }

    static func buildURL(
        baseURL: URL,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let requestURL = components?.url else {
            throw InsForgeError.invalidURL
        }

        return requestURL
    }
}

/// Database client for PostgREST-style operations.
///
/// Provides a fluent API for querying and manipulating data in PostgreSQL databases
/// through the InsForge API.
public actor DatabaseClient {
    private let context: DatabaseRequestContext

    /// Creates a new database client.
    /// - Parameters:
    ///   - url: The base URL of the database API.
    ///   - headersProvider: A thread-safe provider for HTTP headers.
    ///   - options: Optional database configuration options.
    ///   - tokenRefreshHandler: Optional handler for automatic token refresh on 401 errors.
    public init(
        url: URL,
        headersProvider: LockIsolated<[String: String]>,
        options: DatabaseOptions = DatabaseOptions(),
        tokenRefreshHandler: (any TokenRefreshHandler)? = nil,
        retry: RetryConfiguration = .default
    ) {
        self.context = DatabaseRequestContext(
            url: url,
            headersProvider: headersProvider,
            httpClient: HTTPClient(retry: retry),
            encoder: options.encoder,
            decoder: options.decoder,
            tokenRefreshHandler: tokenRefreshHandler
        )
    }

    /// Creates a table-scoped builder for the specified table.
    /// - Parameter table: The name of the table to query.
    /// - Returns: A `TableQueryBuilder` for constructing read and mutation queries.
    public func from(_ table: String) -> TableQueryBuilder {
        TableQueryBuilder(
            url: context.tableURL(table),
            context: context
        )
    }

    /// Call a PostgreSQL function (RPC).
    ///
    /// - Parameters:
    ///   - fn: The name of the database function to call.
    ///   - args: Optional dictionary of arguments to pass to the function.
    /// - Returns: An `RPCBuilder` for executing the RPC call.
    public func rpc(_ fn: String, args: [String: Any]? = nil) -> RPCBuilder {
        RPCBuilder(
            url: context.rpcURL(fn),
            headersProvider: context.headersProvider,
            httpClient: context.httpClient,
            encoder: context.encoder,
            decoder: context.decoder,
            args: args,
            tokenRefreshHandler: context.tokenRefreshHandler
        )
    }
}

/// Table-scoped entry point for database operations.
///
/// This type intentionally separates read queries from mutation queries.
/// Read-only modifiers such as `order`, `limit`, and `select` are not available
/// once you move into a mutation flow like `update(...)` or `delete()`.
public struct TableQueryBuilder: Sendable {
    private let url: URL
    private let context: DatabaseRequestContext

    fileprivate init(url: URL, context: DatabaseRequestContext) {
        self.url = url
        self.context = context
    }

    /// Begins a read query with an optional select clause.
    public func select(
        _ columns: String = "*",
        head: Bool = false,
        count: CountOption? = nil
    ) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).select(columns, head: head, count: count)
    }

    /// Begins a read query with an equality filter.
    public func eq(_ column: String, value: Any) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).eq(column, value: value)
    }

    /// Begins a read query with an inequality filter.
    public func neq(_ column: String, value: Any) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).neq(column, value: value)
    }

    /// Begins a read query with a greater-than filter.
    public func gt(_ column: String, value: Any) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).gt(column, value: value)
    }

    /// Begins a read query with a greater-than-or-equal filter.
    public func gte(_ column: String, value: Any) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).gte(column, value: value)
    }

    /// Begins a read query with a less-than filter.
    public func lt(_ column: String, value: Any) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).lt(column, value: value)
    }

    /// Begins a read query with a less-than-or-equal filter.
    public func lte(_ column: String, value: Any) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).lte(column, value: value)
    }

    /// Begins a read query with grouped OR filters.
    public func or(_ filters: String...) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).or(filters)
    }

    /// Begins a read query with grouped OR filters.
    public func or(_ filters: [String]) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).or(filters)
    }

    /// Begins a read query with grouped AND filters.
    public func and(_ filters: String...) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).and(filters)
    }

    /// Begins a read query with grouped AND filters.
    public func and(_ filters: [String]) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).and(filters)
    }

    /// Begins a read query with a custom PostgREST filter operator.
    public func filter(_ column: String, `operator`: String, value: Any) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).filter(column, operator: `operator`, value: value)
    }

    /// Begins a read query with a negated PostgREST filter operator.
    public func not(_ column: String, `operator`: String, value: Any) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).not(column, operator: `operator`, value: value)
    }

    /// Begins a read query with a pattern-matching filter.
    public func like(_ column: String, pattern: String) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).like(column, pattern: pattern)
    }

    /// Begins a read query with a case-insensitive pattern-matching filter.
    public func ilike(_ column: String, pattern: String) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).ilike(column, pattern: pattern)
    }

    /// Begins a read query with an IN filter.
    public func `in`(_ column: String, values: [Any]) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).in(column, values: values)
    }

    /// Begins a read query with an IS filter.
    public func `is`(_ column: String, value: Bool?) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).is(column, value: value)
    }

    /// Begins a read query with a contains filter for array-like columns.
    public func contains(_ column: String, values: [Any]) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).contains(column, values: values)
    }

    /// Begins a read query with a contained-by filter for array-like columns.
    public func containedBy(_ column: String, values: [Any]) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).containedBy(column, values: values)
    }

    /// Begins a read query with a full-text search filter.
    public func textSearch(
        _ column: String,
        query: String,
        config: String? = nil,
        type: TextSearchType = .plain
    ) -> ReadQueryBuilder {
        ReadQueryBuilder(url: url, context: context).textSearch(column, query: query, config: config, type: type)
    }

    /// Inserts multiple records into the table.
    public func insert<T: Encodable>(_ values: [T]) async throws -> [T] where T: Decodable {
        let requestURL = try DatabaseBuilderSupport.buildURL(baseURL: url, queryItems: [])
        let data = try context.encoder.encode(values)

        var requestHeaders = context.headers
        requestHeaders["Content-Type"] = "application/json"
        requestHeaders["Prefer"] = "return=representation"

        context.logger.debug("POST \(requestURL.absoluteString)")
        context.logger.trace("Request headers: \(requestHeaders.filter { $0.key != "Authorization" })")
        if let bodyString = String(data: data, encoding: .utf8) {
            context.logger.trace("Request body: \(bodyString)")
        }

        let response = try await executeRequest(
            .post,
            url: requestURL,
            headers: requestHeaders,
            body: data,
            httpClient: context.httpClient,
            tokenRefreshHandler: context.tokenRefreshHandler
        )

        context.logger.debug("Response: \(response.response.statusCode)")
        if let responseString = String(data: response.data, encoding: .utf8) {
            context.logger.trace("Response body: \(responseString)")
        }

        let result = try context.decoder.decode([T].self, from: response.data)
        context.logger.debug("Inserted \(result.count) record(s)")
        return result
    }

    /// Inserts a single record into the table.
    public func insert<T: Encodable>(_ value: T) async throws -> T where T: Decodable {
        let results: [T] = try await insert([value])
        guard let first = results.first else {
            throw InsForgeError.unknown("Insert failed")
        }
        return first
    }

    /// Inserts or updates multiple records using PostgREST upsert semantics.
    public func upsert<T: Encodable>(
        _ values: [T],
        onConflict: String? = nil,
        ignoreDuplicates: Bool = false
    ) async throws -> [T] where T: Decodable {
        let queryItems = onConflict.map { [URLQueryItem(name: "on_conflict", value: $0)] } ?? []
        let requestURL = try DatabaseBuilderSupport.buildURL(baseURL: url, queryItems: queryItems)
        let data = try context.encoder.encode(values)

        var requestHeaders = context.headers
        requestHeaders["Content-Type"] = "application/json"
        let resolution = ignoreDuplicates ? "ignore-duplicates" : "merge-duplicates"
        requestHeaders["Prefer"] = "resolution=\(resolution),return=representation"

        context.logger.debug("POST \(requestURL.absoluteString)")
        context.logger.trace("Request headers: \(requestHeaders.filter { $0.key != "Authorization" })")
        if let bodyString = String(data: data, encoding: .utf8) {
            context.logger.trace("Request body: \(bodyString)")
        }

        let response = try await executeRequest(
            .post,
            url: requestURL,
            headers: requestHeaders,
            body: data,
            httpClient: context.httpClient,
            tokenRefreshHandler: context.tokenRefreshHandler
        )

        context.logger.debug("Response: \(response.response.statusCode)")
        if let responseString = String(data: response.data, encoding: .utf8) {
            context.logger.trace("Response body: \(responseString)")
        }

        let result = try context.decoder.decode([T].self, from: response.data)
        context.logger.debug("Upserted \(result.count) record(s)")
        return result
    }

    /// Inserts or updates a single record using PostgREST upsert semantics.
    public func upsert<T: Encodable>(
        _ value: T,
        onConflict: String? = nil,
        ignoreDuplicates: Bool = false
    ) async throws -> T where T: Decodable {
        let results: [T] = try await upsert(
            [value],
            onConflict: onConflict,
            ignoreDuplicates: ignoreDuplicates
        )
        guard let first = results.first else {
            if ignoreDuplicates {
                return value
            }

            throw InsForgeError.unknown("Upsert failed")
        }
        return first
    }

    /// Begins an update mutation. Only mutation-safe filter methods are available after this point.
    public func update<T: Encodable & Sendable>(_ values: T) -> UpdateQueryBuilder<T> {
        UpdateQueryBuilder(url: url, context: context, values: values)
    }

    /// Begins a delete mutation. Only mutation-safe filter methods are available after this point.
    public func delete() -> DeleteQueryBuilder {
        DeleteQueryBuilder(url: url, context: context)
    }
}

/// Read-only query builder.
///
/// This builder contains modifiers that are valid for SELECT-style operations.
public struct ReadQueryBuilder: Sendable {
    private let url: URL
    private let context: DatabaseRequestContext
    private var state = ReadState()

    fileprivate init(url: URL, context: DatabaseRequestContext) {
        self.url = url
        self.context = context
    }

    private func appendingQueryItem(name: String, value: String) -> ReadQueryBuilder {
        var builder = self
        builder.state.queryItems.append(URLQueryItem(name: name, value: value))
        return builder
    }

    private func appendingGroupedFilters(name: String, filters: [String]) -> ReadQueryBuilder {
        guard !filters.isEmpty else { return self }
        return appendingQueryItem(name: name, value: "(\(filters.joined(separator: ",")))")
    }

    private func buildURL() throws -> URL {
        try DatabaseBuilderSupport.buildURL(baseURL: url, queryItems: state.queryItems)
    }

    private func withDefaultSelectIfNeeded() -> ReadQueryBuilder {
        guard !state.queryItems.contains(where: { $0.name == "select" }) else {
            return self
        }

        var builder = self
        builder.state.queryItems.append(URLQueryItem(name: "select", value: "*"))
        return builder
    }

    /// Selects specific columns to return.
    /// - Parameters:
    ///   - columns: Comma-separated column names, or "*" for all columns.
    ///   - head: If `true`, returns only the count without data.
    ///   - count: The count algorithm to use for including total row count in response.
    /// - Returns: A new `ReadQueryBuilder` with the select clause applied.
    public func select(
        _ columns: String = "*",
        head: Bool = false,
        count: CountOption? = nil
    ) -> ReadQueryBuilder {
        var builder = self
        builder.state.queryItems.removeAll { $0.name == "select" }
        builder.state.queryItems.append(
            URLQueryItem(name: "select", value: DatabaseBuilderSupport.cleanSelectColumns(columns))
        )
        builder.state.head = head
        builder.state.countOption = count
        return builder
    }

    /// Filters by equality.
    /// - Parameters:
    ///   - column: The column name to filter on.
    ///   - value: The value to match.
    /// - Returns: A new `ReadQueryBuilder` with the filter applied.
    public func eq(_ column: String, value: Any) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "eq.\(value)")
    }

    /// Filters by inequality (not equal).
    /// - Parameters:
    ///   - column: The column name to filter on.
    ///   - value: The value to exclude.
    /// - Returns: A new `ReadQueryBuilder` with the filter applied.
    public func neq(_ column: String, value: Any) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "neq.\(value)")
    }

    /// Filters by greater than comparison.
    /// - Parameters:
    ///   - column: The column name to filter on.
    ///   - value: The threshold value.
    /// - Returns: A new `ReadQueryBuilder` with the filter applied.
    public func gt(_ column: String, value: Any) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "gt.\(value)")
    }

    /// Filters by greater than or equal comparison.
    /// - Parameters:
    ///   - column: The column name to filter on.
    ///   - value: The threshold value.
    /// - Returns: A new `ReadQueryBuilder` with the filter applied.
    public func gte(_ column: String, value: Any) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "gte.\(value)")
    }

    /// Filters by less than comparison.
    /// - Parameters:
    ///   - column: The column name to filter on.
    ///   - value: The threshold value.
    /// - Returns: A new `ReadQueryBuilder` with the filter applied.
    public func lt(_ column: String, value: Any) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "lt.\(value)")
    }

    /// Filters by less than or equal comparison.
    /// - Parameters:
    ///   - column: The column name to filter on.
    ///   - value: The threshold value.
    /// - Returns: A new `ReadQueryBuilder` with the filter applied.
    public func lte(_ column: String, value: Any) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "lte.\(value)")
    }

    /// Applies OR grouping to multiple filters.
    /// - Parameter filters: Raw PostgREST filter expressions.
    /// - Returns: A new `ReadQueryBuilder` with grouped OR filters.
    public func or(_ filters: String...) -> ReadQueryBuilder {
        or(filters)
    }

    /// Applies OR grouping to multiple filters.
    /// - Parameter filters: Raw PostgREST filter expressions.
    /// - Returns: A new `ReadQueryBuilder` with grouped OR filters.
    public func or(_ filters: [String]) -> ReadQueryBuilder {
        appendingGroupedFilters(name: "or", filters: filters)
    }

    /// Applies AND grouping to multiple filters.
    /// - Parameter filters: Raw PostgREST filter expressions.
    /// - Returns: A new `ReadQueryBuilder` with grouped AND filters.
    public func and(_ filters: String...) -> ReadQueryBuilder {
        and(filters)
    }

    /// Applies AND grouping to multiple filters.
    /// - Parameter filters: Raw PostgREST filter expressions.
    /// - Returns: A new `ReadQueryBuilder` with grouped AND filters.
    public func and(_ filters: [String]) -> ReadQueryBuilder {
        appendingGroupedFilters(name: "and", filters: filters)
    }

    /// Applies a custom PostgREST filter operator.
    /// - Parameters:
    ///   - column: Column name to filter.
    ///   - operator: Raw PostgREST filter operator.
    ///   - value: Preformatted filter value.
    /// - Returns: A new `ReadQueryBuilder` with the custom filter applied.
    public func filter(_ column: String, `operator`: String, value: Any) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "\(`operator`).\(value)")
    }

    /// Applies a negated PostgREST filter operator.
    /// - Parameters:
    ///   - column: Column name to filter.
    ///   - operator: Raw PostgREST filter operator.
    ///   - value: Preformatted filter value.
    /// - Returns: A new `ReadQueryBuilder` with the negated filter applied.
    public func not(_ column: String, `operator`: String, value: Any) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "not.\(`operator`).\(value)")
    }

    /// Orders results by a column.
    /// - Parameters:
    ///   - column: The column name to order by.
    ///   - ascending: Whether to sort ascending. Defaults to `true`.
    /// - Returns: A new `ReadQueryBuilder` with ordering applied.
    public func order(_ column: String, ascending: Bool = true) -> ReadQueryBuilder {
        let direction = ascending ? "asc" : "desc"
        return appendingQueryItem(name: "order", value: "\(column).\(direction)")
    }

    /// Limits the number of results returned.
    /// - Parameter count: The maximum number of results.
    /// - Returns: A new `ReadQueryBuilder` with the limit applied.
    public func limit(_ count: Int) -> ReadQueryBuilder {
        appendingQueryItem(name: "limit", value: "\(count)")
    }

    /// Offsets results for pagination.
    /// - Parameter count: The number of results to skip.
    /// - Returns: A new `ReadQueryBuilder` with the offset applied.
    public func offset(_ count: Int) -> ReadQueryBuilder {
        appendingQueryItem(name: "offset", value: "\(count)")
    }

    /// Applies range-based pagination (from and to are inclusive).
    /// - Parameters:
    ///   - from: Starting index (0-based).
    ///   - to: Ending index (inclusive).
    /// - Returns: A new `ReadQueryBuilder` with range applied.
    public func range(from: Int, to: Int) -> ReadQueryBuilder {
        var builder = self
        builder.state.queryItems.append(URLQueryItem(name: "offset", value: "\(from)"))
        builder.state.queryItems.append(URLQueryItem(name: "limit", value: "\(to - from + 1)"))
        return builder
    }

    /// Filters by pattern matching (case-sensitive).
    /// - Parameters:
    ///   - column: Column name to filter.
    ///   - pattern: Pattern to match (use % as wildcard).
    /// - Returns: A new `ReadQueryBuilder` with like filter.
    public func like(_ column: String, pattern: String) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "like.\(pattern)")
    }

    /// Filters by pattern matching (case-insensitive).
    /// - Parameters:
    ///   - column: Column name to filter.
    ///   - pattern: Pattern to match (use % as wildcard).
    /// - Returns: A new `ReadQueryBuilder` with ilike filter.
    public func ilike(_ column: String, pattern: String) -> ReadQueryBuilder {
        appendingQueryItem(name: column, value: "ilike.\(pattern)")
    }

    /// Filters where column value is in an array.
    /// - Parameters:
    ///   - column: Column name to filter.
    ///   - values: Array of values to match.
    /// - Returns: A new `ReadQueryBuilder` with in filter.
    public func `in`(_ column: String, values: [Any]) -> ReadQueryBuilder {
        let valueString = values.map { "\($0)" }.joined(separator: ",")
        return appendingQueryItem(name: column, value: "in.(\(valueString))")
    }

    /// Filters for null/boolean checks.
    /// - Parameters:
    ///   - column: Column name to filter.
    ///   - value: Value to check (null if nil, or true/false).
    /// - Returns: A new `ReadQueryBuilder` with is filter.
    public func `is`(_ column: String, value: Bool?) -> ReadQueryBuilder {
        let valueString: String
        if let boolValue = value {
            valueString = boolValue ? "true" : "false"
        } else {
            valueString = "null"
        }
        return appendingQueryItem(name: column, value: "is.\(valueString)")
    }

    /// Filters where the column contains all specified array values.
    /// - Parameters:
    ///   - column: Column name to filter.
    ///   - values: Values to match inside the array column.
    /// - Returns: A new `ReadQueryBuilder` with the contains filter applied.
    public func contains(_ column: String, values: [Any]) -> ReadQueryBuilder {
        appendingQueryItem(
            name: column,
            value: "cs.\(DatabaseBuilderSupport.postgresArrayLiteral(from: values))"
        )
    }

    /// Filters where the column is contained by the specified array values.
    /// - Parameters:
    ///   - column: Column name to filter.
    ///   - values: Superset values to compare against.
    /// - Returns: A new `ReadQueryBuilder` with the contained-by filter applied.
    public func containedBy(_ column: String, values: [Any]) -> ReadQueryBuilder {
        appendingQueryItem(
            name: column,
            value: "cd.\(DatabaseBuilderSupport.postgresArrayLiteral(from: values))"
        )
    }

    /// Applies a full-text search filter.
    /// - Parameters:
    ///   - column: Text-searchable column.
    ///   - query: Search query.
    ///   - config: Optional text search configuration.
    ///   - type: Text search parsing strategy.
    /// - Returns: A new `ReadQueryBuilder` with the text search filter applied.
    public func textSearch(
        _ column: String,
        query: String,
        config: String? = nil,
        type: TextSearchType = .plain
    ) -> ReadQueryBuilder {
        let value: String
        if let config, !config.isEmpty {
            value = "\(type.rawValue)(\(config)).\(query)"
        } else {
            value = "\(type.rawValue).\(query)"
        }

        return appendingQueryItem(name: column, value: value)
    }

    /// Executes a SELECT query and returns decoded results.
    /// - Returns: An array of decoded objects.
    /// - Throws: `InsForgeError` if the query fails.
    public func execute<T: Decodable & Sendable>() async throws -> [T] {
        let result: QueryResult<T> = try await executeWithCount()
        return result.data
    }

    /// Executes a SELECT query and returns results with optional count.
    /// - Returns: A `QueryResult` containing data and optional count.
    /// - Throws: `InsForgeError` if the query fails.
    public func executeWithCount<T: Decodable & Sendable>() async throws -> QueryResult<T> {
        let requestURL = try buildURL()

        var requestHeaders = context.headers
        if let countOpt = state.countOption {
            requestHeaders["Prefer"] = "count=\(countOpt.rawValue)"
        }

        let method: HTTPMethod = state.head ? .head : .get

        context.logger.debug("\(method.rawValue) \(requestURL.absoluteString)")
        context.logger.trace("Request headers: \(requestHeaders.filter { $0.key != "Authorization" })")

        let response = try await executeRequest(
            method,
            url: requestURL,
            headers: requestHeaders,
            httpClient: context.httpClient,
            tokenRefreshHandler: context.tokenRefreshHandler
        )

        context.logger.debug("Response: \(response.response.statusCode)")
        if let responseString = String(data: response.data, encoding: .utf8) {
            context.logger.trace("Response body: \(responseString)")
        }

        let totalCount = DatabaseBuilderSupport.parseCount(from: response.response)
        if let contentRange = response.response.value(forHTTPHeaderField: "Content-Range") {
            context.logger.trace("Content-Range: \(contentRange), count: \(totalCount ?? -1)")
        }

        if state.head {
            return QueryResult(data: [], count: totalCount)
        }

        let data = try context.decoder.decode([T].self, from: response.data)
        context.logger.debug("Decoded \(data.count) record(s)")
        return QueryResult(data: data, count: totalCount)
    }

    /// Executes a count-only query (HEAD request).
    /// - Parameter countOption: The count algorithm to use. Defaults to `.exact`.
    /// - Returns: The total count of matching records.
    /// - Throws: `InsForgeError` if the query fails.
    public func count(_ countOption: CountOption = .exact) async throws -> Int {
        var builder = withDefaultSelectIfNeeded()
        builder.state.head = true
        builder.state.countOption = countOption

        let result: QueryResult<EmptyRecord> = try await builder.executeWithCount()
        return result.count ?? 0
    }

    /// Executes a SELECT query and validates that exactly one record is returned.
    /// - Returns: A single decoded object.
    /// - Throws: `InsForgeError.validationError` if zero or multiple records are returned.
    public func single<T: Decodable & Sendable>() async throws -> T {
        let builder = withDefaultSelectIfNeeded()
        let requestURL = try builder.buildURL()

        var requestHeaders = context.headers
        requestHeaders["Accept"] = "application/vnd.pgrst.object+json"

        context.logger.debug("GET \(requestURL.absoluteString)")
        context.logger.trace("Request headers: \(requestHeaders.filter { $0.key != "Authorization" })")

        do {
            let response = try await executeRequest(
                .get,
                url: requestURL,
                headers: requestHeaders,
                httpClient: context.httpClient,
                tokenRefreshHandler: context.tokenRefreshHandler
            )

            context.logger.debug("Response: \(response.response.statusCode)")
            if let responseString = String(data: response.data, encoding: .utf8) {
                context.logger.trace("Response body: \(responseString)")
            }

            let record = try builder.context.decoder.decode(T.self, from: response.data)
            context.logger.debug("Decoded singular record")
            return record
        } catch let error as InsForgeError {
            if case .httpError(let statusCode, let message, _, _) = error, statusCode == 406 {
                throw InsForgeError.validationError(message)
            }

            throw error
        }
    }
}

private protocol MutationFilteringBuilder: Sendable {
    var url: URL { get }
    var context: DatabaseRequestContext { get }
    var state: MutationState { get set }
}

private extension MutationFilteringBuilder {
    func appendingQueryItem(name: String, value: String) -> Self {
        var builder = self
        builder.state.queryItems.append(URLQueryItem(name: name, value: value))
        return builder
    }

    func appendingGroupedFilters(name: String, filters: [String]) -> Self {
        guard !filters.isEmpty else { return self }
        return appendingQueryItem(name: name, value: "(\(filters.joined(separator: ",")))")
    }

    func buildURL() throws -> URL {
        try DatabaseBuilderSupport.buildURL(baseURL: url, queryItems: state.queryItems)
    }
}

/// Mutation builder for update operations.
///
/// This builder intentionally exposes only filter methods and execution,
/// not read-only modifiers like `order`, `limit`, or `select`.
public struct UpdateQueryBuilder<Value: Encodable & Sendable>: MutationFilteringBuilder {
    fileprivate let url: URL
    fileprivate let context: DatabaseRequestContext
    fileprivate var state = MutationState()
    private let values: Value

    fileprivate init(url: URL, context: DatabaseRequestContext, values: Value) {
        self.url = url
        self.context = context
        self.values = values
    }

    /// Filters by equality.
    /// - Parameters:
    ///   - column: The column name to filter on.
    ///   - value: The value to match.
    /// - Returns: A new `UpdateQueryBuilder` with the filter applied.
    public func eq(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "eq.\(value)") }
    /// Filters by inequality (not equal).
    public func neq(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "neq.\(value)") }
    /// Filters by greater than comparison.
    public func gt(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "gt.\(value)") }
    /// Filters by greater than or equal comparison.
    public func gte(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "gte.\(value)") }
    /// Filters by less than comparison.
    public func lt(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "lt.\(value)") }
    /// Filters by less than or equal comparison.
    public func lte(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "lte.\(value)") }
    /// Applies OR grouping to multiple filters.
    public func or(_ filters: String...) -> Self { or(filters) }
    /// Applies OR grouping to multiple filters.
    public func or(_ filters: [String]) -> Self { appendingGroupedFilters(name: "or", filters: filters) }
    /// Applies AND grouping to multiple filters.
    public func and(_ filters: String...) -> Self { and(filters) }
    /// Applies AND grouping to multiple filters.
    public func and(_ filters: [String]) -> Self { appendingGroupedFilters(name: "and", filters: filters) }
    /// Applies a custom PostgREST filter operator.
    public func filter(_ column: String, `operator`: String, value: Any) -> Self { appendingQueryItem(name: column, value: "\(`operator`).\(value)") }
    /// Applies a negated PostgREST filter operator.
    public func not(_ column: String, `operator`: String, value: Any) -> Self { appendingQueryItem(name: column, value: "not.\(`operator`).\(value)") }
    /// Filters by pattern matching (case-sensitive).
    public func like(_ column: String, pattern: String) -> Self { appendingQueryItem(name: column, value: "like.\(pattern)") }
    /// Filters by pattern matching (case-insensitive).
    public func ilike(_ column: String, pattern: String) -> Self { appendingQueryItem(name: column, value: "ilike.\(pattern)") }
    /// Filters where column value is in an array.
    public func `in`(_ column: String, values: [Any]) -> Self {
        appendingQueryItem(name: column, value: "in.(\(values.map { "\($0)" }.joined(separator: ",")))")
    }
    /// Filters for null/boolean checks.
    public func `is`(_ column: String, value: Bool?) -> Self {
        let valueString = value.map { $0 ? "true" : "false" } ?? "null"
        return appendingQueryItem(name: column, value: "is.\(valueString)")
    }
    /// Filters where the column contains all specified array values.
    public func contains(_ column: String, values: [Any]) -> Self {
        appendingQueryItem(name: column, value: "cs.\(DatabaseBuilderSupport.postgresArrayLiteral(from: values))")
    }
    /// Filters where the column is contained by the specified array values.
    public func containedBy(_ column: String, values: [Any]) -> Self {
        appendingQueryItem(name: column, value: "cd.\(DatabaseBuilderSupport.postgresArrayLiteral(from: values))")
    }
    /// Applies a full-text search filter.
    public func textSearch(
        _ column: String,
        query: String,
        config: String? = nil,
        type: TextSearchType = .plain
    ) -> Self {
        let value: String
        if let config, !config.isEmpty {
            value = "\(type.rawValue)(\(config)).\(query)"
        } else {
            value = "\(type.rawValue).\(query)"
        }
        return appendingQueryItem(name: column, value: value)
    }

    /// Executes the update query and returns updated rows.
    /// - Returns: An array of decoded updated objects.
    /// - Throws: `InsForgeError` if the mutation fails.
    public func execute<T: Decodable & Sendable>() async throws -> [T] {
        let requestURL = try buildURL()
        let data = try context.encoder.encode(values)

        var requestHeaders = context.headers
        requestHeaders["Content-Type"] = "application/json"
        requestHeaders["Prefer"] = "return=representation"

        context.logger.debug("PATCH \(requestURL.absoluteString)")
        context.logger.trace("Request headers: \(requestHeaders.filter { $0.key != "Authorization" })")
        if let bodyString = String(data: data, encoding: .utf8) {
            context.logger.trace("Request body: \(bodyString)")
        }

        let response = try await executeRequest(
            .patch,
            url: requestURL,
            headers: requestHeaders,
            body: data,
            httpClient: context.httpClient,
            tokenRefreshHandler: context.tokenRefreshHandler
        )

        context.logger.debug("Response: \(response.response.statusCode)")
        if let responseString = String(data: response.data, encoding: .utf8) {
            context.logger.trace("Response body: \(responseString)")
        }

        let result = try context.decoder.decode([T].self, from: response.data)
        context.logger.debug("Updated \(result.count) record(s)")
        return result
    }
}

/// Mutation builder for delete operations.
///
/// This builder intentionally exposes only filter methods and execution,
/// not read-only modifiers like `order`, `limit`, or `select`.
public struct DeleteQueryBuilder: MutationFilteringBuilder {
    fileprivate let url: URL
    fileprivate let context: DatabaseRequestContext
    fileprivate var state = MutationState()

    fileprivate init(url: URL, context: DatabaseRequestContext) {
        self.url = url
        self.context = context
    }

    /// Filters by equality.
    /// - Parameters:
    ///   - column: The column name to filter on.
    ///   - value: The value to match.
    /// - Returns: A new `DeleteQueryBuilder` with the filter applied.
    public func eq(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "eq.\(value)") }
    /// Filters by inequality (not equal).
    public func neq(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "neq.\(value)") }
    /// Filters by greater than comparison.
    public func gt(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "gt.\(value)") }
    /// Filters by greater than or equal comparison.
    public func gte(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "gte.\(value)") }
    /// Filters by less than comparison.
    public func lt(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "lt.\(value)") }
    /// Filters by less than or equal comparison.
    public func lte(_ column: String, value: Any) -> Self { appendingQueryItem(name: column, value: "lte.\(value)") }
    /// Applies OR grouping to multiple filters.
    public func or(_ filters: String...) -> Self { or(filters) }
    /// Applies OR grouping to multiple filters.
    public func or(_ filters: [String]) -> Self { appendingGroupedFilters(name: "or", filters: filters) }
    /// Applies AND grouping to multiple filters.
    public func and(_ filters: String...) -> Self { and(filters) }
    /// Applies AND grouping to multiple filters.
    public func and(_ filters: [String]) -> Self { appendingGroupedFilters(name: "and", filters: filters) }
    /// Applies a custom PostgREST filter operator.
    public func filter(_ column: String, `operator`: String, value: Any) -> Self { appendingQueryItem(name: column, value: "\(`operator`).\(value)") }
    /// Applies a negated PostgREST filter operator.
    public func not(_ column: String, `operator`: String, value: Any) -> Self { appendingQueryItem(name: column, value: "not.\(`operator`).\(value)") }
    /// Filters by pattern matching (case-sensitive).
    public func like(_ column: String, pattern: String) -> Self { appendingQueryItem(name: column, value: "like.\(pattern)") }
    /// Filters by pattern matching (case-insensitive).
    public func ilike(_ column: String, pattern: String) -> Self { appendingQueryItem(name: column, value: "ilike.\(pattern)") }
    /// Filters where column value is in an array.
    public func `in`(_ column: String, values: [Any]) -> Self {
        appendingQueryItem(name: column, value: "in.(\(values.map { "\($0)" }.joined(separator: ",")))")
    }
    /// Filters for null/boolean checks.
    public func `is`(_ column: String, value: Bool?) -> Self {
        let valueString = value.map { $0 ? "true" : "false" } ?? "null"
        return appendingQueryItem(name: column, value: "is.\(valueString)")
    }
    /// Filters where the column contains all specified array values.
    public func contains(_ column: String, values: [Any]) -> Self {
        appendingQueryItem(name: column, value: "cs.\(DatabaseBuilderSupport.postgresArrayLiteral(from: values))")
    }
    /// Filters where the column is contained by the specified array values.
    public func containedBy(_ column: String, values: [Any]) -> Self {
        appendingQueryItem(name: column, value: "cd.\(DatabaseBuilderSupport.postgresArrayLiteral(from: values))")
    }
    /// Applies a full-text search filter.
    public func textSearch(
        _ column: String,
        query: String,
        config: String? = nil,
        type: TextSearchType = .plain
    ) -> Self {
        let value: String
        if let config, !config.isEmpty {
            value = "\(type.rawValue)(\(config)).\(query)"
        } else {
            value = "\(type.rawValue).\(query)"
        }
        return appendingQueryItem(name: column, value: value)
    }

    /// Executes the delete query.
    /// - Throws: `InsForgeError` if the mutation fails.
    public func execute() async throws {
        let requestURL = try buildURL()

        context.logger.debug("DELETE \(requestURL.absoluteString)")
        context.logger.trace("Request headers: \(context.headers.filter { $0.key != "Authorization" })")

        let response = try await executeRequest(
            .delete,
            url: requestURL,
            headers: context.headers,
            httpClient: context.httpClient,
            tokenRefreshHandler: context.tokenRefreshHandler
        )

        context.logger.debug("Response: \(response.response.statusCode)")
        if let responseString = String(data: response.data, encoding: .utf8), !responseString.isEmpty {
            context.logger.trace("Response body: \(responseString)")
        }
    }
}

/// Builder for executing PostgreSQL RPC (Remote Procedure Call) functions.
///
/// Provides a simple interface for calling database functions with optional parameters.
public struct RPCBuilder: Sendable {
    private let url: URL
    private let headersProvider: LockIsolated<[String: String]>
    private let httpClient: HTTPClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let argsData: Data?
    private let tokenRefreshHandler: (any TokenRefreshHandler)?

    /// Logger for debug output
    private var logger: Logging.Logger { InsForgeLoggerFactory.shared }

    /// Get current headers (dynamically fetched to reflect auth state changes)
    private var headers: [String: String] {
        headersProvider.value
    }

    init(
        url: URL,
        headersProvider: LockIsolated<[String: String]>,
        httpClient: HTTPClient,
        encoder: JSONEncoder,
        decoder: JSONDecoder,
        args: [String: Any]?,
        tokenRefreshHandler: (any TokenRefreshHandler)? = nil
    ) {
        self.url = url
        self.headersProvider = headersProvider
        self.httpClient = httpClient
        self.encoder = encoder
        self.decoder = decoder
        if let args = args {
            self.argsData = try? JSONSerialization.data(withJSONObject: args)
        } else {
            self.argsData = nil
        }
        self.tokenRefreshHandler = tokenRefreshHandler
    }

    /// Executes the RPC call and returns decoded results as an array.
    public func execute<T: Decodable>() async throws -> [T] {
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/json"

        logger.debug("POST \(url.absoluteString)")
        logger.trace("Request headers: \(requestHeaders.filter { $0.key != "Authorization" })")
        if let argsData = argsData, let bodyString = String(data: argsData, encoding: .utf8) {
            logger.trace("Request body: \(bodyString)")
        }

        let response = try await executeRequest(
            .post,
            url: url,
            headers: requestHeaders,
            body: argsData,
            httpClient: httpClient,
            tokenRefreshHandler: tokenRefreshHandler
        )

        logger.debug("Response: \(response.response.statusCode)")
        if let responseString = String(data: response.data, encoding: .utf8) {
            logger.trace("Response body: \(responseString)")
        }

        if let arrayData = try? decoder.decode([T].self, from: response.data) {
            logger.debug("RPC returned \(arrayData.count) result(s)")
            return arrayData
        } else if let singleData = try? decoder.decode(T.self, from: response.data) {
            logger.debug("RPC returned 1 result")
            return [singleData]
        } else {
            return try decoder.decode([T].self, from: response.data)
        }
    }

    /// Executes the RPC call and returns a single decoded result.
    public func executeSingle<T: Decodable>() async throws -> T {
        let results: [T] = try await execute()
        guard let first = results.first else {
            throw InsForgeError.unknown("RPC returned no results")
        }
        return first
    }

    /// Executes the RPC call without expecting a return value.
    public func execute() async throws {
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/json"

        logger.debug("POST \(url.absoluteString)")
        logger.trace("Request headers: \(requestHeaders.filter { $0.key != "Authorization" })")
        if let argsData = argsData, let bodyString = String(data: argsData, encoding: .utf8) {
            logger.trace("Request body: \(bodyString)")
        }

        let response = try await executeRequest(
            .post,
            url: url,
            headers: requestHeaders,
            body: argsData,
            httpClient: httpClient,
            tokenRefreshHandler: tokenRefreshHandler
        )

        logger.debug("Response: \(response.response.statusCode)")
        if let responseString = String(data: response.data, encoding: .utf8), !responseString.isEmpty {
            logger.trace("Response body: \(responseString)")
        }

        logger.debug("RPC executed successfully")
    }
}
