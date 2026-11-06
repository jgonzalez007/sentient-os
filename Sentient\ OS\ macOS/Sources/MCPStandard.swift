//
//  MCPStandard.swift
//  Sentient OS macOS  ·  Sources/
//
//  Phase 1.7 — MCP Connector Standardization
//
//  Standardizes how Model Context Protocol (MCP) connectors integrate with the existing
//  Sentient OS ingestion pipeline. All MCP connectors (Gmail, Google Calendar, Google Drive,
//  Slack, Notion, Granola, Outlook Mail, Outlook Calendar) follow this unified interface:
//
//   - MCPTransport — enum for SSE and stdio transports
//   - MCPConnector — protocol all MCP connectors implement
//   - MCPClient — core client handling protocol handshake (init, tools, calling)
//   - MCPRegistry — singleton registry for discovering and managing MCP connectors
//
//  Key methods:
//   - MCPClient.connect()       — establish transport
//   - MCPClient.disconnect()    — close transport
//   - MCPClient.listTools()     — get available tools from server
//   - MCPClient.callTool(...)   — invoke a tool by name with arguments
//   - MCPClient.isAvailable()   — check if server is reachable
//   - MCPRegistry.addConnector(_:)   — register a connector
//   - MCPRegistry.removeConnector(by:) — unregister by name
//   - MCPRegistry.availableTools()     — aggregate all tool names
//   - MCPRegistry.findConnector(for:)  — find which connector provides a tool
//
//  Doc: Sources/MCPStandard.swift
//

import Foundation
import os

// MARK: - Transport

/// Transport protocol for MCP connections. MCP servers can be reached via SSE (Server-Sent Events)
/// over HTTP(S), or via stdio (local process with command-line arguments).
///
/// ## Usage
///
/// ```swift
/// // SSE transport (hosted services like Gmail, Calendar, Drive)
/// let transport = MCPTransport.sse(url: URL(string: "https://gmailmcp.googleapis.com/mcp/v1")!)
///
/// // stdio transport (local tool servers)
/// let transport = MCPTransport.stdio(
///     command: "/usr/local/bin/mcp-server-gmail",
///     arguments: ["--config", "~/.config/gmail.json"]
/// )
/// ```
enum MCPTransport: Sendable, Equatable {
    /// Server-Sent Events over HTTP(S). The server pushes JSON-RPC messages through an SSE
    /// endpoint; the client connects, reads the event stream, and multiplexes requests.
    ///
    /// Used by hosted Google services (Gmail, Calendar, Drive) and other cloud MCP providers.
    case sse(url: URL)

    /// Standard I/O. A local executable is spawned with the given arguments; the client
    /// reads and writes JSON-RPC messages over the process's stdin/stdout.
    ///
    /// Used by local MCP tool servers and developer-built connectors.
    case stdio(command: String, arguments: [String])
}

// MARK: - Connector Protocol

/// Standardized connector interface for all MCP-backed data sources. Every MCP connector
/// in the pipeline (Gmail, Calendar, Drive, Slack, Notion, Granola, Outlook Mail, Outlook
/// Calendar) must implement this protocol to integrate with the unified `MCPCall` execution
/// engine in `MCPSource.swift`.
///
/// ## Protocol Requirements
///
/// - `mcpTransport` — how the connector reaches its server (SSE or stdio)
/// - `mcpTools` — the tool names this connector uses (for classification and routing)
///
/// ## Example
///
/// ```swift
/// struct GmailConnector: MCPConnector {
///     static let slug = "gmail"
///     static let displayName = "Gmail"
///     let mcpTransport: MCPTransport = .sse(url: URL(string: "https://gmailmcp.googleapis.com/mcp/v1")!)
///     let mcpTools: [String] = ["search_emails", "read_email", "send_email", "list_drafts"]
/// }
/// ```
protocol MCPConnector: Sendable {
    /// The canonical slug for this connector, used throughout the pipeline
    /// (`mcp.<slug>` buckets, `kbEnabledConnectors`, telemetry, etc.)
    static var slug: String { get }

    /// Human-readable name shown in UI (Connected Services, Knowledge Sources, etc.)
    static var displayName: String { get }

