import XCTest
import TestHelper
@testable import InsForge
@testable import InsForgeFunctions
@testable import InsForgeCore

/// Tests for InsForge Functions Client
///
/// ## Setup Instructions
/// To run the full test suite, deploy a 'hello' function to your InsForge instance with the following code:
///
/// ```javascript
/// export default async function handler(req, res) {
///   const { name } = req.body || {};
///   const message = name ? `Hello, ${name}!` : "Hello, World!";
///   return res.status(200).json({ message });
/// }
/// ```
///
/// Deploy it with the slug: `hello`
///
/// If the hello function is not deployed, those tests will be skipped automatically.
final class InsForgeFunctionsTests: XCTestCase {
    // MARK: - Helper

    private var insForgeClient: InsForgeClient!

    override func setUp() async throws {
        insForgeClient = TestHelper.createClient()
        print("📍 InsForge URL: \(TestHelper.insForgeURL)")
    }

    override func tearDown() async throws {
        insForgeClient = nil
    }

    private func derivedFunctionsURL() throws -> URL {
        guard let host = TestHelper.baseURL.host else {
            throw XCTSkip("Test base URL has no host")
        }

        let hostComponents = host.split(separator: ".")
        guard let appKey = hostComponents.first else {
            throw XCTSkip("Could not derive functions URL from host")
        }

        var components = URLComponents(url: TestHelper.baseURL, resolvingAgainstBaseURL: false)
        components?.host = "\(appKey).functions.insforge.app"
        components?.path = ""
        components?.query = nil
        components?.fragment = nil

        guard let url = components?.url else {
            throw XCTSkip("Could not construct functions URL")
        }

        return url
    }

    // MARK: - Tests

    func testFunctionsClientInitialization() async {
        let functionsClient = await insForgeClient.functions
        XCTAssertNotNil(functionsClient)
    }

    /// Test calling the hello function without parameters
    /// NOTE: This test requires a 'hello' function to be deployed on your InsForge instance
    /// If the function doesn't exist, the test will be skipped
    func testInvokeHelloFunction() async throws {
        // Define response structure
        struct HelloResponse: Decodable {
            let message: String
        }

        do {
            // Invoke hello function via SDK
            print("🔵 Calling hello function at: \(TestHelper.insForgeURL)/functions/hello")
            let response: HelloResponse = try await insForgeClient.functions.invoke("hello")

            // Verify response
            XCTAssertFalse(response.message.isEmpty, "Response message should not be empty")
            print("✅ Hello function response: \(response.message)")
        } catch let error as InsForgeError {
            if case .httpError(let statusCode, _, _, _) = error, statusCode == 404 {
                print("⚠️  Skipping test: 'hello' function not found (404). Please deploy a hello function to test.")
                throw XCTSkip("Hello function not deployed on InsForge instance")
            } else {
                throw error
            }
        }
    }

    /// Test calling hello function with parameters
    func testInvokeHelloFunctionWithParameters() async throws {
        // Define request and response structures
        struct HelloRequest: Encodable {
            let name: String
        }

        struct HelloResponse: Decodable {
            let message: String
        }

        do {
            // Invoke hello function with name parameter
            let request = HelloRequest(name: "InsForge")
            let response: HelloResponse = try await insForgeClient.functions.invoke("hello", body: request)

            // Verify response contains the name
            XCTAssertTrue(response.message.contains("InsForge"),
                         "Response should contain the provided name")
            print("✅ Hello function with params response: \(response.message)")
        } catch let error as InsForgeError {
            if case .httpError(let statusCode, _, _, _) = error, statusCode == 404 {
                throw XCTSkip("Hello function not deployed")
            } else {
                throw error
            }
        }
    }

    /// Test calling hello function with dictionary parameters
    func testInvokeHelloFunctionWithDictionary() async throws {
        struct HelloResponse: Decodable {
            let message: String
        }

        do {
            // Invoke with dictionary body
            let body: [String: Any] = ["name": "Swift SDK"]
            let response: HelloResponse = try await insForgeClient.functions.invoke("hello", body: body)

            XCTAssertFalse(response.message.isEmpty)
            print("✅ Hello function with dictionary response: \(response.message)")
        } catch let error as InsForgeError {
            if case .httpError(let statusCode, _, _, _) = error, statusCode == 404 {
                throw XCTSkip("Hello function not deployed")
            } else {
                throw error
            }
        }
    }

    /// Test calling function without expecting response
    func testInvokeHelloFunctionWithoutResponse() async throws {
        do {
            // This should not throw
            try await insForgeClient.functions.invoke("hello")
            print("✅ Hello function invoked without response")
        } catch let error as InsForgeError {
            if case .httpError(let statusCode, _, _, _) = error, statusCode == 404 {
                throw XCTSkip("Hello function not deployed")
            } else {
                throw error
            }
        }
    }

    /// Test invoking a function with a custom HTTP method.
    func testInvokeHelloFunctionWithGETMethod() async throws {
        struct HelloResponse: Decodable {
            let message: String
        }

        let response: HelloResponse = try await insForgeClient.functions.invoke(
            "hello",
            options: FunctionInvokeOptions(method: .get)
        )

        XCTAssertFalse(response.message.isEmpty)
        print("✅ Hello function GET response: \(response.message)")
    }

    /// Test invoking through an explicit subhosting URL and falling back to the proxy on 404.
    func testInvokeHelloFunctionWithSubhostingFallback() async throws {
        struct HelloResponse: Decodable {
            let message: String
        }

        let client = TestHelper.createClient(
            options: InsForgeClientOptions(
                functions: FunctionsOptions(
                    url: try derivedFunctionsURL()
                )
            )
        )

        let response: HelloResponse = try await client.functions.invoke("hello")
        XCTAssertFalse(response.message.isEmpty)
        print("✅ Hello function with subhosting fallback response: \(response.message)")
    }

    /// Test error handling for non-existent function
    func testInvokeNonExistentFunction() async throws {
        struct EmptyResponse: Decodable {}

        do {
            let _: EmptyResponse = try await insForgeClient.functions.invoke("non-existent-function-12345")
            XCTFail("Should have thrown an error for non-existent function")
        } catch {
            // Expected to fail
            print("✅ Correctly threw error for non-existent function: \(error)")
        }
    }
}
