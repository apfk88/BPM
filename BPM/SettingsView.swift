//
//  SettingsView.swift
//  BPM
//
//  Created by OpenAI on 11/5/25.
//

import SwiftUI

struct SettingsView: View {
    let onConfigureZones: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isHeartRateAlertEnabled = false
    @State private var isZoneAlertEnabled = false

    var body: some View {
        NavigationView {
            List {
                Section("Heart Rate Zones") {
                    Button("Heart Rate Zone Settings") {
                        onConfigureZones()
                    }
                }

                Section(
                    header: Text("Alerts"),
                    footer: Text("Alert toggles default to off. These will play sounds in the background and include a cooldown so hovering near a boundary does not spam you.")
                ) {
                    Toggle("Heart Rate Alert", isOn: $isHeartRateAlertEnabled)
                    Toggle("Zone Alert", isOn: $isZoneAlertEnabled)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(onConfigureZones: {})
}
