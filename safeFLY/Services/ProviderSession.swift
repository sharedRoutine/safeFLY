//
//  ProviderSession.swift
//  safeFLY
//

import Foundation
import Combine

protocol GeospatialProvider {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    var datasets: [ProviderDataset] { get }
    var referenceLinks: [ProviderReferenceLink] { get }

    func refreshStatus() async -> ProviderStatusSnapshot
    func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload]
    func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome
}

protocol ZoneFeatureNormalizing {
    func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature]
}

@MainActor
final class ProviderSession: ObservableObject {
    @Published private(set) var statusSnapshot: ProviderStatusSnapshot
    @Published private(set) var renderPayloads: [ProviderRenderPayload] = []
    @Published private(set) var zoneQueryResult: ZoneQueryResult?
    @Published private(set) var isLoading = false
    @Published var selectedDatasetIDs: Set<String> {
        didSet {
            persistSelectedDatasetIDs()
        }
    }

    let provider: any GeospatialProvider

    private let normalizer: any ZoneFeatureNormalizing
    private let selectionStorageKey: String
    private let statusStorageKey: String

    init(provider: any GeospatialProvider, normalizer: any ZoneFeatureNormalizing) {
        let selectionStorageKey = "provider.selected-datasets.\(provider.id)"
        let statusStorageKey = "provider.status-snapshot.\(provider.id)"
        self.provider = provider
        self.normalizer = normalizer
        self.selectionStorageKey = selectionStorageKey
        self.statusStorageKey = statusStorageKey
        self.selectedDatasetIDs = Self.loadSelectedDatasetIDs(for: provider)
        self.statusSnapshot = Self.loadStatusSnapshot(for: provider, storageKey: statusStorageKey)

        Task {
            await refreshStatus()
        }
    }

    var datasetCatalog: [ProviderDataset] {
        provider.datasets
    }

    func clearZoneQueryResult() {
        zoneQueryResult = nil
    }

    func clearRenderPayloads() {
        renderPayloads = []
    }

    func setDatasetSelected(_ datasetID: String, isSelected: Bool) {
        if isSelected {
            selectedDatasetIDs.insert(datasetID)
        } else {
            selectedDatasetIDs.remove(datasetID)
        }
    }

    func refreshStatus() async {
        guard provider.capabilities.supportsStatusRefresh else {
            let availableSnapshot = ProviderStatusSnapshot(
                providerStatus: .available,
                datasetStatuses: Dictionary(uniqueKeysWithValues: provider.datasets.map { ($0.id, .available) }),
                refreshedAt: Date()
            )
            statusSnapshot = availableSnapshot
            persistStatusSnapshot(availableSnapshot)
            return
        }

        let refreshedSnapshot = await provider.refreshStatus()
        statusSnapshot = refreshedSnapshot
        persistStatusSnapshot(refreshedSnapshot)
    }

    func refreshRenderPayloads(for request: ProviderRenderRequest) async {
        guard provider.capabilities.supportsRendering else {
            renderPayloads = []
            return
        }

        let renderableDatasetIDs = selectedDatasetIDsForRendering()
        guard !renderableDatasetIDs.isEmpty else {
            renderPayloads = []
            return
        }

        renderPayloads = await provider.renderPayloads(
            for: request,
            selectedDatasetIDs: renderableDatasetIDs,
            status: statusSnapshot
        )
    }

    func queryLocation(for request: ProviderPointQueryRequest) async {
        guard provider.capabilities.supportsQuerying else {
            zoneQueryResult = .nonAssessment(reason: .noEnabledLayers)
            return
        }

        let queryableDatasetIDs = selectedDatasetIDsForQuerying()
        guard !queryableDatasetIDs.isEmpty else {
            zoneQueryResult = .nonAssessment(reason: .noEnabledLayers)
            return
        }

        isLoading = true
        zoneQueryResult = nil

        let outcome = await provider.query(
            for: request,
            selectedDatasetIDs: queryableDatasetIDs,
            status: statusSnapshot
        )

        zoneQueryResult = mapQueryOutcomeToZoneQueryResult(outcome)
        isLoading = false
    }

    private func selectedDatasetIDsForRendering() -> Set<String> {
        Set(
            provider.datasets
                .filter { selectedDatasetIDs.contains($0.id) && $0.capabilities.supportsRendering }
                .map(\.id)
        )
    }

    private func selectedDatasetIDsForQuerying() -> Set<String> {
        Set(
            provider.datasets
                .filter { selectedDatasetIDs.contains($0.id) && $0.capabilities.supportsQuerying }
                .map(\.id)
        )
    }

    private func mapQueryOutcomeToZoneQueryResult(_ outcome: ProviderQueryOutcome) -> ZoneQueryResult {
        switch outcome {
        case .noMatches:
            return .clear(reason: .noMatchingRestrictions)
        case .unavailable(let reason):
            return .unavailable(reason: mapUnavailableReason(reason))
        case .matches(let records):
            let features = normalizer.normalize(records: records)
                .sorted { lhs, rhs in
                    if lhs.category.displayPriority != rhs.category.displayPriority {
                        return lhs.category.displayPriority < rhs.category.displayPriority
                    }

                    return lhs.id < rhs.id
                }
            let assessment = ZoneAssessmentEvaluator.evaluate(features: features)
            return .matches(features: features, assessment: assessment)
        }
    }

    private func mapUnavailableReason(_ reason: ProviderQueryUnavailableReason) -> UnavailableReason {
        switch reason {
        case .outsideCoverage:
            return .outsideCoverage
        case .requestFailed(let details):
            return .requestFailed(details: details)
        case .providerNoData:
            return .providerNoData
        case .invalidResponse:
            return .invalidResponse
        }
    }

    private func persistSelectedDatasetIDs() {
        UserDefaults.standard.set(Array(selectedDatasetIDs).sorted(), forKey: selectionStorageKey)
    }

    private func persistStatusSnapshot(_ statusSnapshot: ProviderStatusSnapshot) {
        guard let data = try? JSONEncoder().encode(statusSnapshot) else {
            return
        }

        UserDefaults.standard.set(data, forKey: statusStorageKey)
    }

    private static func loadSelectedDatasetIDs(for provider: any GeospatialProvider) -> Set<String> {
        let storageKey = "provider.selected-datasets.\(provider.id)"
        if let savedDatasetIDs = UserDefaults.standard.stringArray(forKey: storageKey) {
            return Set(savedDatasetIDs)
        }

        return Set(provider.datasets.filter(\.isSelectedByDefault).map(\.id))
    }

    private static func loadStatusSnapshot(
        for provider: any GeospatialProvider,
        storageKey: String
    ) -> ProviderStatusSnapshot {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let snapshot = try? JSONDecoder().decode(ProviderStatusSnapshot.self, from: data)
        else {
            return .unknown(for: provider.datasets)
        }

        return snapshot
    }
}
