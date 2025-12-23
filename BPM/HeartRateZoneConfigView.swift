//
//  HeartRateZoneConfigView.swift
//  BPM
//

import SwiftUI

struct HeartRateZoneConfigView: View {
    @Binding var isPresented: Bool
    @ObservedObject var storage = HeartRateZoneStorage.shared

    @State private var maxHeartRate: String = ""
    @State private var zone1Min: String = ""
    @State private var zone1Max: String = ""
    @State private var zone2Min: String = ""
    @State private var zone2Max: String = ""
    @State private var zone3Min: String = ""
    @State private var zone3Max: String = ""
    @State private var zone4Min: String = ""
    @State private var zone4Max: String = ""
    @State private var zone5Min: String = ""
    @State private var zone5Max: String = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Max Heart Rate Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Max Heart Rate")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)

                            HStack {
                                TextField("", text: $maxHeartRate)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.gray.opacity(0.3))
                                    .cornerRadius(8)
                                    .onChange(of: maxHeartRate) { _, newValue in
                                        if let hrMax = Int(newValue), hrMax > 0 {
                                            recalculateZones(from: hrMax)
                                        }
                                    }

                                Text("BPM")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.gray)
                            }

                            Text("If you don't know your max heart rate, use 220 minus your age.")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal, 20)

                        Divider()
                            .background(Color.gray.opacity(0.5))
                            .padding(.horizontal, 20)

                        // Zone Configuration
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Heart Rate Zones")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)

                            Text("Zones are auto-calculated from your max HR. You can override individual values.")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                                .padding(.horizontal, 20)

                            zoneRow(
                                zone: .zone1,
                                minValue: $zone1Min,
                                maxValue: $zone1Max
                            )

                            zoneRow(
                                zone: .zone2,
                                minValue: $zone2Min,
                                maxValue: $zone2Max
                            )

                            zoneRow(
                                zone: .zone3,
                                minValue: $zone3Min,
                                maxValue: $zone3Max
                            )

                            zoneRow(
                                zone: .zone4,
                                minValue: $zone4Min,
                                maxValue: $zone4Max
                            )

                            zoneRow(
                                zone: .zone5,
                                minValue: $zone5Min,
                                maxValue: $zone5Max
                            )

                            // Validation error message
                            if let error = validationError {
                                Text(error)
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 4)
                            }
                        }

                        // Clear Configuration Button
                        if storage.isConfigured {
                            Button {
                                storage.config = nil
                                isPresented = false
                            } label: {
                                Text("Clear Zone Configuration")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.red)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Heart Rate Zones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .foregroundColor(.white)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveConfiguration()
                        isPresented = false
                    }
                    .foregroundColor(.green)
                    .disabled(!isValidConfiguration)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            loadExistingConfiguration()
        }
    }

    @ViewBuilder
    private func zoneRow(zone: HeartRateZone, minValue: Binding<String>, maxValue: Binding<String>) -> some View {
        HStack(spacing: 12) {
            // Zone indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(zone.displayName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(zone.color)

                Text(zone.percentageRange)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .frame(width: 60, alignment: .leading)

            // Min field
            TextField("", text: minValue)
                .keyboardType(.numberPad)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(6)
                .frame(width: 70)

            Text("-")
                .foregroundColor(.gray)

            // Max field
            TextField("", text: maxValue)
                .keyboardType(.numberPad)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(6)
                .frame(width: 70)

            Text("BPM")
                .font(.system(size: 14))
                .foregroundColor(.gray)

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var isValidConfiguration: Bool {
        guard let hrMax = Int(maxHeartRate), hrMax > 0 else { return false }
        guard let z1Min = Int(zone1Min), let z1Max = Int(zone1Max) else { return false }
        guard let z2Min = Int(zone2Min), let z2Max = Int(zone2Max) else { return false }
        guard let z3Min = Int(zone3Min), let z3Max = Int(zone3Max) else { return false }
        guard let z4Min = Int(zone4Min), let z4Max = Int(zone4Max) else { return false }
        guard let z5Min = Int(zone5Min), let z5Max = Int(zone5Max) else { return false }

        // Validate each zone's min < max
        guard z1Min < z1Max, z2Min < z2Max, z3Min < z3Max, z4Min < z4Max, z5Min < z5Max else {
            return false
        }

        // Validate zones don't overlap: each zone's min should be >= previous zone's max
        guard z2Min >= z1Max, z3Min >= z2Max, z4Min >= z3Max, z5Min >= z4Max else {
            return false
        }

        return true
    }

    private var validationError: String? {
        guard let hrMax = Int(maxHeartRate), hrMax > 0 else {
            return "Enter a valid max heart rate"
        }
        guard let z1Min = Int(zone1Min), let z1Max = Int(zone1Max),
              let z2Min = Int(zone2Min), let z2Max = Int(zone2Max),
              let z3Min = Int(zone3Min), let z3Max = Int(zone3Max),
              let z4Min = Int(zone4Min), let z4Max = Int(zone4Max),
              let z5Min = Int(zone5Min), let z5Max = Int(zone5Max) else {
            return "Fill in all zone values"
        }

        if z1Min >= z1Max { return "Z1 min must be less than max" }
        if z2Min >= z2Max { return "Z2 min must be less than max" }
        if z3Min >= z3Max { return "Z3 min must be less than max" }
        if z4Min >= z4Max { return "Z4 min must be less than max" }
        if z5Min >= z5Max { return "Z5 min must be less than max" }

        if z2Min < z1Max { return "Z2 overlaps with Z1" }
        if z3Min < z2Max { return "Z3 overlaps with Z2" }
        if z4Min < z3Max { return "Z4 overlaps with Z3" }
        if z5Min < z4Max { return "Z5 overlaps with Z4" }

        return nil
    }

    private func loadExistingConfiguration() {
        if let config = storage.config {
            maxHeartRate = String(config.maxHeartRate)
            zone1Min = String(config.zone1Min)
            zone1Max = String(config.zone1Max)
            zone2Min = String(config.zone2Min)
            zone2Max = String(config.zone2Max)
            zone3Min = String(config.zone3Min)
            zone3Max = String(config.zone3Max)
            zone4Min = String(config.zone4Min)
            zone4Max = String(config.zone4Max)
            zone5Min = String(config.zone5Min)
            zone5Max = String(config.zone5Max)
        }
    }

    private func recalculateZones(from hrMax: Int) {
        let config = HeartRateZoneConfig(maxHeartRate: hrMax)
        zone1Min = String(config.zone1Min)
        zone1Max = String(config.zone1Max)
        zone2Min = String(config.zone2Min)
        zone2Max = String(config.zone2Max)
        zone3Min = String(config.zone3Min)
        zone3Max = String(config.zone3Max)
        zone4Min = String(config.zone4Min)
        zone4Max = String(config.zone4Max)
        zone5Min = String(config.zone5Min)
        zone5Max = String(config.zone5Max)
    }

    private func saveConfiguration() {
        guard let hrMax = Int(maxHeartRate),
              let z1Min = Int(zone1Min), let z1Max = Int(zone1Max),
              let z2Min = Int(zone2Min), let z2Max = Int(zone2Max),
              let z3Min = Int(zone3Min), let z3Max = Int(zone3Max),
              let z4Min = Int(zone4Min), let z4Max = Int(zone4Max),
              let z5Min = Int(zone5Min), let z5Max = Int(zone5Max) else {
            return
        }

        var config = HeartRateZoneConfig(maxHeartRate: hrMax)
        config.zone1Min = z1Min
        config.zone1Max = z1Max
        config.zone2Min = z2Min
        config.zone2Max = z2Max
        config.zone3Min = z3Min
        config.zone3Max = z3Max
        config.zone4Min = z4Min
        config.zone4Max = z4Max
        config.zone5Min = z5Min
        config.zone5Max = z5Max

        storage.config = config
    }
}
