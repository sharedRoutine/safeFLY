//
//  SettingsView.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import SwiftUI

struct SettingsView: View {
    private struct DatasetSection: Identifiable {
        let title: String?
        var datasets: [ProviderDataset]

        var id: String {
            title ?? "ungrouped"
        }
    }

    @EnvironmentObject var droneSettings: DroneSettings
    @EnvironmentObject var providerSession: ProviderSession
    @Environment(\.dismiss) var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private var datasetSections: [DatasetSection] {
        var sections: [DatasetSection] = []

        for dataset in providerSession.datasetCatalog {
            if let index = sections.firstIndex(where: { $0.title == dataset.presentation.groupTitle }) {
                sections[index].datasets.append(dataset)
            } else {
                sections.append(DatasetSection(title: dataset.presentation.groupTitle, datasets: [dataset]))
            }
        }

        return sections
    }
    
    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        return "\(version)"
    }
    
    var copyrightText: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Jan Grüttefien and safeFLY contributors"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Drone Class", selection: $droneSettings.droneClass) {
                        ForEach(DroneClass.allCases, id: \.self) { droneClass in
                            Text(droneClass.description).tag(droneClass)
                        }
                    }
                    
                    TextField("UAV e-ID", text: $droneSettings.operatorID)
                        .textContentType(.none)
                        .autocapitalization(.allCharacters)
                } header: {
                    Text("Drone Information")
                } footer: {
                    Text("Save your UAV e-ID (e.g., DEU3otef849kry8h)")                    
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(datasetSections.enumerated()), id: \.offset) { index, section in
                            if let title = section.title {
                                SectionHeader(title: title)
                            }

                            ForEach(section.datasets) { dataset in
                                Toggle(
                                    dataset.presentation.title,
                                    isOn: Binding(
                                        get: { providerSession.selectedDatasetIDs.contains(dataset.id) },
                                        set: { providerSession.setDatasetSelected(dataset.id, isSelected: $0) }
                                    )
                                )
                            }

                            if index < datasetSections.count - 1 {
                                Divider()
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                } header: {
                    Text("Map Layers")
                } footer: {
                    Text("Toggle specific layers to customize which restrictions are displayed on the map.")
                }
                
                Section {
                    Link("Support the Developer", destination: URL(string: "https://buymeacoffee.com/jan04")!)
                    Link("App Webpage & Status", destination: URL(string: "https://gruettecloud.com/safeFLY")!)
                    Link("Contact", destination: URL(string: "https://gruettecloud.com/support")!)
                    Link("GitHub", destination: URL(string: "https://github.com/xelemir/safeFLY")!)
                    Link("DFS DIPUL Datasource", destination: URL(string: "https://uas-betrieb.dfs.de/homepage/")!)
                } header: {
                    Text("Resources")
                }
                
                Section {
                    Button {
                        hasCompletedOnboarding = false
                        dismiss()
                    } label: {
                        Text("Play App Introduction Again")
                    }
                } header: {
                    Text("App Setup")
                }
                
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                } footer: {
                    Link(destination: URL(string: "https://jan.gruettefien.com")!) {
                        Text(copyrightText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Done", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(DroneSettings())
        .environmentObject(ProviderSession(provider: DIPULProvider(), normalizer: ZoneFeatureNormalizer()))
}
