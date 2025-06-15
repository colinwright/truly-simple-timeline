import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var isPurchasing = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Upgrade to Pro")
                .font(.largeTitle.bold())
                .padding(.top)

            Text("Unlock unlimited timelines that sync across all your devices.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "list.bullet.rectangle.portrait", text: "Create Unlimited Timelines")
                FeatureRow(icon: "sparkles", text: "Support Future Development")
            }
            .padding(.vertical)
            
            if isPurchasing {
                ProgressView()
                    .padding()
            } else {
                purchaseButton
            }
            
            Button("Not Now") {
                dismiss()
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.bottom)
        }
        .padding(30)
        .frame(minWidth: 320, maxWidth: 480)
        .task {
            // Load product info when the paywall appears.
            if purchaseManager.products.isEmpty {
                do {
                    try await purchaseManager.loadProducts()
                } catch {
                    print("Could not load products: \(error)")
                }
            }
        }
    }
    
    @ViewBuilder
    private var purchaseButton: some View {
        if let proProduct = purchaseManager.products.first {
            Button {
                Task {
                    isPurchasing = true
                    do {
                        try await purchaseManager.purchase(proProduct)
                        // If purchase is successful, hasProAccess will update,
                        // and we can dismiss the sheet on the next view update.
                    } catch {
                        print("Purchase failed: \(error)")
                    }
                    isPurchasing = false
                }
            } label: {
                Text("Unlock for \(proProduct.displayPrice)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            // Shows a disabled button or loading state if products haven't loaded.
            Text("Loading...")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.gray.opacity(0.2))
                .foregroundColor(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 40)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
