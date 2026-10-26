//
//  ShareSheet.swift
//  BPM
//

import SwiftUI
import UIKit
import LinkPresentation

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
    let subject: String
}

/// Share a file URL so receiving apps import an attachment instead of pasting the JSON.
/// Unique directories prevent one export from overwriting an attachment still being read.
enum JSONLogFile {
    static func create(json: String, prefix: String, date: Date = Date()) throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("BPMLogExports", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        // Keep recent attachments alive for share extensions that read them asynchronously.
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let previous = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for directory in previous {
            if let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                try? manager.removeItem(at: directory)
            }
        }

        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appendingPathComponent("\(prefix)-\(formatter.string(from: date)).json")
        do {
            try Data(json.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let subject: String?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let icon = Self.appIconImage()
        let title = subject ?? "BPM"
        let preparedItems: [Any] = items.map { item in
            if let text = item as? String {
                return ShareItem(text: text, subject: subject, title: title, icon: icon)
            }
            return item
        }

        let controller = UIActivityViewController(activityItems: preparedItems, applicationActivities: nil)
        if let subject = subject {
            controller.setValue(subject, forKey: "subject")
        }
        controller.completionWithItemsHandler = { _, _, _, _ in
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }

    static func appIconImage() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let iconFiles = primary["CFBundleIconFiles"] as? [String],
              let iconName = iconFiles.last else {
            return nil
        }
        return UIImage(named: iconName)
    }
}

private final class ShareItem: NSObject, UIActivityItemSource {
    private let text: String
    private let subject: String?
    private let title: String
    private let icon: UIImage?

    init(text: String, subject: String?, title: String, icon: UIImage?) {
        self.text = text
        self.subject = subject
        self.title = title
        self.icon = icon
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        text
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        subject ?? title
    }

    @available(iOS 13.0, *)
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        if let icon = icon {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        return metadata
    }
}
