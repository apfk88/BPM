import SwiftUI
import UIKit
import LinkPresentation
import UniformTypeIdentifiers

enum WorkoutShareStyle: String, CaseIterable, Identifiable {
    case chart = "Chart"
    case stats = "Stats"
    var id: String { rawValue }
}

private enum WorkoutCardPalette {
    static let background = Color(red: 0.065, green: 0.075, blue: 0.09)
    static let coral = Color(red: 1, green: 0.39, blue: 0.34)
    static let muted = Color(red: 0.63, green: 0.66, blue: 0.70)
}

/// One design shared by history, the live preview, and the exported image.
struct WorkoutShareCard: View {
    let snapshot: WorkoutShareSnapshot
    let style: WorkoutShareStyle
    var compact = false

    private var accent: Color { WorkoutCardPalette.coral }
    private var muted: Color { WorkoutCardPalette.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 22) {
            header
            if style == .chart {
                if !compact { title }
                WorkoutSharePlot(snapshot: snapshot, showsAxes: !compact)
                    .frame(maxHeight: .infinity)
                metrics
            } else {
                if !compact { title }
                statsTable
            }
            if !compact { footer }
        }
        .padding(compact ? 22 : 28)
        .frame(width: 360, height: compact ? 238 : 450)
        .background {
            ZStack(alignment: .topTrailing) {
                WorkoutCardPalette.background
                RadialGradient(colors: [accent.opacity(0.13), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 320)
                // A quiet frame gives the artwork definition against both dark and light surfaces.
                RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.09), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon = ShareSheet.appIconImage() {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: compact ? 7 : 8)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
                    }
                    .accessibilityHidden(true)
            }
            if compact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    Text(snapshot.record.startAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(muted)
                }
            } else {
                Text("BPM").tracking(2)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            Spacer(minLength: 8)
            if !compact {
                Text("WORKOUT")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(muted)
                    .padding(.top, 3)
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(snapshot.title)
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.7)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(snapshot.record.startAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 12) {
            metric(WorkoutShareSnapshot.time(snapshot.duration), label: "TOTAL TIME")
            metric(snapshot.average.map(String.init) ?? "—", label: "AVG BPM")
            metric(snapshot.maximum.map(String.init) ?? "—", label: "MAX BPM")
        }
        .padding(.top, compact ? 0 : 17)
        .overlay(alignment: .top) {
            if !compact { Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5) }
        }
    }

    private var statsTable: some View {
        VStack(spacing: 0) {
            statRow("Avg BPM", value: snapshot.average.map(String.init) ?? "—")
            tableRule
            statRow("Max BPM", value: snapshot.maximum.map(String.init) ?? "—")
            tableRule
            statRow("Total Time", value: WorkoutShareSnapshot.time(snapshot.duration))
            tableRule
            statRow("Top Zone", value: snapshot.topZone.map { "Zone \($0.rawValue)" } ?? "—")
        }
        .frame(maxHeight: .infinity)
    }

    private var tableRule: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: compact ? 11 : 14, weight: .medium))
                .foregroundStyle(muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: compact ? 22 : 30, weight: .medium, design: .rounded))
                .tracking(-0.6)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxHeight: .infinity)
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Text(value)
                .font(.system(size: compact ? 23 : 27, weight: .medium, design: .rounded))
                .tracking(-0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var footer: some View {
        Text("bpmtracker.app")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(muted)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var accessibilitySummary: String {
        "\(snapshot.title), Workout, total time \(WorkoutShareSnapshot.time(snapshot.duration)), average \(snapshot.average.map(String.init) ?? "unavailable") BPM, maximum \(snapshot.maximum.map(String.init) ?? "unavailable") BPM, top zone \(snapshot.topZone.map { String($0.rawValue) } ?? "unavailable")"
    }
}

struct WorkoutShareCardPreview: View {
    let snapshot: WorkoutShareSnapshot
    let style: WorkoutShareStyle
    var compact = false

    var body: some View {
        GeometryReader { geometry in
            WorkoutShareCard(snapshot: snapshot, style: style, compact: compact)
                .scaleEffect(geometry.size.width / 360, anchor: .topLeading)
        }
        .aspectRatio(360 / (compact ? 238 : 450), contentMode: .fit)
    }
}

/// Draw saved measurements with straight connections only within a continuous sensor stream.
struct WorkoutSharePlot: View {
    let snapshot: WorkoutShareSnapshot
    var showsAxes = true

    var body: some View {
        let points = snapshot.plotPoints
        let axisStep = 50.0
        let maximum = Double(points.map(\.bpm).max() ?? 160)
        let low = min(150, max(0, floor((Double(points.map(\.bpm).min() ?? 60) - 10) / axisStep) * axisStep))
        // Avoid an empty 200–250 band, while still showing any measurements above 205.
        let high = maximum > 205 ? maximum + 5
            : min(205, max(low + axisStep, ceil((maximum + 10) / axisStep) * axisStep))
        let ticks = Array(stride(from: low, through: min(200, high), by: axisStep))
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if showsAxes {
                    GeometryReader { geometry in
                        ForEach(ticks, id: \.self) { tick in
                            Text("\(Int(tick))")
                                .frame(width: 26, alignment: .trailing)
                                .position(x: 13, y: (1 - (tick - low) / (high - low)) * geometry.size.height)
                        }
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(WorkoutCardPalette.muted)
                    .frame(width: 26, alignment: .trailing)
                }
                Canvas { context, size in
                    let width = max(1, size.width)
                    let height = max(1, size.height)
                    func position(_ point: WorkoutSharePoint) -> CGPoint {
                        CGPoint(x: (point.time - snapshot.range.start) / max(1, snapshot.duration) * width,
                                y: (1 - (Double(point.bpm) - low) / (high - low)) * height)
                    }
                    for tick in ticks {
                        let y = (1 - (tick - low) / (high - low)) * height
                        var grid = Path()
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: width, y: y))
                        context.stroke(grid, with: .color(.white.opacity(0.1)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    }
                    let groups = Dictionary(grouping: points, by: \.segment)
                    for key in groups.keys.sorted() {
                        guard let group = groups[key], let first = group.first, let last = group.last else { continue }
                        var line = Path()
                        line.move(to: position(first))
                        for point in group.dropFirst() { line.addLine(to: position(point)) }
                        if group.count > 1 {
                            var fill = line
                            fill.addLine(to: CGPoint(x: position(last).x, y: height))
                            fill.addLine(to: CGPoint(x: position(first).x, y: height))
                            fill.closeSubpath()
                            context.fill(fill, with: .linearGradient(
                                Gradient(colors: [WorkoutCardPalette.coral.opacity(0.35), WorkoutCardPalette.coral.opacity(0.01)]),
                                startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
                            context.stroke(line, with: .color(WorkoutCardPalette.coral),
                                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        } else {
                            let point = position(first)
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)),
                                         with: .color(WorkoutCardPalette.coral))
                        }
                    }
                }
                .overlay {
                    if points.isEmpty {
                        Text("No heart-rate samples")
                            .font(.system(size: 12))
                            .foregroundStyle(WorkoutCardPalette.muted)
                    }
                }
            }
            if showsAxes {
                HStack {
                    Text(WorkoutShareSnapshot.time(snapshot.range.start))
                    Spacer()
                    Text(WorkoutShareSnapshot.time((snapshot.range.start + snapshot.range.end) / 2))
                    Spacer()
                    Text(WorkoutShareSnapshot.time(snapshot.range.end))
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(WorkoutCardPalette.muted)
                .padding(.leading, 34)
            }
        }
        .accessibilityHidden(true)
    }
}

enum WorkoutShareCardRenderer {
    @MainActor static func image(snapshot: WorkoutShareSnapshot, style: WorkoutShareStyle) -> UIImage? {
        let renderer = ImageRenderer(content: WorkoutShareCard(snapshot: snapshot, style: style))
        renderer.scale = 3 // 1080 × 1350, matching the on-screen composition.
        return renderer.uiImage
    }
}

/// Share a concrete PNG so extensions can read the pixels outside the app process.
final class WorkoutShareImageItem: NSObject, UIActivityItemSource {
    let fileURL: URL
    private let title: String

    init(image: UIImage, title: String) throws {
        self.title = title
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("BPMCardExports", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-86_400)
        for file in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                try? manager.removeItem(at: file)
            }
        }
        fileURL = root.appendingPathComponent("BPM-workout-\(UUID().uuidString).png")
        guard let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: fileURL, options: .atomic)
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { fileURL }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if activityType == .copyToPasteboard {
            return UIImage(contentsOfFile: fileURL.path)
        }
        return fileURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { UTType.png.identifier }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(contentsOf: fileURL)
        metadata.iconProvider = NSItemProvider(contentsOf: fileURL)
        return metadata
    }
}
