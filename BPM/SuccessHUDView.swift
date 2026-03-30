import SwiftUI

struct SuccessHUDView: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.green)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}
