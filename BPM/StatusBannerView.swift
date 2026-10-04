import SwiftUI

struct StatusBannerView: View {
    enum Style {
        case success
        case warning

        var iconName: String {
            switch self {
            case .success:
                return "checkmark.circle.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .success:
                return .green
            case .warning:
                return .orange
            }
        }

        var backgroundColor: Color {
            switch self {
            case .success:
                return Color.green.opacity(0.14)
            case .warning:
                return Color.orange.opacity(0.12)
            }
        }

        var borderColor: Color {
            switch self {
            case .success:
                return Color.green.opacity(0.3)
            case .warning:
                return Color.orange.opacity(0.28)
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let style: Style
    let message: String
    var actionTitle: String? = nil
    var isActionDisabled = false
    var action: (() -> Void)? = nil

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Image(systemName: style.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(style.iconColor)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isActionDisabled ? .gray : .white)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(isActionDisabled ? Color.white.opacity(0.08) : Color.white.opacity(0.14))
                        .cornerRadius(8)
                }
                .disabled(isActionDisabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(style.backgroundColor)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
