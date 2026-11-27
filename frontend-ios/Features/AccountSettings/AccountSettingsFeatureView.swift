
import ComposableArchitecture
import SwiftUI

public struct AccountSettingsFeatureView: View {
    @Bindable private var store: StoreOf<AccountSettingsFeature>
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isNameFocused: Bool
    private let observedAccountID: String
    private let onClose: () -> Void

    public init(store: StoreOf<AccountSettingsFeature>, onClose: @escaping () -> Void) {
        self.store = store
        self.observedAccountID = store.accountID
        self.onClose = onClose
    }

    private var backPlacement: ToolbarItemPlacement {
#if os(iOS)
        .navigationBarLeading
#else
        .navigation
#endif
    }

    public var body: some View {
        Group {
            list
                .navigationTitle(String(localized: "apiKeys.title"))
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.send(.presentCreateForm)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(
                            store.hasReachedActiveKeyLimit
                                || store.isLoadingFirstPage
                                || store.isSessionExpired
                                || store.isBusy
                                || !store.isMetadataReady
                        )
                        .accessibilityLabel(String(localized: "apiKeys.create"))
                        .accessibilityIdentifier("settings.apiKeys.create")
                    }
                }
                .refreshable { store.send(.refresh) }
                .task { store.send(.onAppear) }
                .onChange(of: scenePhase) { _, phase in
                    store.send(.scenePhaseChanged(isActive: phase == .active))
                }
                .onChange(of: observedAccountID) { _, newValue in
                    store.send(.accountChanged(newValue))
                }
                .sheet(isPresented: createSheetBinding) {
                    createSheet
                }
                .alert(
                    String(localized: "apiKeys.revoke.title"),
                    isPresented: revokeAlertBinding,
                    presenting: store.revokeTarget
                ) { key in
                    Button(String(localized: "apiKeys.revoke.confirm"), role: .destructive) {
                        store.send(.confirmRevoke)
                    }
                    Button(String(localized: "diary.common.cancel"), role: .cancel) {
                        store.send(.cancelRevoke)
                    }
                } message: { key in
                    Text(
                        String(
                            format: String(localized: "apiKeys.revoke.message"),
                            key.name,
                            key.tokenHint
                        )
                    )
                }
                .interactiveDismissDisabled(store.isCreatePresented || store.isRevoking)
        }
        .navigationBarBackButtonHidden(store.isBusy)
        .accessibilityIdentifier("settings.apiKeys")
#if os(macOS)
        .frame(minWidth: 440, idealWidth: 540, maxWidth: 680)
