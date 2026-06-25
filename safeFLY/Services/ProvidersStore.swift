//
//  ProvidersStore.swift
//  safeFLY
//

import Foundation
import Combine

struct ProviderRegistration {
    let provider: any GeospatialProvider
    let normalizer: any ZoneFeatureNormalizing
}

enum BuiltInProviders {
    static let all: [ProviderRegistration] = [
        ProviderRegistration(provider: DIPULProvider(), normalizer: ZoneFeatureNormalizer())
    ]
}

@MainActor
final class ProvidersStore: ObservableObject {
    @Published private(set) var sessions: [ProviderSession]
    @Published private(set) var renderPayloads: [ProviderRenderPayload] = []
    @Published private(set) var zoneQueryResult: ZoneQueryResult?
    @Published private(set) var isLoading = false
    @Published private(set) var configurationRevision = 0
    @Published var enabledProviderIDs: Set<String> {
        didSet {
            persistEnabledProviderIDs()
            clearZoneQueryResult()
            configurationRevision += 1
        }
    }

    private let enabledProvidersStorageKey = "providers.enabled"

    init(registrations: [ProviderRegistration]) {
        let sessions = registrations.map {
            ProviderSession(provider: $0.provider, normalizer: $0.normalizer, autoRefreshStatus: false)
        }

        self.sessions = sessions
        self.enabledProviderIDs = Self.loadEnabledProviderIDs(
            storageKey: "providers.enabled",
            providers: sessions.map { $0.provider }
        )

        Task {
            await refreshAllStatuses()
        }
    }

    var enabledSessions: [ProviderSession] {
        sessions.filter { enabledProviderIDs.contains($0.provider.id) }
    }

    func isProviderEnabled(_ providerID: String) -> Bool {
        enabledProviderIDs.contains(providerID)
    }

    func providerSession(for providerID: String) -> ProviderSession? {
        sessions.first { $0.provider.id == providerID }
    }

    func setProviderEnabled(_ providerID: String, isEnabled: Bool) {
        if isEnabled {
            enabledProviderIDs.insert(providerID)
        } else {
            enabledProviderIDs.remove(providerID)
        }
    }

    func refreshAllStatuses() async {
        for session in sessions {
            await session.refreshStatus()
        }

        configurationRevision += 1
    }

    func refreshStatus(for providerID: String) async {
        guard let session = providerSession(for: providerID) else {
            return
        }

        await session.refreshStatus()
        configurationRevision += 1
    }

    func refreshRenderPayloads(for request: ProviderRenderRequest) async {
        let enabledSessions = enabledSessions

        for session in sessions where !enabledProviderIDs.contains(session.provider.id) {
            session.clearRenderPayloads()
        }

        for session in enabledSessions {
            await session.refreshRenderPayloads(for: request)
        }

        renderPayloads = enabledSessions.flatMap(\.renderPayloads)
    }

    func queryLocation(for request: ProviderPointQueryRequest) async {
        let enabledSessions = enabledSessions

        guard !enabledSessions.isEmpty else {
            zoneQueryResult = .nonAssessment(reason: .noEnabledLayers)
            return
        }

        isLoading = true
        zoneQueryResult = nil

        for session in sessions where !enabledProviderIDs.contains(session.provider.id) {
            session.clearZoneQueryResult()
        }

        for session in enabledSessions {
            await session.queryLocation(for: request)
        }

        zoneQueryResult = aggregateZoneQueryResult(from: enabledSessions)
        isLoading = false
    }

    func clearZoneQueryResult() {
        zoneQueryResult = nil
        sessions.forEach { $0.clearZoneQueryResult() }
    }

    func clearRenderPayloads() {
        renderPayloads = []
        sessions.forEach { $0.clearRenderPayloads() }
    }

    func markConfigurationChanged() {
        clearZoneQueryResult()
        configurationRevision += 1
    }

    private func aggregateZoneQueryResult(from sessions: [ProviderSession]) -> ZoneQueryResult {
        var matchedFeatures: [ZoneFeature] = []
        var firstUnavailableReason: UnavailableReason?
        var sawClearResult = false

        for session in sessions {
            guard let result = session.zoneQueryResult else {
                continue
            }

            switch result {
            case .matches(let features, _):
                matchedFeatures.append(contentsOf: features)
            case .unavailable(let reason):
                if firstUnavailableReason == nil {
                    firstUnavailableReason = reason
                }
            case .clear:
                sawClearResult = true
            case .nonAssessment:
                continue
            }
        }

        if !matchedFeatures.isEmpty {
            let sortedFeatures = matchedFeatures.sorted { lhs, rhs in
                if lhs.category.displayPriority != rhs.category.displayPriority {
                    return lhs.category.displayPriority < rhs.category.displayPriority
                }

                return lhs.id < rhs.id
            }
            return .matches(
                features: sortedFeatures,
                assessment: ZoneAssessmentEvaluator.evaluate(features: sortedFeatures)
            )
        }

        if let firstUnavailableReason {
            return .unavailable(reason: firstUnavailableReason)
        }

        if sawClearResult {
            return .clear(reason: .noMatchingRestrictions)
        }

        return .nonAssessment(reason: .noEnabledLayers)
    }

    private func persistEnabledProviderIDs() {
        UserDefaults.standard.set(Array(enabledProviderIDs).sorted(), forKey: enabledProvidersStorageKey)
    }

    private static func loadEnabledProviderIDs(
        storageKey: String,
        providers: [any GeospatialProvider]
    ) -> Set<String> {
        if let savedProviderIDs = UserDefaults.standard.stringArray(forKey: storageKey) {
            return Set(savedProviderIDs)
        }

        return Set(providers.map(\.id))
    }
}
