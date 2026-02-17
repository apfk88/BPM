//
//  SubscriptionManager.swift
//  BPM
//
//  Sharing is fully free. This shim remains to keep older call sites and previews build-safe.
//

import Foundation

@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published private(set) var isSubscribed: Bool = true
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    private init() {}

    func loadProducts() async {}

    func purchase() async throws -> Bool { true }

    func checkEntitlement() async {
        isSubscribed = true
    }

    func canShare() async -> Bool { true }

    func restorePurchases() async {}
}

