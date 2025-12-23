//
//  SharePaywallView.swift
//  BPM
//
//  Paywall for BPM Sharing subscription
//

import SwiftUI
import StoreKit

struct SharePaywallView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false
    @State private var showError = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 60))
                        .foregroundColor(.green)

                    Text("BPM Sharing")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Live stream your heart rate to another BPM user")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 40)

                Spacer()

                // Features
                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(icon: "heart.fill", text: "Share your heart rate in real-time")
                    FeatureRow(icon: "person.2.fill", text: "Let friends, coaches, or family monitor you")
                    FeatureRow(icon: "number", text: "Simple 6-digit sharing codes")
                    FeatureRow(icon: "eye", text: "Viewing others' heart rates is always free")
                }
                .padding(.horizontal, 32)

                Spacer()

                // Price and Subscribe Button
                VStack(spacing: 16) {
                    if let product = subscriptionManager.sharingProduct {
                        Text("\(product.displayPrice)/month")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Button {
                            Task {
                                await purchase()
                            }
                        } label: {
                            if isPurchasing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text("Subscribe")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .disabled(isPurchasing)

                        Button("Restore Purchases") {
                            Task {
                                await subscriptionManager.restorePurchases()
                                if subscriptionManager.isSubscribed {
                                    dismiss()
                                }
                            }
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    } else if subscriptionManager.isLoading {
                        ProgressView()
                    } else {
                        Text("Unable to load subscription")
                            .foregroundColor(.secondary)

                        Button("Retry") {
                            Task {
                                await subscriptionManager.loadProducts()
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .alert("Purchase Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(subscriptionManager.errorMessage ?? "An error occurred")
            }
        }
    }

    private func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let success = try await subscriptionManager.purchase()
            if success {
                dismiss()
            }
        } catch {
            showError = true
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.green)
                .frame(width: 24)

            Text(text)
                .font(.body)
        }
    }
}

#Preview {
    SharePaywallView()
}
