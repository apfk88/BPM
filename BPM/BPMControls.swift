import SwiftUI

/// Shared sizing keeps local and remote workout controls aligned.
struct WorkoutControlMetrics {
    let isLandscape: Bool
    let screenWidth: CGFloat

    private var scale: CGFloat { min(1, screenWidth / 375) }
    var spacing: CGFloat { isLandscape ? 8 : max(12, 16 * scale) }
    var horizontalPadding: CGFloat { isLandscape ? 0 : max(20, 24 * scale) }
    var fontSize: CGFloat { isLandscape ? 16 : max(14, 18 * scale) }
    var minimumHeight: CGFloat { isLandscape ? 30 : 52 }
    var bottomPadding: CGFloat { isLandscape ? 4 : max(12, 16 * scale) }

    static func landscapeColumnWidth(for width: CGFloat) -> CGFloat {
        min(200, max(150, width * 0.23))
    }
}

struct WorkoutPresetControl: View {
    let name: String
    let metrics: WorkoutControlMetrics
    let canClear: Bool
    let identifierPrefix: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Preset: \(name.isEmpty ? "Custom Preset" : name)")
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canClear)
            .accessibilityLabel("Clear preset")
            .accessibilityValue(name.isEmpty ? "Custom Preset" : name)
            .accessibilityIdentifier("\(identifierPrefix)ClearPreset")
        }
        .font(.system(size: metrics.fontSize, weight: .semibold))
        .foregroundStyle(canClear ? .white : .gray.opacity(0.55))
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: metrics.minimumHeight + 14)
        .modifier(BPMPresetSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifierPrefix)PresetName")
    }
}

private struct BPMPresetSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Keep the system's material, contrast preferences, and interaction feedback.
/// Measurement values and charts remain on the content layer.
struct BPMGlassContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8, content: content)
        } else {
            content()
        }
    }
}

private struct BPMActionStyle: ViewModifier {
    var prominent: Bool

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *) {
                if prominent {
                    content.buttonStyle(.glassProminent)
                } else {
                    content.buttonStyle(.glass)
                }
            } else if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .controlSize(.regular)
    }
}

private struct BPMCircleSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

private struct BPMGlassGroup: ViewModifier {
    func body(content: Content) -> some View {
        BPMGlassContainer { content }
    }
}

extension View {
    func bpmGlassGroup() -> some View {
        modifier(BPMGlassGroup())
    }

    func bpmActionStyle(prominent: Bool = false) -> some View {
        modifier(BPMActionStyle(prominent: prominent))
    }

    func bpmCircleSurface() -> some View {
        modifier(BPMCircleSurface())
    }
}
