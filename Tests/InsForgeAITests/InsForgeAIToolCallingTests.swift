import XCTest
import TestHelper
@testable import InsForge
@testable import InsForgeAI
@testable import InsForgeCore

/// Tests for AI Tool Calling
final class ToolCallingTests: XCTestCase {
    // MARK: - Helper

    private var insForgeClient: InsForgeClient!

    override func setUp() async throws {
        insForgeClient = TestHelper.createClient()
    }

    override func tearDown() async throws {
        insForgeClient = nil
    }

    // MARK: - Tool Calling Model Tests

    func testToolFunctionToDictionary() {
        let function = ToolFunction(
            name: "get_weather",
            description: "Get current weather",
            parameters: [
                "type": "object",
                "properties": [
                    "location": ["type": "string"] as [String: Any]
                ] as [String: Any],
                "required": ["location"]
            ] as [String: Any]
        )

        let dict = function.toDictionary()
        XCTAssertEqual(dict["name"] as? String, "get_weather")
        XCTAssertEqual(dict["description"] as? String, "Get current weather")
        XCTAssertNotNil(dict["parameters"])
    }

    func testToolFunctionMinimal() {
        let function = ToolFunction(name: "simple_func")

        let dict = function.toDictionary()
        XCTAssertEqual(dict["name"] as? String, "simple_func")
        XCTAssertNil(dict["description"])
        XCTAssertNil(dict["parameters"])
    }

    func testToolToDictionary() {
        let tool = Tool(function: ToolFunction(
            name: "test_func",
            description: "A test function"
        ))

        let dict = tool.toDictionary()
        XCTAssertEqual(dict["type"] as? String, "function")

        guard let funcDict = dict["function"] as? [String: Any] else {
            XCTFail("function should be a dictionary")
            return
        }
        XCTAssertEqual(funcDict["name"] as? String, "test_func")
        XCTAssertEqual(funcDict["description"] as? String, "A test function")
    }

    func testToolChoiceValues() {
        XCTAssertEqual(ToolChoice.auto.toValue() as? String, "auto")
        XCTAssertEqual(ToolChoice.none.toValue() as? String, "none")
        XCTAssertEqual(ToolChoice.required.toValue() as? String, "required")

        let functionChoice = ToolChoice.function(name: "my_func")
        guard let funcDict = functionChoice.toValue() as? [String: Any] else {
            XCTFail("function choice should be a dictionary")
            return
        }
        XCTAssertEqual(funcDict["type"] as? String, "function")
        if let funcName = funcDict["function"] as? [String: String] {
            XCTAssertEqual(funcName["name"], "my_func")
        } else {
            XCTFail("function dict should contain name")
        }
    }

    func testToolCallDecoding() throws {
        let json = """
        {
            "id": "call_123",
            "type": "function",
            "function": {
                "name": "get_weather",
                "arguments": "{\\"location\\": \\"Paris\\"}"
            }
        }
        """.data(using: .utf8)!

        let toolCall = try JSONDecoder().decode(ToolCall.self, from: json)
        XCTAssertEqual(toolCall.id, "call_123")
        XCTAssertEqual(toolCall.type, "function")
        XCTAssertEqual(toolCall.function.name, "get_weather")
        XCTAssertEqual(toolCall.function.arguments, "{\"location\": \"Paris\"}")
    }

    func testChatMessageToolRole() {
        let message = ChatMessage(toolCallId: "call_123", content: "Result here")

        XCTAssertEqual(message.role, .tool)
        XCTAssertEqual(message.toolCallId, "call_123")
        XCTAssertNil(message.toolCalls)

        let dict = message.toDictionary()
        XCTAssertEqual(dict["role"] as? String, "tool")
        XCTAssertEqual(dict["tool_call_id"] as? String, "call_123")
        XCTAssertEqual(dict["content"] as? String, "Result here")
    }

