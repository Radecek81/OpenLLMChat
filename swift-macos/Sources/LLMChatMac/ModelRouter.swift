import Foundation

struct LLMRouteCandidate {
    let id: String
    let settings: AppSettings
    let maxContextTokens: Int?
}

final class ModelRouter {
    private struct CircuitState {
        var consecutiveFailures: Int
        var openedAt: Date?
    }

    private var policy = RoutePolicy.default
    private var circuits: [String: CircuitState] = [:]

    func update(policy: RoutePolicy) {
        self.policy = policy
    }

    func orderedCandidates(
        primary: AppSettings,
        fallbacks: [AppSettings],
        estimatedInputTokens: Int,
        requestedOutputTokens: Int,
        now: Date = Date()
    ) throws -> [LLMRouteCandidate] {
        let settingsCandidates = [primary] + (policy.automaticFallbackEnabled ? fallbacks : [])
        let candidates = settingsCandidates.map(candidate)
        let withinContext = candidates.filter { candidate in
            guard let limit = candidate.maxContextTokens, limit > 0 else { return true }
            return estimatedInputTokens + requestedOutputTokens <= limit
        }
        let available = withinContext.filter { !isCircuitOpen($0.id, now: now) }

        if available.isEmpty {
            if withinContext.isEmpty {
                throw LLMServiceError.invalidConfiguration(
                    L10n.choose(
                        "Žádný povolený endpoint nemá dostatečné kontextové okno.",
                        "No eligible endpoint has a large enough context window."
                    )
                )
            }
            throw LLMServiceError.request(
                L10n.choose(
                    "Všechny povolené endpointy jsou dočasně odpojené circuit breakerem.",
                    "All eligible endpoints are temporarily disabled by the circuit breaker."
                )
            )
        }
        return available
    }

    func isRetryable(_ error: Error) -> Bool {
        guard let serviceError = error as? LLMServiceError else { return true }
        switch serviceError {
        case let .http(status, _, _):
            return status == 429 || (500 ... 599).contains(status)
        case .request:
            return true
        case .invalidConfiguration, .invalidJSON, .invalidResponse, .structuredOutput:
            return false
        }
    }

    func recordFailure(candidateID: String, at now: Date = Date()) {
        var state = circuits[candidateID] ?? CircuitState(consecutiveFailures: 0, openedAt: nil)
        state.consecutiveFailures += 1
        if state.consecutiveFailures >= max(1, policy.circuitFailureThreshold) {
            state.openedAt = now
        }
        circuits[candidateID] = state
    }

    func recordSuccess(candidateID: String) {
        circuits.removeValue(forKey: candidateID)
    }

    private func candidate(_ settings: AppSettings) -> LLMRouteCandidate {
        let profile = settings.activeProfile
        let fallbackID = "\(settings.interfaceType.rawValue)|\(settings.baseURL.lowercased())|\(settings.model.lowercased())"
        return LLMRouteCandidate(
            id: profile?.id ?? fallbackID,
            settings: settings,
            maxContextTokens: profile?.capabilities.maxContextTokens
        )
    }

    private func isCircuitOpen(_ candidateID: String, now: Date) -> Bool {
        guard let state = circuits[candidateID], let openedAt = state.openedAt else { return false }
        let cooldown = TimeInterval(max(1, policy.circuitCooldownSeconds))
        if now.timeIntervalSince(openedAt) >= cooldown {
            circuits.removeValue(forKey: candidateID)
            return false
        }
        return true
    }
}
