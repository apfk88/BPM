import SwiftUI

struct SavedWorkoutRequest {
    let record: WorkoutRecord
    let activityOption: HealthKitActivityOption
}

/// A save receipt over Home, using the same chart card as workout history.
struct WorkoutSavedOverlay: View {
    let record: WorkoutRecord
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragOffset = CGSize.zero
    @State private var isRevealed = false

    var body: some View {
        GeometryReader { geometry in
            // Leave space around the receipt in both portrait and landscape.
            let contentWidth = min(380, max(1, geometry.size.width - 48))
            let cardWidth = min(contentWidth,
                                max(1, (geometry.size.height - 180) * 360 / 238))
            ZStack {
                Button(action: onDismiss) {
                    Color.black.opacity(isRevealed ? 0.62 : 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ignoresSafeArea()
                .accessibilityLabel("Dismiss workout saved")
                .accessibilityIdentifier("dismissWorkoutSavedBackdrop")
                .animation(.easeOut(duration: 0.4), value: isRevealed)

                ViewThatFits(in: .vertical) {
                    receipt(contentWidth: contentWidth, cardWidth: cardWidth)
                    ScrollView {
                        receipt(contentWidth: contentWidth, cardWidth: cardWidth, allowsSwipeDismissal: false)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onDismiss)
            .onAppear { isRevealed = true }
        }
    }

    private func receipt(contentWidth: CGFloat, cardWidth: CGFloat,
                         allowsSwipeDismissal: Bool = true) -> some View {
        VStack(spacing: 24) {
            successHeader
                .opacity(isRevealed ? 1 : 0)
                .offset(y: isRevealed || reduceMotion ? 0 : 8)
                .animation(.easeOut(duration: 0.5).delay(0.08), value: isRevealed)

            openWorkoutButton(cardWidth: cardWidth)
        }
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .offset(reduceMotion ? .zero : dragOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .updating($dragOffset) { value, offset, _ in
                    if allowsSwipeDismissal { offset = value.translation }
                }
                .onEnded { value in
                    guard allowsSwipeDismissal else { return }
                    let distance = max(abs(value.translation.width), abs(value.translation.height))
                    let predicted = max(abs(value.predictedEndTranslation.width),
                                        abs(value.predictedEndTranslation.height))
                    if distance > 70 || predicted > 140 { onDismiss() }
                }
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: dragOffset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workoutSavedReceipt")
    }

    private var successHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.green)
                .shadow(color: .green.opacity(0.3), radius: 12)
                .frame(width: 36, height: 44)
                .accessibilityHidden(true)
            Text("Workout saved")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss workout saved")
            .accessibilityIdentifier("dismissWorkoutSaved")
        }
    }

    private func openWorkoutButton(cardWidth: CGFloat) -> some View {
        let snapshot = WorkoutShareSnapshot(record: record)
        return Button(action: onOpen) {
            VStack(spacing: 20) {
                WorkoutShareCardPreview(snapshot: snapshot, style: .chart, compact: true)
                    .frame(width: cardWidth)
                    .shadow(color: .black.opacity(0.4), radius: 28, y: 16)
                    .opacity(isRevealed ? 1 : 0)
                    .scaleEffect(isRevealed || reduceMotion ? 1 : 0.96)
                    .offset(y: isRevealed || reduceMotion ? 0 : 18)
                    .animation(.easeOut(duration: 0.7).delay(0.16), value: isRevealed)
                HStack(spacing: 7) {
                    Text("View workout")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
                .frame(minHeight: 44)
                .opacity(isRevealed ? 1 : 0)
                .animation(.easeOut(duration: 0.45).delay(0.4), value: isRevealed)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View saved workout, \(snapshot.title)")
        .accessibilityHint("Opens workout details")
        .accessibilityIdentifier("openSavedWorkout")
    }
}

#if DEBUG
#Preview("Workout saved") {
    Color.black
        .overlay {
            WorkoutSavedOverlay(record: WorkoutSharePreviewFixture.record, onOpen: {}, onDismiss: {})
        }
        .preferredColorScheme(.dark)
}
#endif