    /// Transport configuration — how to reach the connector's MCP server.
    var mcpTransport: MCPTransport { get }

    /// Tool names this connector provides. Used for classification (read/write/destructive),
    /// KB eligibility, and action routing.
    var mcpTools: [String] { get }
}

// MARK: - MCP Client

/// Core MCP client that handles the protocol handshake, tool discovery, and invocation.
/// Implements the JSON-RPC 2.0 protocol as defined by the Model Context Protocol spec.
///
/// ## Lifecycle
///
/// 1. **Create** — `MCPClient(transport:)` initializes with a transport configuration
/// 2. **Connect** — `connect()` establishes the transport (SSE stream or stdio process)
/// 3. **Interact** — `listTools()` and `callTool(name:arguments:)` drive the protocol
/// 4. **Disconnect** — `disconnect()` tears down the transport
///
/// ## Thread Safety
///
/// All public methods are `Sendable`; internal state is protected by serial access
/// through the transport's event loop. No concurrent calls are expected from the
/// `MCPCall.execute()` pattern, but the client guards against race conditions.
///
/// ## Doc
/// - `MCPSource.swift` — unified connector execution
/// - `ConnectorRegistry.swift` — identity and policy layer
@Observable
final class MCPClient: Sendable {
    private let logger = Logger(subsystem: "com.josegonzalez.sentient-os", category: "MCPClient")
    private let transport: MCPTransport

    /// Connection state. `connected` means the transport is established and the server
    /// has completed the initialization handshake.
    private(set) var connected = false
    private(set) var serverInfo: ServerInfo?
    private(set) var availableTools: [ToolInfo] = []

    /// Request ID counter for JSON-RPC message correlation.
    private var nextID: Int = 0

    /// Pending requests: maps a request ID to its continuations.
    private var pendingRequests: [Int: Continuation<JSONRPCResponse>] = [:]

    /// SSE event stream for the transport. `Sendable` serial queue ensures no
    /// concurrent access to the stream.
    private var eventStream: AsyncStream<JSONObject>?

    /// Stdio process for the transport. Controlled via the serial event loop.
    private var process: Process?

    /// JSON-RPC message queue for the stdio transport.
    private var messageQueue: [JSONRPCMessage] = []

    // MARK: - Server and Tool Metadata

    /// A single server's version and capabilities as reported during initialization.
    struct ServerInfo: Sendable, Codable {
        /// The server's protocol version (e.g., "2024-11-05").
        let protocolVersion: String
        /// The server's implementation name and version.
        let implementation: ImplementationInfo
        /// Optional capabilities the server advertises.
        let capabilities: ServerCapabilities?
    }

    /// Implementation metadata reported by the server.
    struct ImplementationInfo: Sendable, Codable {
        let name: String
        let version: String
    }

    /// Server capabilities as advertised during initialization.
    struct ServerCapabilities: Sendable, Codable {
        /// The tools the server advertises support for.
        let tools: ToolCapabilities?
    }

    /// Tool capability flags.
    struct ToolCapabilities: Sendable, Codable {
        /// Non-empty when the server supports tool listing.
        let listChanged: Bool?
    }

    /// A single tool as reported by the server. Includes the name, description, and
    /// parameter schema (JSON Schema format).
    struct ToolInfo: Sendable, Codable {
        /// The tool's unique name within this server.
        let name: String
        /// Human-readable description of what the tool does.
        let description: String
        /// JSON Schema defining the tool's input parameters.
        let inputSchema: JSONValue
    }

    /// Error as reported by an MCP server (JSON-RPC 2.0 error response).
    struct MCPError: Sendable, Codable, Error {
        /// The standard JSON-RPC error code.
        let code: Int
        /// Human-readable error message.
        let message: String
    }

    /// JSON representation value used throughout the MCP protocol.
    typealias JSONValue = JSONRPCValue
    typealias JSONObject = [String: JSONRPCValue]

    // MARK: - Lifecycle

    /// Create a new MCP client with the given transport.
    ///
    /// - Parameter transport: The transport configuration (SSE or stdio).
    init(transport: MCPTransport) {
        self.transport = transport
    }

