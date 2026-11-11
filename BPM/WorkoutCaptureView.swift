import SwiftUI

/// The complete save form owns recording and generation so no second screen is needed.
struct WorkoutCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    private enum VoiceState { case idle, starting, recording, ready, processing, complete }
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
                    voiceControls
                        .disabled(isSaving)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    if let message = errorMessage ?? recorder.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("voiceCaptureMessage")
                    }
                } footer: {
                    adaptiveControlLayout {
                        voiceSecondaryControl
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Link(destination: URL(string: "https://bpmtracker.app/privacy.html#ai-voice")!) {
                            Text("Voice privacy")
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var voiceState: VoiceState {
        if isGenerating { return .processing }
        if recorder.isRequestingPermission { return .starting }
        if recorder.isRecording { return .recording }
        if recorder.audioURL != nil { return .ready }
        if previousFields != nil { return .complete }
        return .idle
    }

    private var voiceActionTitle: String {
        switch voiceState {
        case .idle: return "Record workout notes"
        case .starting: return "Starting recording…"
        case .recording: return "Recording…"
        case .ready: return "Send recording"
        case .processing: return "Processing…"
        case .complete: return "Notes ready"
        }
    }

    private var voiceActionSubtitle: String {
        switch voiceState {
        case .idle: return "AI turns your words into notes."
        case .starting: return "Waiting for microphone access."
        case .recording: return "Tap to send · \(recordingTime(recorder.duration)) / \(recordingTime(WorkoutDictation.maximumDuration))"
        case .ready: return "Tap to create your workout notes."
        case .processing: return "Creating your workout notes."
        case .complete: return "Tap to rerecord."
        }
    }

    private var voiceActionIcon: String {
        switch voiceState {
        case .idle, .starting: return "waveform"
        case .recording: return "record.circle"
        case .ready: return "arrow.up"
        case .processing: return "waveform"
        case .complete: return "checkmark"
        }
    }

    private var voiceActionHint: String {
        switch voiceState {
        case .idle: return "Record up to \(Int(WorkoutDictation.maximumDuration)) seconds to create a workout title and description."
        case .starting: return "Waiting for microphone access."
        case .recording: return "Stops recording and sends it to create your workout notes."
        case .ready: return "Sends your recording to create a workout title and description."
        case .processing: return "Creating your workout notes."
        case .complete: return "Starts a new recording. Your current notes stay until the new result is ready."
        }
    }

    private var voiceControls: some View {
        Button {
            switch voiceState {
            case .idle, .complete:
                startRecording()
            case .recording, .ready:
                requestSendRecording()
            case .starting, .processing:
                break
            }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if voiceState == .processing || voiceState == .starting {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: voiceActionIcon)
                            .font(.title3.weight(.semibold))
                    }
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(voiceActionTitle).font(.headline)
                    Text(voiceActionSubtitle)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.black.opacity(0.7))
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        }
        .bpmActionStyle(prominent: true)
        .tint(.white)
        .disabled(isGenerating || recorder.isRequestingPermission || (recorder.isRecording && recorder.duration < 0.5))
        .accessibilityLabel(voiceActionTitle)
        .accessibilityValue(voiceState == .recording || voiceState == .ready
            ? "\(Int(recorder.duration)) of \(Int(WorkoutDictation.maximumDuration)) seconds recorded"
            : "")
        .accessibilityHint(voiceActionHint)
        .accessibilityIdentifier("voiceCaptureAction")
    }

    @ViewBuilder private var voiceSecondaryControl: some View {
        Group {
            switch voiceState {
            case .recording:
                voiceSecondaryButton("Stop") { recorder.finishRecording() }
            case .ready:
                voiceSecondaryButton("Record again") { startRecording() }
            case .processing:
                voiceSecondaryButton("Cancel request") {
                    AppAnalytics.signal(.voiceRecapCancelled)
                    generationTask?.cancel()
                    generationTask = nil
                    isGenerating = false
                }
            case .complete:
                voiceSecondaryButton("Undo AI changes") {
                    if let previousFields {
                        title = previousFields.title
                        notes = previousFields.description
                    }
                    previousFields = nil
                }
            case .idle, .starting:
                Text("Up to \(Int(WorkoutDictation.maximumDuration)) seconds")
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .disabled(isSaving)
    }

    private func voiceSecondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(.tint)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private var adaptiveControlLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 16))
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
