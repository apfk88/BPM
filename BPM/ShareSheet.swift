//
//  ShareSheet.swift
//  BPM
//

import SwiftUI
import UIKit
import LinkPresentation

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let subject: String?

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
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }

    private static func appIconImage() -> UIImage? {
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
