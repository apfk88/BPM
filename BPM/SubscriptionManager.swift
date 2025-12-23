//
//  SubscriptionManager.swift
//  BPM
//
//  Manages StoreKit 2 subscriptions for sharing feature
//

import Foundation
import StoreKit

/// Manages StoreKit 2 subscriptions for the BPM app
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // MARK: - Product Identifiers
    private let sharingProductID = "com.bpmapp.client.sharing.monthly"

    // MARK: - Published Properties
    @Published private(set) var sharingProduct: Product?
    @Published private(set) var isSubscribed: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Private Properties
    private var updateListenerTask: Task<Void, Error>?
    private let entitlementCacheKey = "BPM_SharingEntitlement"
    private let entitlementCacheTimeKey = "BPM_SharingEntitlementTime"
    private let cacheValidityDuration: TimeInterval = 3600 // 1 hour

    // MARK: - Initialization
    private init() {
        // Start listening for transaction updates
        updateListenerTask = listenForTransactions()

        // Load cached entitlement for offline support
        loadCachedEntitlement()

        // Fetch products and check entitlement
        Task {
            await loadProducts()
            await checkEntitlement()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Product Loading
    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let products = try await Product.products(for: [sharingProductID])
            if let product = products.first {
                sharingProduct = product
            } else {
                print("⚠️ Subscription product not found: \(sharingProductID)")
            }
        } catch {
            print("❌ Failed to load products: \(error.localizedDescription)")
            errorMessage = "Failed to load subscription"
        }
    }

    // MARK: - Purchase
    func purchase() async throws -> Bool {
        guard let product = sharingProduct else {
            throw SubscriptionError.productNotFound
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                // Verify the transaction
                let transaction = try checkVerified(verification)

                // Update entitlement
                await checkEntitlement()

                // Finish the transaction
                await transaction.finish()

                return true

            case .pending:
                // Transaction is pending (e.g., Ask to Buy)
                return false

            case .userCancelled:
                return false

            @unknown default:
                return false
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: - Entitlement Checking
    func checkEntitlement() async {
        // Check for active subscription
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productID == sharingProductID {
                    // Check if subscription is still valid
                    if transaction.revocationDate == nil,
                       transaction.expirationDate ?? Date.distantFuture > Date() {
                        isSubscribed = true
                        cacheEntitlement(true)
                        return
                    }
                }
            }
        }

        isSubscribed = false
        cacheEntitlement(false)
    }

    /// Check if user can share (has active subscription)
    /// This is the main method to call before allowing sharing
    func canShare() async -> Bool {
        await checkEntitlement()
        return isSubscribed
    }

    // MARK: - Restore Purchases
    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await checkEntitlement()
        } catch {
            errorMessage = "Failed to restore purchases: \(error.localizedDescription)"
        }
    }

    // MARK: - Transaction Listener
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                do {
                    let transaction = try await MainActor.run { [self] in
                        try self.checkVerified(result)
                    }

                    // Update entitlement status
                    await self.checkEntitlement()

                    // Always finish a transaction
                    await transaction.finish()
                } catch {
                    print("❌ Transaction verification failed: \(error)")
                }
            }
        }
    }

    // MARK: - Verification Helper
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw SubscriptionError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Caching for Offline Support
    private func cacheEntitlement(_ entitled: Bool) {
        UserDefaults.standard.set(entitled, forKey: entitlementCacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: entitlementCacheTimeKey)
    }

    private func loadCachedEntitlement() {
        let cachedTime = UserDefaults.standard.double(forKey: entitlementCacheTimeKey)
        let now = Date().timeIntervalSince1970

        // Only use cache if it's within validity period
        if now - cachedTime < cacheValidityDuration {
            isSubscribed = UserDefaults.standard.bool(forKey: entitlementCacheKey)
        }
    }
}

// MARK: - Errors
enum SubscriptionError: LocalizedError {
    case productNotFound
    case verificationFailed
    case purchaseFailed

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "Subscription product not available"
        case .verificationFailed:
            return "Transaction verification failed"
        case .purchaseFailed:
            return "Purchase could not be completed"
        }
    }
}
