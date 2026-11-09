import SwiftUI

/// The complete save form owns recording and generation so no second screen is needed.
struct WorkoutCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var title: String
    @Binding var notes: String
    @AppStorage(WorkoutVoiceConsent.defaultsKey) private var hasVoiceConsent = false
    @FocusState private var focusedField: Field?
    @StateObject private var recorder = WorkoutDictation()
    @State private var recordingTask: Task<Void, Never>?
    @State private var generationTask: Task<Void, Never>?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var previousFields: WorkoutRecap?
    @State private var showVoiceConsent = false
    @State private var isSaving = false
    let prepareAudio: () -> Void
    let save: () async throws -> Void
    var generate: (URL) async throws -> WorkoutRecap = { url in
#if DEBUG && targetEnvironment(simulator)
        // Deterministic UI verification only. Release/device builds always use the real service.
        if ProcessInfo.processInfo.arguments.contains("--workout-voice-ui-test") {
            try await Task.sleep(for: .seconds(4))
            return WorkoutRecap(title: "Squats and push-ups", description: "3 sets of 8 squats at 62.5 kg. Maybe 9 reps on the last set. Left knee felt odd.")
        }
#endif
        return try await WorkoutRecapClient().generate(audioURL: url)
    }

    private enum Field: Hashable { case title, notes }
    private var isBusy: Bool { isSaving || isGenerating || recorder.isRecording || recorder.isRequestingPermission }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($focusedField, equals: .title)
                        .textInputAutocapitalization(.words)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $notes)
                            .accessibilityLabel("Workout description")
                            .focused($focusedField, equals: .notes)
                            .frame(minHeight: 140)
                    }
                }
                .disabled(isGenerating || isSaving)
                Section {
                    voiceControls.disabled(isSaving)
                    if let message = errorMessage ?? recorder.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("voiceCaptureMessage")
                    }
                    if previousFields != nil {
                        Button("Undo AI changes", systemImage: "arrow.uturn.backward") {
                            if let previousFields {
                                title = previousFields.title
                                notes = previousFields.description
                            }
                            previousFields = nil
                        }.disabled(isBusy)
                    }
                } footer: {
                    Link("Voice privacy", destination: URL(string: "https://bpmtracker.app/privacy.html#ai-voice")!)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save Workout")
            .analyticsScreen(.workoutSave)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        focusedField = nil
                        isSaving = true
                        Task {
                            do {
                                try await save()
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                                isSaving = false
                            }
                        }
                    }.disabled(isBusy)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .alert("Send recording?", isPresented: $showVoiceConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Allow & Send") {
                hasVoiceConsent = true
                sendRecording()
            }
        } message: {
            Text("BPM sends your recording, including any health details you mention, to \(WorkoutVoiceConsent.providerName) for AI transcription and workout notes. Review the result before saving.")
        }
        .onDisappear {
            recordingTask?.cancel()
            if isGenerating { AppAnalytics.signal(.voiceRecapCancelled) }
            isGenerating = false
            generationTask?.cancel()
            recorder.discardRecording()
        }
    }

    @ViewBuilder private var voiceControls: some View {
        if isGenerating {
            HStack {
                ProgressView()
                Text("Loading title and description…")
            }.accessibilityIdentifier("voiceCaptureLoading")
            Button("Cancel request") {
                AppAnalytics.signal(.voiceRecapCancelled)
                generationTask?.cancel()
                generationTask = nil
                isGenerating = false
            }
        } else if recorder.isRecording || recorder.audioURL != nil {
            HStack {
                Image(systemName: recorder.isRecording ? "record.circle" : "waveform")
                    .foregroundStyle(recorder.isRecording ? .red : .secondary)
                Text(recorder.isRecording ? "Recording" : "Ready to send")
                Spacer()
                Text("\(recordingTime(recorder.duration)) / \(recordingTime(WorkoutDictation.maximumDuration))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                if recorder.isRecording {
                    Button("Stop", systemImage: "stop.fill") { recorder.finishRecording() }
                } else {
                    Button("Record again", systemImage: "arrow.counterclockwise") { startRecording() }
                }
                Spacer()
                Button(action: requestSendRecording) {
                    Label("Send", systemImage: "arrow.up.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(recorder.duration < 0.5)
            }.buttonStyle(.borderless)
        } else {
            Button(action: startRecording) {
                HStack {
                    Label("AI voice", systemImage: "waveform")
                    Spacer()
                    if recorder.isRequestingPermission { ProgressView() }
                    else { Text("Up to \(Int(WorkoutDictation.maximumDuration)) sec").font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            .accessibilityLabel("Record workout with AI voice")
            .disabled(recorder.isRequestingPermission)
        }
    }

    private func recordingTime(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func startRecording() {
        focusedField = nil
        errorMessage = nil
        recordingTask = Task { await recorder.start(prepareAudio: prepareAudio) }
    }

    private func sendRecording() {
        recorder.finishRecording()
        guard hasVoiceConsent, let url = recorder.audioURL, !isGenerating else { return }
        focusedField = nil
        errorMessage = nil
        isGenerating = true
        AppAnalytics.signal(.voiceRecapRequested)
        generationTask = Task {
            do {
                let result = try await generate(url)
                guard !Task.isCancelled else { return }
                AppAnalytics.signal(.voiceRecapCompleted)
                previousFields = WorkoutRecap(title: title, description: notes)
                title = result.title
                notes = result.description
                recorder.discardRecording()
                isGenerating = false
            } catch {
                guard !Task.isCancelled else { return }
                AppAnalytics.signal(.voiceRecapFailed, parameters: ["category": AppFailureCategory(error: error).rawValue])
                errorMessage = (error as? URLError)?.code == .notConnectedToInternet
                    ? "You’re offline. Your recording is ready to send when you reconnect."
                    : error.localizedDescription
                isGenerating = false
            }
        }
    }

    private func requestSendRecording() {
        recorder.finishRecording()
        guard recorder.audioURL != nil, !isGenerating else { return }
        focusedField = nil
        if hasVoiceConsent {
            sendRecording()
        } else {
            showVoiceConsent = true
        }
    }
}