    func testChatMessageWithToolCalls() throws {
        let toolCall = try JSONDecoder().decode(ToolCall.self, from: """
        {"id": "call_1", "type": "function", "function": {"name": "fn", "arguments": "{}"}}
        """.data(using: .utf8)!)

        let message = ChatMessage(content: "", toolCalls: [toolCall])

        XCTAssertEqual(message.role, .assistant)
        XCTAssertNotNil(message.toolCalls)
        XCTAssertEqual(message.toolCalls?.count, 1)
        XCTAssertNil(message.toolCallId)

        let dict = message.toDictionary()
        XCTAssertEqual(dict["role"] as? String, "assistant")
        guard let toolCallsArray = dict["tool_calls"] as? [[String: Any]] else {
            XCTFail("tool_calls should be an array of dictionaries")
            return
        }
        XCTAssertEqual(toolCallsArray.count, 1)
        XCTAssertEqual(toolCallsArray[0]["id"] as? String, "call_1")
    }

    func testChatMessageWithoutToolFields() {
        let message = ChatMessage(role: .user, content: "Hello")

        XCTAssertNil(message.toolCalls)
        XCTAssertNil(message.toolCallId)

        let dict = message.toDictionary()
        XCTAssertNil(dict["tool_calls"])
        XCTAssertNil(dict["tool_call_id"])
    }

    func testChatCompletionResponseWithToolCalls() throws {
        let json = """
        {
            "text": "",
            "tool_calls": [
                {
                    "id": "call_abc",
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "arguments": "{\\"city\\": \\"Tokyo\\"}"
                    }
                }
            ],
            "metadata": {
                "model": "openai/gpt-4o-mini",
                "usage": {
                    "promptTokens": 50,
                    "completionTokens": 20,
                    "totalTokens": 70
                }
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: json)
        XCTAssertEqual(response.text, "")
        XCTAssertNotNil(response.toolCalls)
        XCTAssertEqual(response.toolCalls?.count, 1)
        XCTAssertEqual(response.toolCalls?[0].id, "call_abc")
        XCTAssertEqual(response.toolCalls?[0].function.name, "get_weather")
        XCTAssertEqual(response.toolCalls?[0].function.arguments, "{\"city\": \"Tokyo\"}")
    }

    func testChatCompletionResponseWithoutToolCalls() throws {
        let json = """
        {
            "text": "Hello!",
            "metadata": {
                "model": "openai/gpt-4o-mini",
                "usage": {
                    "promptTokens": 10,
                    "completionTokens": 5,
                    "totalTokens": 15
                }
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: json)
        XCTAssertEqual(response.text, "Hello!")
        XCTAssertNil(response.toolCalls)
    }

    // MARK: - Tool Calling API Tests

    /// Test chat completion with tool calling
    func testChatCompletionWithToolCalling() async throws {
        print("🔵 Testing chatCompletion with tool calling...")

        let response = try await insForgeClient.ai.chatCompletion(
            model: "openai/gpt-4o-mini",
            messages: [
                ChatMessage(role: .user, content: "What is the weather in Tokyo?")
            ],
            tools: [
                Tool(function: ToolFunction(
                    name: "get_weather",
                    description: "Get current weather for a location",
                    parameters: [
                        "type": "object",
                        "properties": [
                            "location": [
                                "type": "string",
                                "description": "City name"
                            ] as [String: Any]
                        ] as [String: Any],
                        "required": ["location"]
                    ] as [String: Any]
                ))
            ],
            toolChoice: .auto
        )

        // The model should either respond with text or request a tool call
        if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
            print("✅ Model requested tool call(s):")
            for call in toolCalls {
                print("   - id: \(call.id)")
                print("     function: \(call.function.name)")
                print("     arguments: \(call.function.arguments)")
                XCTAssertEqual(call.type, "function")
                XCTAssertFalse(call.id.isEmpty)
                XCTAssertFalse(call.function.name.isEmpty)
            }
        } else {
            // Model responded with text instead of calling a tool — still valid
            print("✅ Model responded with text (no tool call): \(response.text)")
        }
    }
}