    /// Establish the transport connection and complete the MCP initialization handshake.
    ///
    /// ## Behavior
    ///
    /// 1. Opens the transport (SSE stream for `.sse`, spawns process for `.stdio`)
    /// 2. Sends `initialize` request with client capabilities
    /// 3. Waits for server's `initialize` response
    /// 4. Sends `initialized` notification to complete handshake
    /// 5. Sets `connected = true` and caches server metadata
    ///
    /// - Throws: `MCPConnectionError` if the transport cannot be opened or handshake fails.
    ///
    /// - Returns: `Self` for method chaining.
    @MainActor
    func connect() async throws -> Self {
        switch transport {
        case .sse(let url):
            try await connectSSE(url: url)
        case .stdio(let command, let arguments):
            try await connectStdio(command: command, arguments: arguments)
        }

        // Send initialize request
        let initRequest = JSONRPCMessage(
            jsonrpc: .v2_0,
            id: nextRequestID(),
            method: .init("initialize"),
            params: JSONValue.dictionary([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": JSONValue.dictionary([
                    "roots": JSONValue.dictionary(["listChanged": .bool(true)])
                ]),
                "clientInfo": JSONValue.dictionary([
                    "name": "SentientOS",
                    "version": "2.8.0"
                ])
            ])
        )

        let initResponse = try await sendRequest(initRequest)

        // Parse server info
        guard case .dictionary(let root) = initResponse.result else {
            throw MCPConnectionError.invalidHandshake(reason: "Expected dictionary result")
        }

        let serverVersion = root["protocolVersion"]?.string ?? "unknown"
        let implDict = root["server"]?.dictionary ?? [:]
        let implementation = ImplementationInfo(
            name: implDict["name"]?.string ?? "unknown",
            version: implDict["version"]?.string ?? "unknown"
        )

        serverInfo = ServerInfo(
            protocolVersion: serverVersion,
            implementation: implementation,
            capabilities: nil
        )

        // Send initialized notification (fire-and-forget)
        let notification = JSONRPCMessage(
            jsonrpc: .v2_0,
            id: nil,
            method: .init("notifications/initialized"),
            params: nil
        )
        await sendNotification(notification)

        connected = true
        logger.info("MCP connected: \(implementation.name) v\(implementation.version)")
        return self
    }

    /// Close the transport and reset connection state.
    @MainActor
    func disconnect() {
        connected = false
        serverInfo = nil
        availableTools = []
        pendingRequests.removeAll()
        switch transport {
        case .sse:
            // SSE stream is naturally terminated by the event loop
            break
        case .stdio(let command, _):
            process?.terminate()
            process = nil
            logger.info("MCP stdio process terminated: \(command)")
        }
    }

    /// Check if the server is reachable without establishing a full connection.
    ///
    /// - Parameter timeout: Maximum wait time for the reachability check (default: 5 seconds).
    /// - Returns: `true` if the server responds to a basic probe.
    @MainActor
    func isAvailable(timeout: TimeInterval = 5.0) async -> Bool {
        do {
            let client = Self(transport: transport)
            _ = try await client.connect()
            client.disconnect()
            return true
        } catch {
            logger.debug("MCP availability check failed: \(error)")
            return false
        }
    }

    // MARK: - Tool Discovery

    /// Fetch the list of available tools from the connected server.
    ///
    /// - Returns: An array of `ToolInfo` describing each available tool.
    /// - Throws: `MCPConnectionError.notConnected` if not connected, or a server error.
    @MainActor
    func listTools() async throws -> [ToolInfo] {
        guard connected else {
            throw MCPConnectionError.notConnected
        }

        let request = JSONRPCMessage(
            jsonrpc: .v2_0,
            id: nextRequestID(),
            method: .init("tools/list"),
            params: nil
        )

        let response = try await sendRequest(request)

        guard case .dictionary(let root) = response.result else {
            throw MCPConnectionError.invalidResponse(reason: "tools/list returned non-dictionary")
        }

        guard case .array(let toolsArray) = root["tools"] ?? .null else {
            throw MCPConnectionError.invalidResponse(reason: "No 'tools' key in response")
        }

        var tools: [ToolInfo] = []
        for case .dictionary(let toolDict) in toolsArray {
            let name = toolDict["name"]?.string ?? ""
            let description = toolDict["description"]?.string ?? ""
            let inputSchema = toolDict["inputSchema"] ?? .null
            tools.append(ToolInfo(name: name, description: description, inputSchema: inputSchema))
        }

        availableTools = tools
        return tools
    }

    /// Call a tool on the connected server by name with the given arguments.
    ///
    /// - Parameters:
    ///   - name: The tool's name as reported by `listTools()`.
    ///   - arguments: Key-value pairs matching the tool's JSON Schema.
    /// - Returns: The tool's result as a `JSONValue` (typically a dictionary or array).
    /// - Throws: `MCPConnectionError.notConnected` if not connected, or an `MCPError` from the server.
    @MainActor
    func callTool(name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard connected else {
            throw MCPConnectionError.notConnected
        }

        let request = JSONRPCMessage(
            jsonrpc: .v2_0,
            id: nextRequestID(),
            method: .init("tools/call"),
            params: JSONValue.dictionary([
                "name": .string(name),
                "arguments": .dictionary(arguments)
            ])
        )

        let response = try await sendRequest(request)

        if let error = response.error {
            throw error
        }

        return response.result
    }

    // MARK: - Internal

    /// Send a JSON-RPC request and wait for the response.
    @MainActor
    private func sendRequest(_ message: JSONRPCMessage) async throws -> JSONRPCResponse {
        guard let id = message.id else {
            throw MCPConnectionError.invalidHandshake(reason: "Request must have an ID")
        }

        let continuation = Continuation<JSONRPCResponse>()
        pendingRequests[id] = continuation
        defer { pendingRequests.removeValue(forKey: id) }

        switch transport {
        case .sse:
            await sseWrite(message)
        case .stdio(_, _):
            await stdioWrite(message)
        }

        return try await continuation.value
    }

    /// Send a notification (fire-and-forget, no response expected).
    @MainActor
    private func sendNotification(_ message: JSONRPCMessage) async {
        switch transport {
        case .sse:
            await sseWrite(message)
        case .stdio(_, _):
            await stdioWrite(message)
        }
    }

    @MainActor
    private func nextRequestID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    // MARK: - SSE Transport

    @MainActor
    private func connectSSE(url: URL) async throws {
        // In production this would use URLSession to open an SSE stream.
        // For now, we validate the URL and mark the transport as ready.
        guard url.scheme == "https" || url.scheme == "http" else {
            throw MCPConnectionError.invalidTransport(reason: "URL must use http or https scheme")
        }
        logger.info("SSE transport configured for: \(url.absoluteString)")
    }

    @MainActor
    private func sseWrite(_: JSONRPCMessage) async {
        // Write to the SSE stream. In production, this serializes the message to
        // JSON and sends it as an HTTP POST to the SSE endpoint.
    }

    // MARK: - Stdio Transport

    @MainActor
    private func connectStdio(command: String, arguments: [String]) async throws {
        guard !command.isEmpty else {
            throw MCPConnectionError.invalidTransport(reason: "Command must not be empty")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        // Setup pipes for stdin/stdout
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout

        try process.run()

        // Start reading stdout in the background
        Task {
            let fileHandle = stdout.fileHandleForReading
            let data = try fileHandle.readToEnd() ?? Data()
            if let text = String(data: data, encoding: .utf8) {
                logger.debug("Stdio initial output: \(text.prefix(200))")
            }
        }

        self.process = process
        logger.info("Stdio transport started: \(command) \(arguments.joined(separator: " "))")
    }

    @MainActor
    private func stdioWrite(_: JSONRPCMessage) async {
        // Write to the process's stdin. In production, this serializes the message
        // to JSON and writes it followed by a newline.
    }
}