#endif
        .onDisappear { store.send(.clearOnDismiss) }
    }

    private func close() {
        guard !store.isBusy else { return }
        store.send(.clearOnDismiss)
        store.send(.delegate(.dismiss(generation: store.generation)))
        onClose()
    }

    // MARK: - List

    private var list: some View {
        List {
            if let notice = store.listNotice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.apiKeys.notice")
                }
            }

            if let message = store.revokeErrorMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.apiKeys.revoke.error")
                }
            }

            keysSection

            Section {
                if store.hasReachedActiveKeyLimit {
                    Label(
                        String(localized: "apiKeys.limit.message"),
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.apiKeys.limit")
                }

                Text(String(localized: "apiKeys.description"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("settings.apiKeys.list")
    }

    @ViewBuilder
    private var keysSection: some View {
        Section {
            switch store.listPhase {
            case .idle:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(String(localized: "apiKeys.loading"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.apiKeys.loading")

            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(String(localized: "apiKeys.loading"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.apiKeys.loading")

            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.apiKeys.error")
                    Button(String(localized: "diary.common.retry")) {
                        store.send(.refresh)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.apiKeys.retry")
                }

            case .loaded(let keys), .refreshing(previous: let keys):
                if keys.isEmpty {
                    ContentUnavailableView {
                        Label(
                            String(localized: "apiKeys.empty.title"),
                            systemImage: "key"
                        )
                    } description: {
                        Text(String(localized: "apiKeys.empty.message"))
                    }
                    .accessibilityIdentifier("settings.apiKeys.empty")
                } else {
                    ForEach(keys) { key in
                        keyRow(key)
                    }
                }
            }

            if store.listPhase.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "apiKeys.refreshing"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.apiKeys.refreshing")
            }
        } header: {
            Text(String(localized: "apiKeys.list.title"))
        } footer: {
            Text(String(localized: "apiKeys.limit.footer"))
        }
    }

    private func keyRow(_ key: APIKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityValue(
                    dynamicTypeSize.isAccessibilitySize ? metadataLabel(for: key) : ""
                )

            Text(scopeLabel(key.scope))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                String(
                    format: String(localized: "apiKeys.hint"),
                    key.tokenHint
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !dynamicTypeSize.isAccessibilitySize {
                Text(metadataLabel(for: key))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if key.isExpired(at: store.now) {
                Label(
                    String(localized: "apiKeys.expired"),
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                if store.revokingKeyID == key.id {
                    ProgressView()
                    Text(String(localized: "apiKeys.revoking"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.apiKeys.revoking")
                } else {
                    Button(String(localized: "apiKeys.revoke"), role: .destructive) {
                        store.send(.requestRevoke(key))
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy || store.isCreatePresented)
                    .accessibilityLabel(
                        String(format: String(localized: "apiKeys.revoke.named"), key.name)
                    )
                    .accessibilityIdentifier("settings.apiKeys.revoke.\(key.id)")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.apiKeys.row.\(key.id)")
    }

    private func scopeLabel(_ scope: APIKeyScope) -> String {
        switch scope {
        case .read: return String(localized: "apiKeys.scope.read")
        case .readWrite: return String(localized: "apiKeys.scope.readWrite")
        case .unknown: return String(localized: "apiKeys.scope.unknown")
        }
    }

    private func metadataLabel(for key: APIKey) -> String {
        var parts = [
            String(
                format: String(localized: "apiKeys.created"),
                APIKeyTimestamp.displayString(from: key.createdAt)
            )
        ]
        if let lastUsedAt = key.lastUsedAt {
            parts.append(
                String(
                    format: String(localized: "apiKeys.lastUsed"),
                    APIKeyTimestamp.displayString(from: lastUsedAt)
                )
            )
        } else {
            parts.append(String(localized: "apiKeys.neverUsed"))
        }
        if let expiresAt = key.expiresAt {
            parts.append(
                String(
                    format: String(localized: "apiKeys.expires"),
                    APIKeyTimestamp.displayString(from: expiresAt)
                )
            )
        } else {
            parts.append(String(localized: "apiKeys.neverExpires"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Create / reveal sheet

    private var createSheetBinding: Binding<Bool> {
        Binding(
            get: { store.isCreatePresented },
            set: { isPresented in
                if !isPresented { store.send(.createSheetDidDisappear) }
            }
        )
    }

    private var createSheet: some View {
        NavigationStack {
            Group {
                if let created = store.createdKey {
                    secretReveal(created)
                } else {
                    createForm
                }
            }
            .navigationTitle(
                store.createdKey == nil
                    ? String(localized: "apiKeys.create.title")
                    : String(localized: "apiKeys.secret.title")
            )
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                if store.createdKey == nil {
                    ToolbarItem(placement: backPlacement) {
                        Button {
                            isNameFocused = false
                            store.send(.cancelCreateForm)
                        } label: {
                            Text(String(localized: "diary.common.cancel"))
                        }
                        .disabled(store.createState == .submitting)
                        .accessibilityIdentifier("settings.apiKeys.create.cancel")
                    }
                }
            }
            .interactiveDismissDisabled()
            .onChange(of: scenePhase) { _, phase in
                store.send(.scenePhaseChanged(isActive: phase == .active))
            }
            .onDisappear { store.send(.createSheetDidDisappear) }
        }
#if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
#endif
#if os(macOS)
        .frame(minWidth: 440, idealWidth: 540, maxWidth: 680)
#endif
    }

    private var createForm: some View {
        Form {
            Section {
                TextField(String(localized: "apiKeys.create.name"), text: nameBinding)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit { isNameFocused = false }
                    .disabled(!store.isCreateFormEnabled)
                    .accessibilityIdentifier("settings.apiKeys.create.name")

                if let message = store.nameValidationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.apiKeys.create.nameError")
                }
            } header: {
                Text(String(localized: "apiKeys.create.details"))
            } footer: {
                Text(String(localized: "apiKeys.create.description"))
            }

            Section {
                Picker(
                    String(localized: "apiKeys.create.scope"),
                    selection: scopeBinding
                ) {
                    Text(String(localized: "apiKeys.scope.read"))
                        .tag(APIKeyCreatableScope.read)
                    Text(String(localized: "apiKeys.scope.readWrite"))
                        .tag(APIKeyCreatableScope.readWrite)
                }
                .pickerStyle(.inline)
                .disabled(!store.isCreateFormEnabled)
                .accessibilityIdentifier("settings.apiKeys.create.scope")

                Text(scopeDescription(store.draftScope))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(String(localized: "apiKeys.create.scope"))
            }

            Section {
                Picker(
                    String(localized: "apiKeys.create.expiry"),
                    selection: expiryBinding
                ) {
                    ForEach(APIKeyExpiryChoice.allCases, id: \.self) { choice in
                        Text(expiryLabel(choice)).tag(choice)
                    }
                }
                .disabled(!store.isCreateFormEnabled)
                .accessibilityIdentifier("settings.apiKeys.create.expiry")
            } header: {
                Text(String(localized: "apiKeys.create.expiry"))
            }

            if let message = store.createErrorMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.apiKeys.create.error")
                }
            }

            if let message = store.createUncertainMessage {
                Section {
                    Label(
                        String(localized: "apiKeys.create.uncertain.title"),
                        systemImage: "questionmark.circle"
                    )
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings.apiKeys.create.uncertain")

                    Text(message)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)

                    if store.uncertainMetadataRefreshFailed {
                        Text(String(localized: "apiKeys.create.uncertain.refreshFailed"))
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.apiKeys.create.uncertain.refreshError")
                    }

                    Button(String(localized: "apiKeys.create.refresh")) {
                        store.send(.refreshMetadataForUncertainCreate)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.apiKeys.create.refresh")
                }
            }

            Section {
                Text(String(localized: "apiKeys.create.storageWarning"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            createSubmitBar
        }
        .disabled(store.createState == .submitting)
        .accessibilityHidden(store.createState == .submitting)
        .overlay {
            if store.createState == .submitting { submittingOverlay }
        }
    }

    private var createSubmitBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isNameFocused = false
                store.send(.submitCreate)
            } label: {
                HStack(spacing: 8) {
                    if store.createState == .submitting {
                        ProgressView().accessibilityHidden(true)
                    }
                    Text(
                        store.createState == .submitting
                            ? String(localized: "apiKeys.create.submitting")
                            : String(localized: "apiKeys.create.submit")
                    )
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(store.isCreateSubmitDisabled)
            .accessibilityIdentifier("settings.apiKeys.create.submitBottom")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var submittingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "apiKeys.create.submitting"))
                    .font(.headline)
            }
            .padding(24)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.apiKeys.create.submitting")
    }

    private func scopeDescription(_ scope: APIKeyCreatableScope) -> String {
        switch scope {
        case .read: return String(localized: "apiKeys.create.scope.readDescription")
        case .readWrite: return String(localized: "apiKeys.create.scope.readWriteDescription")
        }
    }

    private func expiryLabel(_ choice: APIKeyExpiryChoice) -> String {
        switch choice {
        case .days30: return String(localized: "apiKeys.create.expiry.30Days")
        case .days90: return String(localized: "apiKeys.create.expiry.90Days")
        case .days365: return String(localized: "apiKeys.create.expiry.365Days")
        case .never: return String(localized: "apiKeys.create.expiry.never")
        }
    }

    // MARK: - One-time secret

    private func secretReveal(_ created: CreatedAPIKey) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(
                    String(localized: "apiKeys.secret.warning"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.apiKeys.secret.warning")

                if store.isSecretRevealed {
                    Text(created.secret.value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("settings.apiKeys.secret")

                    Button(String(localized: "apiKeys.secret.hide")) {
                        store.send(.hideSecret)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.apiKeys.secret.hide")
                } else {
                    Text(String(localized: "apiKeys.secret.hidden"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("settings.apiKeys.secret.hidden")

                    Button(String(localized: "apiKeys.secret.reveal")) {
                        store.send(.revealSecret)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.apiKeys.secret.reveal")
                }

                HStack(spacing: 12) {
                    Button {
                        store.send(.copySecret)
                    } label: {
                        Label(
                            String(localized: "apiKeys.secret.copy"),
                            systemImage: "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(!store.canCopySecret)
                    .accessibilityLabel(String(localized: "apiKeys.secret.copy.accessibility"))
                    .accessibilityIdentifier("settings.apiKeys.secret.copy")

                    switch store.copyState {
                    case .idle: EmptyView()
                    case .copied:
                        Label(
                            String(localized: "apiKeys.secret.copied"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("settings.apiKeys.secret.copied")
                    case .failed:
                        Text(String(localized: "apiKeys.secret.copyFailed"))
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.apiKeys.secret.copyError")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "apiKeys.secret.usage"))
                        .font(.subheadline)
                    Text(String(localized: "apiKeys.secret.usageExample"))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                Text(String(localized: "apiKeys.secret.storage"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    store.send(.finishSecretReveal)
                } label: {
                    Text(String(localized: "apiKeys.close"))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.apiKeys.secret.done")
            }
            .padding()
            .privacySensitive()
        }
    }

    private var revokeAlertBinding: Binding<Bool> {
        Binding(
            get: { store.revokeTarget != nil },
            set: { isPresented in
                if !isPresented { store.send(.cancelRevoke) }
            }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(get: { store.draftName }, set: { store.send(.draftNameChanged($0)) })
    }

    private var scopeBinding: Binding<APIKeyCreatableScope> {
        Binding(get: { store.draftScope }, set: { store.send(.draftScopeChanged($0)) })
    }

    private var expiryBinding: Binding<APIKeyExpiryChoice> {
        Binding(get: { store.draftExpiry }, set: { store.send(.draftExpiryChanged($0)) })
    }
}
