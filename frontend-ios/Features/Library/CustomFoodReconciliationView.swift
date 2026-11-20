// Explicit reconciliation UI for a custom-food create whose response was lost.

import SwiftUI

public struct CustomFoodReconciliationView: View {
    public let attempt: CustomFoodCreateAttempt
    public let candidates: [CustomFood]
    public let message: String?
    public let isRefreshing: Bool
    public let onRefresh: () -> Void
    public let onUse: (CustomFood) -> Void
    public let onDiscard: () -> Void

    @State private var confirmingDiscard = false

    public init(
        attempt: CustomFoodCreateAttempt,
        candidates: [CustomFood],
        message: String?,
        isRefreshing: Bool,
        onRefresh: @escaping () -> Void,
        onUse: @escaping (CustomFood) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.attempt = attempt
        self.candidates = candidates
        self.message = message
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.onUse = onUse
        self.onDiscard = onDiscard
    }

    public var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(String(localized: "library.reconcile.title"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                }
                .font(.headline)
                .foregroundStyle(.orange)

                Text(
                    String(
                        format: String(localized: "library.reconcile.message"),
                        attempt.displayName
                    )
                )
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library.reconcile.message")

                if let intent = attempt.logIntent {
                    Text(LibraryLogIntentFormat.summary(intent))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library.reconcile.owedLog")
                }

                Button {
                    onRefresh()
                } label: {
                    HStack {
                        if isRefreshing {
                            ProgressView()
                        }
                        Text(
                            isRefreshing
                                ? String(localized: "library.reconcile.refreshing")
                                : String(localized: "library.reconcile.refresh")
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRefreshing)
                .accessibilityIdentifier("library.reconcile.refresh")
            }
        }

        if !candidates.isEmpty {
            Section {
                ForEach(candidates) { food in
                    Button {
                        onUse(food)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(food.name)
                                if let brand = food.brand, !brand.isEmpty {
                                    Text(brand)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(String(localized: "library.reconcile.use"))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .disabled(isRefreshing)
                    .accessibilityIdentifier("library.reconcile.candidate.\(food.id)")
                }
            } header: {
                Text(String(localized: "library.reconcile.candidates"))
            }
        }

        if let message, candidates.isEmpty {
            Section {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library.reconcile.empty")
            }
        }

        Section {
            Button(role: .destructive) {
                confirmingDiscard = true
            } label: {
                Text(String(localized: "library.reconcile.discard"))
                    .frame(maxWidth: .infinity)
            }
            .disabled(isRefreshing)
            .accessibilityIdentifier("library.reconcile.discard")
        } footer: {
            Text(String(localized: "library.reconcile.discard.help"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert(
            String(localized: "library.reconcile.discard.title"),
            isPresented: $confirmingDiscard
        ) {
            Button(String(localized: "library.reconcile.discard.action"), role: .destructive) {
                onDiscard()
            }
            .accessibilityIdentifier("library.reconcile.discard.confirm")
            Button(String(localized: "diary.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "library.reconcile.discard.message"))
        }
    }
}