// MARK: - Connection Errors

/// Errors specific to MCP transport and protocol operations.
enum MCPConnectionError: LocalizedError, Sendable {
    /// The transport cannot be opened (invalid URL, missing binary, etc.).
    case invalidTransport(reason: String)
    /// No connection is established; call `connect()` first.
    case notConnected
    /// The server returned an invalid response (wrong JSON-RPC format).
    case invalidResponse(reason: String)
    /// The handshake failed (server rejected the protocol version, etc.).
    case invalidHandshake(reason: String)
    /// The connection was lost during an operation.
    case connectionLost(reason: String?)

    var errorDescription: String? {
        switch self {
        case .invalidTransport(let reason):
            return "Invalid transport configuration: \(reason)"
        case .notConnected:
            return "Not connected. Call connect() first."
        case .invalidResponse(let reason):
            return "Invalid server response: \(reason)"
        case .invalidHandshake(let reason):
            return "Handshake failed: \(reason)"
        case .connectionLost(let reason):
            return reason.map { "Connection lost: \($0)" } ?? "Connection lost"
        }
    }
}

// MARK: - JSON-RPC Types

/// A single JSON-RPC 2.0 message. This is the wire format for all MCP communication.
struct JSONRPCMessage: Sendable {
    /// Must be "2.0" per the JSON-RPC 2.0 spec.
    let jsonrpc: String
    /// Request/Response identifier. `nil` for notifications.
    let id: Int?
    /// Method name for requests/notifications.
    let method: String?
    /// Parameter object for requests, or `nil` for notifications.
    let params: JSONRPCValue?

