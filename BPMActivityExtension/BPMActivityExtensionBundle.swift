import WidgetKit
import SwiftUI

@main
struct BPMActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOSApplicationExtension 16.1, *) {
            HeartRateLiveActivity()
        }
    }
}
