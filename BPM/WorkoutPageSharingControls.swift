import SwiftUI
import UIKit

/// One explicit sharing session. The drawer owns this draft across its card editor.
@MainActor
final class WorkoutPageShareDraft: ObservableObject {
    let record: WorkoutRecord
    let workoutDate: String
    @Published var includesPage = false {
        didSet {
            if includesPage { startBackgroundUpload() }
        }
    }
    @Published var title: String
    @Published var description: String
    @Published var includeDate = false
    @Published private(set) var isUploading = false
    @Published private(set) var isPreparingShare = false
    @Published private(set) var uploadStatusText = "Uploading workout…"
    @Published var errorMessage: String?
    @Published var needsUpdateConfirmation = false
    private var continuation: ((URL?) -> Void)?
    private var backgroundUpload: Task<Void, Never>?
    private var preparedUpload = false
    private let service: WorkoutPageService

    init(record: WorkoutRecord, service: WorkoutPageService? = nil) {
        let service = service ?? .shared
        self.record = record
        self.service = service
        workoutDate = service.entry(for: record.id)?.workoutDate
            ?? WorkoutPageDate.string(from: record.startAt) ?? ""
        title = WorkoutShareSnapshot(record: record).title
        description = record.notes ?? ""
    }

    func prepareShare(then completion: @escaping (URL?) -> Void) {
        guard !isPreparingShare else { return }
        continuation = completion
        guard includesPage else {
            finish(with: nil)
            return
        }
        upload(updateExisting: false)
    }

    func retry() { upload(updateExisting: false) }
    func updateAndShare() { upload(updateExisting: true) }

    func shareWithoutLink() {
        includesPage = false
        errorMessage = nil
        finish(with: nil)
    }

    func cancel() {
        continuation = nil
        errorMessage = nil
        needsUpdateConfirmation = false
        // A completed background upload remains inaccessible and expires on the
        // server. Never activate it merely because the drawer was dismissed.
    }

    private func startBackgroundUpload() {
        guard backgroundUpload == nil, !isPreparingShare, !preparedUpload else { return }
        isUploading = true
        let title = title
        let description = description
        let includeDate = includeDate
        backgroundUpload = Task { [weak self] in
            guard let self else { return }
            defer {
                isUploading = false
                backgroundUpload = nil
            }
            do {
                try await service.stageShare(record: record, title: title, description: description,
                                             includeDate: includeDate, workoutDate: workoutDate)
                preparedUpload = true
            } catch {
                // Keep the opt-in unobtrusive. The final Share retries and presents
                // an actionable error if preparation still cannot finish.
            }
        }
    }

    private func upload(updateExisting: Bool) {
        guard !isPreparingShare, continuation != nil else { return }
        isPreparingShare = true
        errorMessage = nil
        needsUpdateConfirmation = false
        uploadStatusText = isUploading ? "Uploading workout…" : "Preparing link…"
        let title = title
        let description = description
        let includeDate = includeDate
        Task {
            defer { isPreparingShare = false }
            await backgroundUpload?.value
            guard continuation != nil, includesPage else { return }
            do {
                // Retrying preparation is idempotent, including a failed or expired
                // background stage. The following call alone activates the link.
                if !updateExisting && !preparedUpload {
                    isUploading = true
                    uploadStatusText = "Uploading workout…"
                    do {
                        try await service.stageShare(record: record, title: title, description: description,
                                                     includeDate: includeDate, workoutDate: workoutDate)
                    } catch {
                        isUploading = false
                        throw error
                    }
                    isUploading = false
                    preparedUpload = true
                }
                guard continuation != nil, includesPage else { return }
                uploadStatusText = updateExisting ? "Uploading workout…" : "Preparing link…"
                let url = try await service.prepareShare(
                    record: record, title: title, description: description,
                    includeDate: includeDate, workoutDate: workoutDate, updateExisting: updateExisting
                )
                finish(with: url)
            } catch WorkoutPageError.updateRequired {
                needsUpdateConfirmation = true
            } catch is CancellationError {
                cancel()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finish(with url: URL?) {
        let completion = continuation
        continuation = nil
        completion?(url)
    }
}

struct WorkoutPageSharingOptions: View {
    @ObservedObject var draft: WorkoutPageShareDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                draft.includesPage.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: draft.includesPage ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .frame(width: 24)
                    Text("Include private workout link")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Include private workout link")
            .accessibilityValue(draft.includesPage ? "On" : "Off")
            .accessibilityIdentifier("includeWorkoutPage")

            Text("Anyone with the link can view and download your workout until you delete it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("workoutPageDisclosure")
        }
        .disabled(draft.isPreparingShare)
    }
}

private struct WorkoutPageShareAlerts: ViewModifier {
    @ObservedObject var draft: WorkoutPageShareDraft
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(draft.isPreparingShare)
            .alert("Couldn’t Create Workout Link", isPresented: Binding(
                get: { isActive && draft.errorMessage != nil },
                set: { if isActive && !$0 { draft.errorMessage = nil } }
            )) {
                Button("Retry") { draft.retry() }
                Button("Share without link") { draft.shareWithoutLink() }
                Button("Cancel", role: .cancel) { draft.cancel() }
            } message: {
                Text(draft.errorMessage ?? "Please try again.")
            }
            .confirmationDialog("Update the existing workout page?", isPresented: Binding(
                get: { isActive && draft.needsUpdateConfirmation },
                set: { if isActive { draft.needsUpdateConfirmation = $0 } }
            ),
                                titleVisibility: .visible) {
                Button("Update Page and Share") { draft.updateAndShare() }
                Button("Share without link") { draft.shareWithoutLink() }
                Button("Cancel", role: .cancel) { draft.cancel() }
            } message: {
                Text("Anyone with the existing link will see these new details. The link stays the same.")
            }
    }
}

extension View {
    func workoutPageShareAlerts(_ draft: WorkoutPageShareDraft, isActive: Bool = true) -> some View {
        modifier(WorkoutPageShareAlerts(draft: draft, isActive: isActive))
    }
}