    /// Serialize to JSON-RPC 2.0 wire format.
    func serialize() -> Data? {
        var dict: [String: JSONRPCValue] = [
            "jsonrpc": .string("2.0")
        ]
        if let id { dict["id"] = .int(id) }
        if let method { dict["method"] = .string(method) }
        if let params { dict["params"] = params }

        return try? JSONSerialization.data(withJSONObject: dict.asJSONDictionary())
    }

    /// Parse from JSON-RPC 2.0 wire format.
    static func deserialize(from data: Data) throws -> JSONRPCMessage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError.invalidTransport(reason: "Not a JSON object")
        }

        guard let jsonrpc = object["jsonrpc"] as? String, jsonrpc == "2.0" else {
            throw MCPConnectionError.invalidResponse(reason: "Missing or invalid jsonrpc version")
        }

        let id = object["id"] as? Int
        let method = object["method"] as? String
        let params = object["params"] as? [String: Any]

        return JSONRPCMessage(jsonrpc: jsonrpc, id: id, method: method, params: params.map(JSONRPCValue.fromDictionary))
    }
}

/// A JSON value that can be serialized/deserialized to/from the standard JSON types.
enum JSONRPCValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONRPCValue])
    case dictionary([String: JSONRPCValue])

    init?(dictionary: [String: Any]) {
        guard let dict = dictionary else { return nil }
        self = .dictionary(Dictionary(uniqueKeysWithValues: dict.map { key, value in
            (key, JSONRPCValue.fromAny(value))
        }))
    }

    static func fromAny(_ value: Any) -> JSONRPCValue {
        switch value {
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map { fromAny($0) })
        case let v as [String: Any]: return .dictionary(Dictionary(uniqueKeysWithValues: v.map { key, value in
            (key, fromAny(value))
        }))
        case let v as NSNull: return .null
        default: return .null
        }
    }

    func asJSONDictionary() -> [String: Any] {
        switch self {
        case .null: return [:]
        case .bool(let v): return ["bool": v]
        case .int(let v): return ["int": v]
        case .double(let v): return ["double": v]
        case .string(let v): return ["string": v]
        case .array(let items): return ["array": items.map { $0.asAny() }]
        case .dictionary(let dict): return Dictionary(uniqueKeysWithValues: dict.map { _, v in v.asAny() })
        }
    }

    func asAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let items): return items.map { $0.asAny() }
        case .dictionary(let dict): return Dictionary(uniqueKeysWithValues: dict.map { $1.asAny() })
        }
    }

    var string: String? {
        guard case .string(let v) = self else { return nil }
        return v
    }

    var int: Int? {
        guard case .int(let v) = self else { return nil }
        return v
    }

    var bool: Bool? {
        guard case .bool(let v) = self else { return nil }
        return v
    }

    var dictionary: [String: JSONRPCValue]? {
        guard case .dictionary(let v) = self else { return nil }
        return v
    }

    var array: [JSONRPCValue]? {
        guard case .array(let v) = self else { return nil }
        return v
    }
}

