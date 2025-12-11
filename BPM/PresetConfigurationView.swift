//
//  PresetConfigurationView.swift
//  BPM
//
//  Created for timer preset feature
//

import SwiftUI

struct PresetConfigurationView: View {
    @ObservedObject var presetStorage = PresetStorage.shared
    @Binding var isPresented: Bool
    var currentPresetId: UUID?
    var onLoadPreset: (TimerPreset) -> Void
    var onClearPreset: () -> Void

    @State private var isCreatingNew = false
    @State private var editingPreset: TimerPreset?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if presetStorage.presets.isEmpty && !isCreatingNew {
                    emptyStateView
                } else {
                    presetListView
                }
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isCreatingNew = true
                        editingPreset = TimerPreset()
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.white)
                    }
                }
            }
            .sheet(item: $editingPreset) { preset in
                PresetEditorView(
                    preset: preset,
                    isNew: isCreatingNew,
                    onSave: { savedPreset in
                        presetStorage.savePreset(savedPreset)
                        editingPreset = nil
                        isCreatingNew = false
                    },
                    onCancel: {
                        editingPreset = nil
                        isCreatingNew = false
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "timer")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No Presets")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)

            Text("Create a preset to quickly load\ninterval workouts.")
                .font(.system(size: 16))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button {
                isCreatingNew = true
                editingPreset = TimerPreset()
            } label: {
                Text("Create Preset")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color.white)
                    .cornerRadius(12)
            }
            .padding(.top, 12)
        }
    }

    private var presetListView: some View {
        VStack(spacing: 0) {
            List {
                ForEach(presetStorage.presets) { preset in
                    let isCurrentPreset = preset.id == currentPresetId

                    HStack {
                        PresetRowView(preset: preset)

                        Spacer()

                        if isCurrentPreset {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .font(.system(size: 22))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isCurrentPreset {
                            // Tapping the currently loaded preset clears it
                            onClearPreset()
                            isPresented = false
                        } else {
                            onLoadPreset(preset)
                            isPresented = false
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            presetStorage.deletePreset(preset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            isCreatingNew = false
                            editingPreset = preset
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.gray.opacity(0.3))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            // Clear Preset button (only shown when a preset is loaded)
            if currentPresetId != nil {
                Button {
                    onClearPreset()
                    isPresented = false
                } label: {
                    Text("Clear Preset")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

struct PresetRowView: View {
    let preset: TimerPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preset.name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "repeat")
                    Text("\(preset.numberOfSets) sets")
                }
                HStack(spacing: 4) {
                    Image(systemName: "flame")
                    Text(formatDuration(preset.workDuration))
                }
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle")
                    Text(formatDuration(preset.restDuration))
                }
                if preset.includeCooldown {
                    HStack(spacing: 4) {
                        Image(systemName: "snowflake")
                        Text("2m")
                    }
                }
                if preset.playSound {
                    Image(systemName: "speaker.wave.2")
                }
            }
            .font(.system(size: 14))
            .foregroundColor(.gray)

            Text("Total: \(preset.formattedTotalDuration)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.green)
        }
        .padding(.vertical, 8)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 && seconds > 0 {
            return "\(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(seconds)s"
    }
}

struct PresetEditorView: View {
    @State private var preset: TimerPreset
    let isNew: Bool
    var onSave: (TimerPreset) -> Void
    var onCancel: () -> Void

    @State private var workMinutes: Int
    @State private var workSeconds: Int
    @State private var restMinutes: Int
    @State private var restSeconds: Int

    init(preset: TimerPreset, isNew: Bool, onSave: @escaping (TimerPreset) -> Void, onCancel: @escaping () -> Void) {
        self._preset = State(initialValue: preset)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel

        let workTotal = Int(preset.workDuration)
        self._workMinutes = State(initialValue: workTotal / 60)
        self._workSeconds = State(initialValue: workTotal % 60)

        let restTotal = Int(preset.restDuration)
        self._restMinutes = State(initialValue: restTotal / 60)
        self._restSeconds = State(initialValue: restTotal % 60)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Name field
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Name")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)

                            HStack {
                                TextField("Preset name", text: $preset.name)
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)

                                if !preset.name.isEmpty {
                                    Button {
                                        preset.name = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                            .font(.system(size: 18))
                                    }
                                }
                            }
                            .padding(14)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                        }

                        // Number of sets
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Number of Sets")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)

                            Stepper(value: $preset.numberOfSets, in: 1...50) {
                                Text("\(preset.numberOfSets) sets")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(14)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                        }

                        // Work duration
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Work Duration")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)

                            HStack(spacing: 16) {
                                DurationPicker(
                                    label: "min",
                                    value: $workMinutes,
                                    range: 0...30
                                )

                                DurationPicker(
                                    label: "sec",
                                    value: $workSeconds,
                                    range: 0...59
                                )
                            }
                        }

                        // Rest duration
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rest Duration")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)

                            HStack(spacing: 16) {
                                DurationPicker(
                                    label: "min",
                                    value: $restMinutes,
                                    range: 0...30
                                )

                                DurationPicker(
                                    label: "sec",
                                    value: $restSeconds,
                                    range: 0...59
                                )
                            }
                        }

                        // Cooldown toggle
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $preset.includeCooldown) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Include Cooldown")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("2-minute recovery period at the end")
                                        .font(.system(size: 14))
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.green)
                            .padding(14)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                        }

                        // Sound toggle
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $preset.playSound) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Play Sound")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("Alert at the end of each round")
                                        .font(.system(size: 14))
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.green)
                            .padding(14)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                        }

                        // Summary
                        VStack(spacing: 8) {
                            Divider()
                                .background(Color.gray.opacity(0.3))

                            HStack {
                                Text("Total Duration")
                                    .font(.system(size: 16))
                                    .foregroundColor(.gray)
                                Spacer()
                                Text(calculatedPreset.formattedTotalDuration)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.green)
                            }
                            .padding(.top, 8)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(isNew ? "New Preset" : "Edit Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave(calculatedPreset)
                    }
                    .foregroundColor(.green)
                    .disabled(!isValid)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var calculatedPreset: TimerPreset {
        var updated = preset
        updated.workDuration = TimeInterval(workMinutes * 60 + workSeconds)
        updated.restDuration = TimeInterval(restMinutes * 60 + restSeconds)
        updated.includeCooldown = preset.includeCooldown
        return updated
    }

    private var isValid: Bool {
        !preset.name.isEmpty && (workMinutes > 0 || workSeconds > 0)
    }
}

struct DurationPicker: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if value > range.lowerBound {
                    value -= 1
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(value > range.lowerBound ? .white : .gray.opacity(0.5))
            }
            .disabled(value <= range.lowerBound)

            VStack(spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(minWidth: 50)

                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            Button {
                if value < range.upperBound {
                    value += 1
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(value < range.upperBound ? .white : .gray.opacity(0.5))
            }
            .disabled(value >= range.upperBound)
        }
        .padding(14)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(10)
    }
}

#Preview {
    PresetConfigurationView(isPresented: .constant(true), currentPresetId: nil, onLoadPreset: { _ in }, onClearPreset: { })
}
