//
//  SharePaywallView.swift
//  BPM
//
//  Legacy screen retained for compatibility. Sharing is now free.
//

import SwiftUI

struct SharePaywallView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.green)

                Text("Sharing Is Free")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Live heart-rate sharing is now available to everyone at no cost.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .navigationTitle("BPM Sharing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    SharePaywallView()
}

