import Foundation
import XCTest
@testable import LLMChatMac

final class ModelsTests: XCTestCase {
    func testPublicDefaultsDoNotContainPrivateInfrastructure() {
        XCTAssertTrue(AppDefaults.baseURL.isEmpty)
        XCTAssertTrue(AppDefaults.model.isEmpty)
        XCTAssertTrue(AppDefaults.apiKey.isEmpty)
        XCTAssertTrue(AppSettings.default.profiles.isEmpty)
    }

    func testSettingsEncodingDoesNotPersistAPIKey() throws {
        var settings = AppSettings.default
        settings.baseURL = "http://127.0.0.1:11434/v1"
        settings.model = "example-model"
        settings.apiKey = "super-secret-value"
        _ = settings.saveCurrentProfile(apiKeyHint: LLMConnectionProfile.maskedHint(for: settings.apiKey))

        let encoded = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.contains("super-secret-value"))
        XCTAssertFalse(json.contains("\"apiKey\":"))
        XCTAssertTrue(json.contains("\"credentialID\":"))
    }

    func testProfileIdentityDoesNotDependOnSecret() {
        let profile = LLMConnectionProfile(
            baseURL: "http://localhost:11434/v1",
            model: "example-model",
            interfaceType: .openAICompatible
        )
        XCTAssertTrue(profile.matches(
            baseURL: "http://localhost:11434/v1",
            model: "example-model",
            interfaceType: .openAICompatible
        ))
    }

    func testLegacySecretMigratesWithoutBeingReencoded() throws {
        let legacy = """
        {
          "baseURL": "https://example.test/v1",
          "model": "example-model",
          "apiKey": "legacy-secret",
          "interfaceType": "openai_compatible"
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.schemaVersion, 2)
        XCTAssertEqual(settings.profiles.first?.legacyAPIKey, "legacy-secret")

        let encoded = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("legacy-secret"))
        XCTAssertTrue(json.contains("\"schemaVersion\":2"))
    }

    func testRouterEnforcesContextAndRetryPolicy() throws {
        var primary = configuredSettings(id: "primary", maxContextTokens: 100)
        let fallback = configuredSettings(id: "fallback", maxContextTokens: 1_000)
        primary.routePolicy.automaticFallbackEnabled = true

        let router = ModelRouter()
        router.update(policy: primary.routePolicy)
        let candidates = try router.orderedCandidates(
            primary: primary,
            fallbacks: [fallback],
            estimatedInputTokens: 80,
            requestedOutputTokens: 50
        )

        XCTAssertEqual(candidates.map(\.id), ["fallback"])
        XCTAssertFalse(router.isRetryable(LLMServiceError.http(status: 401, body: "", url: "")))
        XCTAssertFalse(router.isRetryable(LLMServiceError.http(status: 400, body: "", url: "")))
        XCTAssertTrue(router.isRetryable(LLMServiceError.http(status: 429, body: "", url: "")))
        XCTAssertTrue(router.isRetryable(LLMServiceError.http(status: 503, body: "", url: "")))
    }

    func testCircuitBreakerTemporarilyRemovesFailedEndpoint() throws {
        var primary = configuredSettings(id: "primary", maxContextTokens: 1_000)
        let fallback = configuredSettings(id: "fallback", maxContextTokens: 1_000)
        primary.routePolicy = RoutePolicy(
            automaticFallbackEnabled: true,
            circuitFailureThreshold: 2,
            circuitCooldownSeconds: 60
        )
        let router = ModelRouter()
        router.update(policy: primary.routePolicy)
        let now = Date(timeIntervalSince1970: 1_000)
        router.recordFailure(candidateID: "primary", at: now)
        router.recordFailure(candidateID: "primary", at: now)

        let duringCooldown = try router.orderedCandidates(
            primary: primary,
            fallbacks: [fallback],
            estimatedInputTokens: 10,
            requestedOutputTokens: 10,
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(duringCooldown.map(\.id), ["fallback"])

        let afterCooldown = try router.orderedCandidates(
            primary: primary,
            fallbacks: [fallback],
            estimatedInputTokens: 10,
            requestedOutputTokens: 10,
            now: now.addingTimeInterval(61)
        )
        XCTAssertEqual(afterCooldown.map(\.id), ["primary", "fallback"])
    }

    private func configuredSettings(id: String, maxContextTokens: Int) -> AppSettings {
        var settings = AppSettings.default
        settings.baseURL = "https://\(id).example.test/v1"
        settings.model = "example-model"
        var capabilities = EndpointCapabilities.unknown
        capabilities.maxContextTokens = maxContextTokens
        settings.profiles = [
            LLMConnectionProfile(
                id: id,
                baseURL: settings.baseURL,
                model: settings.model,
                interfaceType: .openAICompatible,
                capabilities: capabilities
            ),
        ]
        return settings
    }
}
