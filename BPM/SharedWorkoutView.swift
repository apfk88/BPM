import SwiftUI
import UIKit

/// A projection of the broadcaster's workout. All measurements and set boundaries
/// come from that device; this view never owns or advances a local workout model.
struct SharedWorkoutView: View {
    let snapshot: SharedWorkoutSnapshot
    @Binding var selectedPage: SharedWorkoutSnapshot.Page
    @ObservedObject var sharingService: SharingService
    let onLeave: () -> Void
    let onDevicePicker: () -> Void
    @State private var showPresetSheet = false
    @State private var showResetAlert = false
    @State private var showStartAlert = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                header
                let layout = isLandscape
                    ? AnyLayout(HStackLayout(spacing: 16))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 0) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            TabView(selection: $selectedPage) {
                                ForEach(SharedWorkoutSnapshot.Page.allCases, id: \.self) { page in
                                    workoutPage(page, isLandscape: isLandscape, age: sharingService.friendWorkoutPresentationAge)
                                        .tag(page)
                                }
                            }
                            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        pageDots(isLandscape: isLandscape)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isLandscape {
                        GeometryReader { controlsGeometry in
                            ScrollView {
                                controls(isLandscape: true, screenWidth: geometry.size.width)
                                    .frame(minHeight: controlsGeometry.size.height, alignment: .center)
                            }
                            .scrollIndicators(.hidden)
                        }
                        .frame(width: WorkoutControlMetrics.landscapeColumnWidth(for: geometry.size.width))
                        .padding(.trailing, 20)
                        .padding(.bottom, 8)
                    } else {
                        controls(isLandscape: false, screenWidth: geometry.size.width)
                            .padding(.bottom, geometry.safeAreaInsets.bottom)
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
        .sheet(isPresented: $showPresetSheet) {
            PresetConfigurationView(
                isPresented: $showPresetSheet,
                currentPresetId: snapshot.activePreset?.id,
                onLoadPreset: { send(.loadPreset, preset: $0) },
                onClearPreset: { send(.clearPreset) }
            )
        }
        .alert("Reset Workout", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { send(.reset) }
        } message: {
            Text("This clears the shared workout on the connected device.")
        }
        .alert("Start Workout", isPresented: $showStartAlert) {
            Button("Start from now") { send(.start) }
            Button("Include last \(historyDuration)") { send(.startIncludingHistory) }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var header: some View {
        HStack(spacing: TopBarLayout.buttonSpacing) {
            Button(action: onLeave) {
                circleIcon("house")
            }
            .accessibilityLabel("Home")
            .accessibilityIdentifier("sharedWorkoutHome")

            Spacer(minLength: 8)
            Button(action: onDevicePicker) {
                SharedConnectionIcon(symbol: "heart.fill", isShared: true, size: TopBarLayout.iconFontSize)
                    .foregroundStyle(.green)
                    .frame(width: TopBarLayout.iconSize, height: TopBarLayout.iconSize)
                    .bpmCircleSurface()
            }
            .accessibilityLabel("Device Picker")
            .accessibilityIdentifier("deviceConnectionMenu")
            .accessibilityValue("Viewing shared BPM")
            .accessibilityHint("Opens monitor and sharing controls")
        }
        .bpmGlassGroup()
        .padding(.horizontal, TopBarLayout.horizontalPadding)
        .padding(.top, TopBarLayout.topPadding)
    }

    private func circleIcon(_ symbol: String, color: Color = .white) -> some View {
        Image(systemName: symbol)
            .font(.system(size: TopBarLayout.iconFontSize))
            .foregroundStyle(color)
            .frame(width: TopBarLayout.iconSize, height: TopBarLayout.iconSize)
            .bpmCircleSurface()
    }

    @ViewBuilder
    private func workoutPage(_ page: SharedWorkoutSnapshot.Page, isLandscape: Bool, age: TimeInterval) -> some View {
        switch page {
        case .table:
            VStack(spacing: 0) {
                summary(isLandscape: isLandscape, age: age)
                    .padding(.top, isLandscape ? 8 : 18)
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 1)
                    .padding(.horizontal, isLandscape ? 12 : 20)
                    .padding(.top, isLandscape ? 8 : 16)
                setTable(age: age)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
        case .bpm:
            GeometryReader { geometry in
                heartRate(size: geometry.size)
            }
        case .stats:
            GeometryReader { geometry in
                stats(size: geometry.size, isLandscape: isLandscape, age: age)
            }
            .padding(.top, 8)
        case .chart:
            VStack(spacing: 0) {
                summary(isLandscape: isLandscape, age: age)
                    .padding(.top, isLandscape ? 8 : 18)
                SharedWorkoutCharts(snapshot: snapshot, isLandscape: isLandscape)
                    .equatable()
            }
        }
    }

    private func heartRate(size: CGSize) -> some View {
        let baseSize = size.height * 0.65
        let font = UIFont.systemFont(ofSize: baseSize, weight: .bold)
        let baseWidth = "888".size(withAttributes: [.font: font]).width
        let fittedSize = baseWidth > 0 ? min(baseSize, size.width * 0.9 / baseWidth * baseSize) : baseSize
        return Text(sharingService.friendHeartRate.map(String.init) ?? "---")
            .font(.system(size: fittedSize, weight: .bold, design: .monospaced))
            .foregroundStyle(sharingService.friendHeartRate == nil ? .gray : .white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Heart rate")
            .accessibilityValue(sharingService.friendHeartRate.map { "\($0) beats per minute" } ?? "No current reading")
    }

    private func summary(isLandscape: Bool, age: TimeInterval) -> some View {
        let total = snapshot.isEmpty ? "---" : formatTime(snapshot.totalTime(after: age))
        let set: String = {
            if snapshot.isEmpty { return "---" }
            if snapshot.isCompleted {
                return snapshot.avgWorkTime.map { formatTime($0) } ?? "---"
            }
            return formatTime(snapshot.setTime(after: age))
        }()
        let metrics: [(String, String, String)] = [
            ("Total Time", total, "sharedWorkoutTotalTime"),
            (snapshot.isCompleted ? (isLandscape ? "Avg Work" : "Avg Work Set") : "Set Time", set, "sharedWorkoutSetTime"),
            (snapshot.isCompleted && !isLandscape ? "Avg BPM" : "BPM",
             (snapshot.isCompleted && !isLandscape ? snapshot.avgBPM : sharingService.friendHeartRate).map(String.init) ?? "---",
             "sharedWorkoutSummaryBPM")
        ]
        let labelSize: CGFloat = isLandscape ? 12 : 14
        let valueSize: CGFloat = isLandscape || UIDevice.current.userInterfaceIdiom == .pad ? 28 : 32
        return GeometryReader { geometry in
            let columnWidth = max(1, (geometry.size.width - 32) / 3)
            let font = UIFont.monospacedSystemFont(ofSize: valueSize, weight: .bold)
            let widest = metrics.map { $0.1.size(withAttributes: [.font: font]).width }.max() ?? 1
            let fittedSize = min(valueSize, valueSize * max(1, columnWidth - 8) / max(1, widest))
            HStack(alignment: .top, spacing: 16) {
                ForEach(metrics.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text(metrics[index].0)
                            .font(.system(size: labelSize, weight: .medium))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(metrics[index].1)
                            .font(.system(size: fittedSize, weight: .bold, design: .monospaced))
                            .foregroundStyle(metrics[index].1 == "---" ? .gray : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(height: valueSize * 1.2)
                            .accessibilityIdentifier(metrics[index].2)
                    }
                    .frame(width: columnWidth)
                }
            }
        }
        .frame(height: labelSize * 1.2 + 6 + valueSize * 1.2)
        .padding(.horizontal, 20)
    }

    private func setTable(age: TimeInterval) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(snapshot.rows) { row in
                            setRow(row, age: age)
                                .id(row.id)
                        }
                    } header: {
                        tableCells(["Set", "Time", snapshot.primaryBPM == "max" ? "Max BPM" : "Avg BPM", "Total"],
                                   color: .gray, fontSize: 14, weight: .semibold)
                            .background(.black)
                    }
                }
            }
            .onAppear { scrollToActiveRow(proxy) }
            .onChange(of: snapshot.controlRevision) { _, _ in scrollToActiveRow(proxy) }
        }
    }

    private func scrollToActiveRow(_ proxy: ScrollViewProxy) {
        if let row = snapshot.rows.last(where: \.isActive) ?? snapshot.rows.last {
            proxy.scrollTo(row.id, anchor: .bottom)
        }
    }

    private func setRow(_ row: SharedWorkoutSnapshot.Row, age: TimeInterval) -> some View {
        let increment = row.isActive && snapshot.rowTimeAdvances ? min(5, max(0, age)) : 0
        let bpm = snapshot.primaryBPM == "max" ? row.maxBPM : row.avgBPM
        let isEmpty = row.kind == "empty"
        let values = [row.label,
                      isEmpty ? "---" : formatTime(row.duration + increment),
                      bpm.map(String.init) ?? "---",
                      isEmpty ? "---" : formatTime(row.totalTime + increment)]
        let color: Color = row.isActive ? .white : (row.kind == "placeholder" || isEmpty ? .gray.opacity(0.5) : .gray)
        return tableCells(values, color: color, fontSize: 18, weight: .medium)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sharedWorkoutRow_\(row.id)")
    }

    private func tableCells(_ values: [String], color: Color, fontSize: CGFloat, weight: Font.Weight) -> some View {
        HStack(spacing: 8) {
            ForEach(values.indices, id: \.self) { index in
                Text(values[index])
                    .font(.system(size: fontSize, weight: weight, design: .monospaced))
                    .foregroundStyle(values[index] == "---" ? .gray : color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func stats(size: CGSize, isLandscape: Bool, age: TimeInterval) -> some View {
        let horizontalPadding: CGFloat = isLandscape ? 14 : 8
        let verticalPadding: CGFloat = isLandscape ? 12 : 10
        let spacing: CGFloat = isLandscape ? 12 : 10
        let columnCount = isLandscape ? 4 : 2
        let rowCount = isLandscape ? 2 : 4
        let tileWidth = max(1, floor((size.width - horizontalPadding * 2 - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)))
        let tileHeight = max(1, floor((size.height - verticalPadding * 2 - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)))
        let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: columnCount)
        let zone = snapshot.zone.flatMap(HeartRateZone.init(rawValue:))
        let zoneAvailable = snapshot.isCompleted || sharingService.friendHeartRate != nil
        let set = snapshot.isCompleted ? snapshot.avgWorkTime : snapshot.setTime(after: age)
        let values: [(String, String, Color)] = [
            ("BPM", sharingService.friendHeartRate.map(String.init) ?? "---", .white),
            ("Total Time", snapshot.isEmpty ? "---" : formatTime(snapshot.totalTime(after: age)), .white),
            (snapshot.isCompleted ? "Work Sets" : "Set Number", snapshot.setNumber, .white),
            (snapshot.isCompleted ? "Avg Work" : "Set Time", snapshot.isEmpty ? "---" : set.map { formatTime($0) } ?? "---", .white),
            ("Avg BPM", snapshot.avgBPM.map(String.init) ?? "---", .white),
            ("Max BPM", snapshot.maxBPM.map(String.init) ?? "---", .white),
            (snapshot.isCompleted ? "Top Zone" : "Zone", zoneAvailable ? zone?.displayName ?? "---" : "---", zone?.color ?? .gray),
            ("Calories", snapshot.calories, .white)
        ]
        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(values.indices, id: \.self) { index in
                metricCell(values[index], width: tileWidth, height: tileHeight)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func metricCell(_ metric: (String, String, Color), width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: max(2, height * 0.04)) {
            Text(metric.0)
                .font(.system(size: max(8, height * 0.13), weight: .medium))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(metric.1)
                .font(.system(size: max(13, height * 0.38), weight: .bold, design: .monospaced))
                .foregroundStyle(metric.1 == "---" ? .gray : metric.2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, max(8, height * 0.08))
        .frame(width: width, height: height)
        .background(Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func pageDots(isLandscape: Bool) -> some View {
        HStack(spacing: isLandscape ? 8 : 9) {
            ForEach(SharedWorkoutSnapshot.Page.allCases, id: \.self) { page in
                Circle()
                    .fill(page == selectedPage ? Color.white : Color.gray.opacity(0.45))
                    .frame(width: isLandscape ? 6 : 7, height: isLandscape ? 6 : 7)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shared workout page")
        .accessibilityValue(selectedPage.rawValue)
        .accessibilityIdentifier("sharedWorkoutPage")
        .accessibilityAdjustableAction { direction in
            let pages = SharedWorkoutSnapshot.Page.allCases
            guard let index = pages.firstIndex(of: selectedPage) else { return }
            switch direction {
            case .increment where index < pages.count - 1:
                selectedPage = pages[index + 1]
            case .decrement where index > 0:
                selectedPage = pages[index - 1]
            default:
                break
            }
        }
    }

    private var status: (message: String, color: Color)? {
        if !sharingService.friendWorkoutIsFresh {
            return ("Waiting for workout updates…", .orange)
        }
        if let error = sharingService.workoutControlError {
            return (error, .red)
        }
        if sharingService.isWorkoutControlPending {
            return ("Sending change…", .secondary)
        }
        if snapshot.isCompleted { return ("Workout ended", .secondary) }
        if snapshot.state == .paused || snapshot.state == .cooldownPaused { return ("Paused", .secondary) }
        if snapshot.isEmpty { return ("Waiting for workout to start", .secondary) }
        return nil
    }

    private func controls(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        let metrics = WorkoutControlMetrics(isLandscape: isLandscape, screenWidth: screenWidth)
        return VStack(spacing: metrics.spacing) {
            Text(status?.message ?? " ")
                .font(.footnote)
                .foregroundStyle(status?.color ?? .secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 20)
                .accessibilityHidden(status == nil)
                .accessibilityIdentifier("sharedWorkoutStatus")

            let layout = isLandscape
                ? AnyLayout(VStackLayout(spacing: metrics.spacing))
                : AnyLayout(HStackLayout(spacing: metrics.spacing))
            VStack(spacing: metrics.spacing) {
                layout {
                    if snapshot.isCompleted {
                        controlButton(.reset, title: "Reset", metrics: metrics)
                        controlButton(.resume, title: "Resume", metrics: metrics)
                    } else if snapshot.state == .idle {
                        controlButton(.start, title: "Start", metrics: metrics)
                        Button { showPresetSheet = true } label: {
                            controlLabel("Load Preset", enabled: canSend(.loadPreset), metrics: metrics)
                        }
                        .disabled(!canSend(.loadPreset))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("sharedWorkoutLoadPreset")
                    } else {
                        let paused = snapshot.state == .paused || snapshot.state == .cooldownPaused
                        controlButton(paused ? .resume : .pause, title: paused ? "Resume" : "Pause", metrics: metrics)
                        controlButton(.end, title: "End", metrics: metrics)
                        if !snapshot.isPresetMode {
                            controlButton(.cool, title: "Cool", metrics: metrics)
                        }
                    }
                }
                if !snapshot.isCompleted {
                    if snapshot.isPresetMode {
                        WorkoutPresetControl(name: snapshot.activePreset?.name ?? "Custom Preset", metrics: metrics,
                                             canClear: canSend(.clearPreset), identifierPrefix: "sharedWorkout") {
                            send(.clearPreset)
                        }
                    } else {
                        layout {
                            controlButton(.work, title: "Work Set", metrics: metrics)
                            controlButton(.rest, title: "Rest Set", metrics: metrics)
                        }
                    }
                }
            }
            .bpmActionStyle()
            .bpmGlassGroup()
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, isLandscape ? 4 : 20)
        .padding(.bottom, metrics.bottomPadding)
        .background(Color.black.opacity(0.8))
    }

    private func canSend(_ action: SharedWorkoutAction) -> Bool {
        snapshot.permits(action) && sharingService.friendWorkoutIsFresh && !sharingService.isWorkoutControlPending
    }

    private func controlButton(_ action: SharedWorkoutAction, title: String, metrics: WorkoutControlMetrics) -> some View {
        let enabled = canSend(action)
        return Button {
            if action == .reset { showResetAlert = true }
            else if action == .start, canSend(.startIncludingHistory), (snapshot.recoverableHistorySeconds ?? 0) > 0 { showStartAlert = true }
            else { send(action) }
        } label: {
            controlLabel(title, enabled: enabled, metrics: metrics, showsPlus: action == .work || action == .rest)
        }
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(action == .work ? "sharedWorkSet" : action == .rest ? "sharedRestSet"
            : "sharedWorkout\(action.rawValue.prefix(1).uppercased())\(action.rawValue.dropFirst())")
    }

    private func controlLabel(_ title: String, enabled: Bool, metrics: WorkoutControlMetrics, showsPlus: Bool = false) -> some View {
        HStack(spacing: 4) {
            if showsPlus { Image(systemName: "plus") }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .font(.system(size: metrics.fontSize, weight: .semibold))
        .foregroundStyle(enabled ? .white : .gray.opacity(0.5))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
        .padding(.vertical, metrics.isLandscape ? 0 : 6)
        .frame(minHeight: metrics.minimumHeight)
    }

    private func send(_ action: SharedWorkoutAction, preset: TimerPreset? = nil) {
        Task { await sharingService.requestWorkoutControl(action, preset: preset) }
    }

    private var historyDuration: String {
        let seconds = Int(max(0, min(3600, snapshot.recoverableHistorySeconds ?? 0)))
        if seconds >= 60 { return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let time = time.isFinite ? max(0, time) : 0
        let seconds = Int(time)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Avoid rebuilding chart data on each presentation timer redraw.
private struct SharedWorkoutCharts: View, Equatable {
    let snapshot: SharedWorkoutSnapshot
    let isLandscape: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isLandscape == rhs.isLandscape && lhs.snapshot.chart == rhs.snapshot.chart &&
        lhs.snapshot.segments == rhs.snapshot.segments && lhs.snapshot.zones == rhs.snapshot.zones &&
        lhs.snapshot.chartMaxTime == rhs.snapshot.chartMaxTime
    }

    var body: some View {
        GeometryReader { geometry in
            let panelHeight = max(0, geometry.size.height - 12) / (isLandscape ? 1 : 2)
            let layout = isLandscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                HeartRateTimelineChart(
                    dataPoints: snapshot.chart.map {
                        HeartRateChartDataPoint(time: $0.time, bpm: $0.bpm, segment: $0.segment, validUntil: $0.validUntil)
                    },
                    segments: snapshot.segments.map {
                        HeartRateChartSegment(startTime: $0.startTime, endTime: $0.endTime,
                                              type: $0.kind == "cooldown" ? .cooldown : ($0.kind == "rest" ? .rest : .work))
                    },
                    maxTime: snapshot.chartMaxTime
                )
                .frame(maxWidth: .infinity, maxHeight: panelHeight)
                TimeInZoneView(
                    zoneData: snapshot.zones.compactMap { duration in
                        HeartRateZone(rawValue: duration.zone).map { ZoneTimeData(zone: $0, duration: duration.duration) }
                    },
                    isLandscape: isLandscape
                )
                .frame(maxWidth: .infinity, maxHeight: panelHeight, alignment: .top)
            }
            .padding(.horizontal, isLandscape ? 12 : 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }
}
