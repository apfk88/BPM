import SwiftUI
import UIKit

struct WorkoutSharedPagesView: View {
    @ObservedObject private var service: WorkoutPageService
    @State private var errorMessage: String?
    @State private var recoverySheet: RecoverySheet?

    private enum RecoverySheet: String, Identifiable {
        case backup, restore
        var id: String { rawValue }
    }

    init(service: WorkoutPageService? = nil) {
        self.service = service ?? .shared
    }

    var body: some View {
        List {
            Section {
                ForEach(service.entries) { entry in
                    NavigationLink {
                        WorkoutSharedPageDetail(initialEntry: entry, service: service)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title.isEmpty ? "Workout" : entry.title)
                                .font(.headline)
                            HStack(spacing: 8) {
                                Text(entry.createdAt, style: .date)
                                Text(entry.hasPendingDeletion ? "Deletion pending" : entry.status == .pending ? "Upload pending" : "Private link")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("Pages have no automatic expiration. They remain here even after their workouts are removed from local history.")
            }
            Section("Recovery") {
                Button("Save Recovery Code") { recoverySheet = .backup }
                    .accessibilityIdentifier("saveWorkoutPageRecovery")
                Button("Restore Shared Pages") { recoverySheet = .restore }
                    .accessibilityIdentifier("restoreWorkoutPages")
            }
        }
        .overlay {
            if service.entries.isEmpty {
                ContentUnavailableView("No shared pages", systemImage: "link",
                                       description: Text("Include a private workout link when sharing a saved workout."))
                    .allowsHitTesting(false)
                    .offset(y: -60)
            }
        }
        .navigationTitle("Shared Pages")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if service.isWorking { ProgressView() }
            }
        }
        .sheet(item: $recoverySheet) { mode in
            WorkoutPageRecoveryView(isRestoring: mode == .restore, service: service)
        }
        .alert("Couldn’t Load Shared Pages", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private func refresh() async {
        do { try await service.refresh() }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}

/// Link access beside its saved workout. Management ownership still lives in
/// the shared-page registry when the local workout is removed.
struct WorkoutSavedPageLink: View {
    let entry: WorkoutPageEntry
    @ObservedObject var service: WorkoutPageService
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    @State private var confirmsDeletion = false
    @State private var errorMessage: String?

    private var hasUsableLink: Bool { entry.status == .published && !entry.hasPendingDeletion }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasUsableLink {
                Text(entry.pageURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("savedWorkoutPageURL")
            } else {
                Text(entry.hasPendingDeletion ? "Deletion pending" : "Link not shared yet")
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("savedWorkoutPageStatus")
                Text(entry.hasPendingDeletion
                     ? "The server hasn’t confirmed deletion. Retry it below or open Manage."
                     : "Create the link in Manage, or delete this pending page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.plain)
        }
        .onChange(of: entry.pageURL) { _, _ in copied = false }
        .confirmationDialog("Delete this shared page?", isPresented: $confirmsDeletion,
                            titleVisibility: .visible) {
            Button("Delete Shared Page", role: .destructive) {
                Task {
                    do { try await service.delete(entry) }
                    catch is CancellationError { }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The link and its shared data will be removed. Your saved workout stays on this device.")
        }
        .alert("Couldn’t Delete Shared Page", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if hasUsableLink {
            Button("Open") { openURL(entry.pageURL) }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Open private workout page")
                .accessibilityIdentifier("openSavedWorkoutPage")
            Button(copied ? "Copied" : "Copy") {
                UIPasteboard.general.string = entry.pageURL.absoluteString
                copied = true
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(copied ? "Private workout link copied" : "Copy private workout link")
            .accessibilityIdentifier("copySavedWorkoutPageLink")
        }
        NavigationLink {
            WorkoutSharedPageDetail(initialEntry: entry, service: service)
        } label: {
            Text("Manage")
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Manage private workout page")
        .accessibilityIdentifier("manageSavedWorkoutPage")
        Button(entry.hasPendingDeletion ? "Retry Deletion" : "Delete", role: .destructive) {
            confirmsDeletion = true
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .foregroundStyle(.red)
        .disabled(service.isWorking)
        .accessibilityLabel(entry.hasPendingDeletion ? "Retry deleting shared page" : "Delete private workout page")
        .accessibilityIdentifier("deleteSavedWorkoutPage")
    }
}

struct WorkoutSharedPageDetail: View {
    let initialEntry: WorkoutPageEntry
    @ObservedObject private var service: WorkoutPageService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmation: Confirmation?
    @State private var editingEntry: WorkoutPageEntry?
    @State private var copied = false
    @State private var errorMessage: String?

    private enum Confirmation: String, Identifiable {
        case delete, replace
        var id: String { rawValue }
    }

    init(initialEntry: WorkoutPageEntry, service: WorkoutPageService? = nil) {
        self.initialEntry = initialEntry
        self.service = service ?? .shared
    }

    private var entry: WorkoutPageEntry? {
        service.entries.first(where: { $0.id == initialEntry.id })
    }

    var body: some View {
        Group {
            if let entry {
                pageContent(entry)
            } else {
                ContentUnavailableView("Page removed", systemImage: "link",
                                       description: Text("This private link is no longer available."))
            }
        }
        .navigationTitle("Workout Page")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pageContent(_ entry: WorkoutPageEntry) -> some View {
        List {
            Section {
                Text(entry.title.isEmpty ? "Workout" : entry.title).font(.title3.bold())
                if !entry.description.isEmpty { Text(entry.description) }
                LabeledContent("Created", value: entry.createdAt.formatted(date: .abbreviated, time: .omitted))
            }
            if entry.status == .published && !entry.hasPendingDeletion {
                Section("Private link") {
                    Text(entry.pageURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("managedWorkoutPageURL")
                    Button { openURL(entry.pageURL) } label: {
                        Label("Open Page", systemImage: "safari")
                    }
                    .accessibilityIdentifier("openSharedWorkoutPage")
                    Button {
                        UIPasteboard.general.string = entry.pageURL.absoluteString
                        copied = true
                    } label: {
                        Label(copied ? "Link Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
                    }
                    .accessibilityIdentifier("copySharedWorkoutLink")
                    Button { editingEntry = entry } label: {
                        Label("Edit Page Details", systemImage: "pencil")
                    }
                }
                .disabled(service.isWorking)
            }

            if entry.hasPendingDeletion {
                Section {
                    Button("Retry Deletion", role: .destructive) {
                        perform { try await service.delete(entry); dismiss() }
                    }
                    .disabled(service.isWorking)
                    .accessibilityIdentifier("retrySharedWorkoutDeletion")
                    Text("The server has not confirmed deletion. This page’s controls stay here until it does.")
                        .foregroundStyle(.secondary)
                }
            } else if entry.status == .pending {
                Section {
                    Button("Create Link") {
                        perform { _ = try await service.retryPendingUpload(entry) }
                    }
                    .disabled(service.isWorking)
                    .accessibilityIdentifier("retrySharedWorkoutUpload")
                    Text("Create this private link, or remove the pending page below.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Replace Link") { confirmation = .replace }
                    .disabled(entry.status == .pending || entry.hasPendingDeletion)
                Button("Delete Shared Page", role: .destructive) { confirmation = .delete }
                    .accessibilityIdentifier("deleteSharedWorkoutPage")
            } footer: {
                Text("Replacing a link stops the previous link from working. Deleting a page stops future viewing and downloads. Copies already downloaded cannot be recalled.")
            }
            .disabled(service.isWorking)
        }
        .onChange(of: entry.pageURL) { _, _ in copied = false }
        .sheet(item: $editingEntry) { entry in
            WorkoutSharedPageEditor(entry: entry, service: service)
        }
        .confirmationDialog(confirmation == .delete ? "Delete this shared page?" : "Replace this private link?",
                            isPresented: Binding(
                                get: { confirmation != nil },
                                set: { if !$0 { confirmation = nil } }
                            ), titleVisibility: .visible) {
            if confirmation == .delete {
                Button("Delete Shared Page", role: .destructive) {
                    perform { try await service.delete(entry); dismiss() }
                }
            } else {
                Button("Replace Link", role: .destructive) {
                    perform { _ = try await service.rotateLink(entry); copied = false }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirmation == .delete
                 ? "The page and its recorded data will be removed. Your saved workout stays on this device."
                 : "People with the old link will lose access. You can copy and share the new link here.")
        }
        .alert("Couldn’t Update Page", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct WorkoutSharedPageEditor: View {
    let entry: WorkoutPageEntry
    @ObservedObject private var service: WorkoutPageService
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var errorMessage: String?

    init(entry: WorkoutPageEntry, service: WorkoutPageService) {
        self.entry = entry
        self.service = service
        _title = State(initialValue: entry.title)
        _description = State(initialValue: entry.description)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(4...12)
                } footer: {
                    Text("Updates appear at the existing link. Your local workout details stay unchanged.")
                }
            }
            .disabled(service.isWorking)
            .navigationTitle("Edit Page Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(service.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update Page") {
                        Task {
                            do {
                                try await service.updateDetails(entry, title: title, description: description)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(service.isWorking)
                }
            }
            .interactiveDismissDisabled(service.isWorking)
            .alert("Couldn’t Update Page", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: { Text(errorMessage ?? "Please try again.") }
        }
    }
}

private struct WorkoutPageRecoveryView: View {
    let isRestoring: Bool
    @ObservedObject var service: WorkoutPageService
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var errorMessage: String?
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(isRestoring
                         ? "Enter a saved recovery code to restore your shared pages. Pages already on this device will be kept."
                         : "Save this code somewhere private, such as your password manager. It restores access to your shared pages if you lose this device.")
                    if isRestoring {
                        SecureField("Recovery code", text: $code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("workoutPageRecoveryCode")
                    } else {
                        Text(code.isEmpty ? "Preparing recovery code…" : code)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .privacySensitive()
                        Button(didCopy ? "Recovery Code Copied" : "Copy Recovery Code") {
                            UIPasteboard.general.setItems([["public.utf8-plain-text": code]], options: [
                                .localOnly: true, .expirationDate: Date().addingTimeInterval(120)
                            ])
                            didCopy = true
                        }
                        .disabled(code.isEmpty)
                    }
                } footer: {
                    Text("Anyone with this code can manage and delete your pages. Losing both the code and your device prevents automatic recovery. Save a new code after restoring additional pages.")
                }
            }
            .navigationTitle(isRestoring ? "Restore Shared Pages" : "Recovery Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(service.isWorking)
                }
                if isRestoring {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Restore") {
                            Task {
                                do {
                                    try await service.restoreRecoveryCode(code)
                                    dismiss()
                                } catch { errorMessage = error.localizedDescription }
                            }
                        }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.isWorking)
                    }
                }
            }
            .task {
                guard !isRestoring else { return }
                do { code = try service.exportRecoveryCode() }
                catch { errorMessage = error.localizedDescription }
            }
            .interactiveDismissDisabled(service.isWorking)
            .alert("Recovery Unavailable", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: { Text(errorMessage ?? "Please try again.") }
        }
    }
}
