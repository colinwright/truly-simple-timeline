import StoreKit
import SwiftUI

@Observable
class PurchaseManager {
    // Replace with your actual Product ID from App Store Connect.
    let productID = "com.colinismyname.TrulySimpleTimeline.pro"
    
    var products: [Product] = []
    var purchasedProductIDs = Set<String>()
    
    var hasProAccess: Bool {
        !self.purchasedProductIDs.isEmpty
    }

    // Loads product information from the App Store.
    func loadProducts() async throws {
        // This requests the product details for your IAP.
        self.products = try await Product.products(for: [productID])
    }
    
    // Initiates a purchase flow for a given product.
    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            // The purchase was successful, now verify the transaction.
            await self.handle(verification: verification)
        case .pending:
            // The purchase is pending, e.g., requires parental approval.
            // The UI should show a waiting state.
            break
        case .userCancelled:
            // The user canceled the purchase. Do nothing.
            break
        @unknown default:
            break
        }
    }
    
    // Checks for existing purchases when the app starts.
    @MainActor
    func updatePurchasedStatus() async {
        // Iterate through all of the user's active transactions.
        // We specify StoreKit.Transaction to avoid ambiguity with SwiftUI.Transaction.
        for await result in StoreKit.Transaction.currentEntitlements {
            // The 'handle' function is not async, so 'await' is not needed.
            // It's already running on the main actor because of the function's attribute.
            self.handle(verification: result)
        }
    }
    
    // Verifies a transaction and updates the purchased status.
    @MainActor
    private func handle(verification: VerificationResult<StoreKit.Transaction>) {
        switch verification {
        case .verified(let transaction):
            // Transaction is verified by Apple.
            if transaction.revocationDate == nil {
                // This is a valid, active transaction. Unlock the content.
                self.purchasedProductIDs.insert(transaction.productID)
            } else {
                // This transaction was revoked (e.g., a refund).
                self.purchasedProductIDs.remove(transaction.productID)
            }
            // Always finish a verified transaction.
            Task { await transaction.finish() }
            
        case .unverified:
            // Do not unlock content for unverified transactions.
            break
        }
    }
}
