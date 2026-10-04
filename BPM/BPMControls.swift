import SwiftUI

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