/// A JSON-RPC 2.0 response message.
struct JSONRPCResponse: Sendable {
    /// The request identifier, matching the original request.
    let id: Int?
    /// The result value. `nil` for error responses.
    let result: JSONRPCValue
    /// Error details. `nil` for successful responses.
    let error: MCPConnectionError?
}

/// A continuation wrapper for async request/response patterns.
@Sendable
final class Continuation<T> {
    private let _promise: (T) -> Void
    private let _future: Task<T, Error>

    init() {
        var promise: (T) -> Void!
        _future = Task {
            let result = await withCheckedContinuation { cont in
                promise = { value in cont.resume(returning: value) }
            }
            return result
        }
        self._promise = promise
    }

    var value: TaskAwaitable<T> {
        _future.result
    }

    func fulfill(_ value: T) {
        _promise(value)
    }
}

// MARK: - MCP Registry

/// Singleton registry for discovering, managing, and routing MCP connectors.
///
/// The registry maintains a list of all registered `MCPConnector` implementations and provides
/// query methods for tool discovery, connector lookup, and policy enforcement. It integrates
/// with `ConnectorRegistry.swift` for identity and policy, and with `MCPSource.swift` for
/// unified execution.
///
/// ## Usage
///
/// ```swift
/// let registry = MCPRegistry.shared
///
/// // Register connectors (typically done at app launch)
/// registry.addConnector(GmailConnector())
/// registry.addConnector(CalendarConnector())
///
/// // Discover available tools across all connectors
/// let tools = registry.availableTools()
///
/// // Find which connector provides a specific tool
/// if let connector = registry.findConnector(for: "read_email") {
///     print("Tool provided by: \(connector.displayName)")
/// }
/// ```
@Observable
final class MCPRegistry: Sendable {
    static let shared = MCPRegistry()

    private init() {}

    /// The list of registered MCP connectors.
    private(set) var connectors: [any MCPConnector] = []

    /// Add a connector to the registry. If a connector with the same slug already exists,
    /// it is replaced (the old connector is removed first).
    ///
    /// - Parameter connector: The connector implementation to register.
    mutating func addConnector(_ connector: any MCPConnector) {
        // Remove existing connector with the same slug, if any
        connectors.removeAll { $0.slug == connector.slug }
        connectors.append(connector)
    }

    /// Remove a connector by its slug.
    ///
    /// - Parameter name: The connector's slug to remove.
    /// - Returns: `true` if a connector was found and removed.
    mutating func removeConnector(by slug: String) -> Bool {
        let before = connectors.count
        connectors.removeAll { $0.slug == slug }
        return connectors.count < before
    }

    /// Aggregate all tool names across every registered connector.
    ///
    /// - Returns: An array of all tool names, deduplicated and sorted.
    func availableTools() -> [String] {
        Set(connectors.flatMap(\.mcpTools)).sorted()
    }

    /// Find which registered connector provides a given tool.
    ///
    /// - Parameter tool: The tool name to look up.
    /// - Returns: The first connector that includes the tool in its `mcpTools` list,
    ///   or `nil` if no connector provides it.
    func findConnector(for tool: String) -> (any MCPConnector)? {
        connectors.first { $0.mcpTools.contains(tool) }
    }

    /// Check if any registered connector includes the given tool.
    ///
    /// - Parameter tool: The tool name to check.
    /// - Returns: `true` if at least one connector provides the tool.
    func hasTool(_ tool: String) -> Bool {
        availableTools().contains(tool)
    }

    /// Get all connectors that include the given tool.
    ///
    /// - Parameter tool: The tool name to filter by.
    /// - Returns: All connectors that provide the tool.
    func findAllConnectors(for tool: String) -> [any MCPConnector] {
        connectors.filter { $0.mcpTools.contains(tool) }
    }

    /// Get a connector by its slug.
    ///
    /// - Parameter slug: The connector's slug.
    /// - Returns: The connector with the given slug, or `nil` if not found.
    func connector(by slug: String) -> (any MCPConnector)? {
        connectors.first { $0.slug == slug }
    }

    /// Count of registered connectors.
    var connectorCount: Int {
        connectors.count
    }
}
