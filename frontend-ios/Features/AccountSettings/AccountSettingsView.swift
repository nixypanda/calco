// Account Settings / personal API keys.
//
// Native SwiftUI, English-only, Apple-default appearance. The layout starts
// from the iPhone 13 mini width and scales to iPad/macOS without fixed widths.

import SwiftUI

public struct AccountSettingsView: View {
    @StateObject private var viewModel: AccountSettingsViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isNameFocused: Bool

    private let observedAccountID: String
    private let onClose: () -> Void

    public init(
        viewModel: AccountSettingsViewModel,
        onClose: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.observedAccountID = viewModel.accountID
        self.onClose = onClose
    }

    public init(
        service: any APIKeyServicing,
        accountID: String,
        clipboard: any APIKeySecretCopying = SystemAPIKeySecretClipboard(),
        nowProvider: @escaping () -> Date = { Date() },
        onSessionExpired: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        let viewModel = AccountSettingsViewModel(
            service: service,
            accountID: accountID,
            clipboard: clipboard,
            nowProvider: nowProvider
        )
        viewModel.onSessionExpired = onSessionExpired
        _viewModel = StateObject(wrappedValue: viewModel)
        self.observedAccountID = accountID
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            list
                .navigationTitle(String(localized: "apiKeys.title"))
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "apiKeys.close")) {
                            close()
                        }
                        .disabled(viewModel.isBusy)
                        .accessibilityIdentifier("settings.apiKeys.close")
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.presentCreateForm()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(
                            viewModel.hasReachedActiveKeyLimit
                                || viewModel.isLoadingFirstPage
                                || viewModel.isSessionExpired
                                || viewModel.isBusy
                                || !viewModel.isMetadataReady
                        )
                        .accessibilityLabel(String(localized: "apiKeys.create"))
                        .accessibilityIdentifier("settings.apiKeys.create")
                    }
                }
                .refreshable {
                    await viewModel.load()
                }
                .task {
                    await viewModel.loadIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    viewModel.scenePhaseChanged(isActive: phase == .active)
                }
                .onChange(of: observedAccountID) { _, newValue in
                    viewModel.accountDidChange(to: newValue)
                }
                .sheet(isPresented: createSheetBinding) {
                    createSheet
                }
                .alert(
                    String(localized: "apiKeys.revoke.title"),
                    isPresented: revokeAlertBinding,
                    presenting: viewModel.revokeTarget
                ) { key in
                    Button(String(localized: "apiKeys.revoke.confirm"), role: .destructive) {
                        Task { await viewModel.confirmRevoke(key) }
                    }

                    Button(String(localized: "diary.common.cancel"), role: .cancel) {
                        viewModel.cancelRevoke()
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
                .interactiveDismissDisabled(viewModel.isCreatePresented || viewModel.isRevoking)
        }
        .accessibilityIdentifier("settings.apiKeys")
#if os(macOS)
        .frame(minWidth: 440, idealWidth: 540, maxWidth: 680)
#endif
    }

    // MARK: - List

    private var list: some View {
        List {
            if let notice = viewModel.listNotice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.apiKeys.notice")
                }
            }

            if let message = viewModel.revokeErrorMessage {
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
                if viewModel.hasReachedActiveKeyLimit {
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
            switch viewModel.listState {
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
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.apiKeys.retry")
                }

            case .loaded:
                if viewModel.keys.isEmpty {
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
                    ForEach(viewModel.keys) { key in
                        keyRow(key)
                    }
                }
            }

            if viewModel.isRefreshing {
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
                    dynamicTypeSize.isAccessibilitySize
                        ? metadataLabel(for: key)
                        : ""
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

            if key.isExpired(at: viewModel.now) {
                Label(
                    String(localized: "apiKeys.expired"),
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                if viewModel.revokingKeyID == key.id {
                    ProgressView()
                    Text(String(localized: "apiKeys.revoking"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.apiKeys.revoking")
                } else {
                    Button(String(localized: "apiKeys.revoke"), role: .destructive) {
                        viewModel.requestRevoke(key)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isBusy || viewModel.isCreatePresented)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "apiKeys.revoke.named"),
                            key.name
                        )
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
        case .read:
            return String(localized: "apiKeys.scope.read")
        case .readWrite:
            return String(localized: "apiKeys.scope.readWrite")
        case .unknown:
            return String(localized: "apiKeys.scope.unknown")
        }
    }

    private func creatableScopeLabel(_ scope: APIKeyCreatableScope) -> String {
        switch scope {
        case .read:
            return String(localized: "apiKeys.scope.read")
        case .readWrite:
            return String(localized: "apiKeys.scope.readWrite")
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
            get: { viewModel.isCreatePresented },
            set: { isPresented in
                if !isPresented {
                    viewModel.createSheetDidDisappear()
                }
            }
        )
    }

    private var createSheet: some View {
        NavigationStack {
            Group {
                if let created = viewModel.createdKey {
                    secretReveal(created)
                } else {
                    createForm
                }
            }
            .navigationTitle(
                viewModel.createdKey == nil
                    ? String(localized: "apiKeys.create.title")
                    : String(localized: "apiKeys.secret.title")
            )
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                if viewModel.createdKey == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "diary.common.cancel")) {
                            isNameFocused = false
                            viewModel.cancelCreateForm()
                        }
                        .disabled(viewModel.createState == .submitting)
                        .accessibilityIdentifier("settings.apiKeys.create.cancel")
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "apiKeys.create.submit")) {
                            isNameFocused = false
                            Task { await viewModel.submitCreate() }
                        }
                        .disabled(viewModel.isCreateSubmitDisabled)
                        .accessibilityIdentifier("settings.apiKeys.create.submit")
                    }
                }
            }
#if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "apiKeys.keyboard.done")) {
                        isNameFocused = false
                    }
                    .accessibilityIdentifier("settings.apiKeys.create.keyboard.done")
                }
            }
#endif
            // Cancellation is an explicit toolbar action. Prevent a form swipe
            // from destroying a partially entered key or the parent sheet.
            .interactiveDismissDisabled()
            .onChange(of: scenePhase) { _, phase in
                viewModel.scenePhaseChanged(isActive: phase == .active)
            }
            .onDisappear {
                viewModel.createSheetDidDisappear()
            }
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
                TextField(String(localized: "apiKeys.create.name"), text: $viewModel.draftName)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit { isNameFocused = false }
                    .disabled(!viewModel.isCreateFormEnabled)
                    .accessibilityIdentifier("settings.apiKeys.create.name")

                if let message = viewModel.nameValidationMessage {
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
                    selection: $viewModel.draftScope
                ) {
                    Text(String(localized: "apiKeys.scope.read"))
                        .tag(APIKeyCreatableScope.read)
                    Text(String(localized: "apiKeys.scope.readWrite"))
                        .tag(APIKeyCreatableScope.readWrite)
                }
                .pickerStyle(.inline)
                .disabled(!viewModel.isCreateFormEnabled)
                .accessibilityIdentifier("settings.apiKeys.create.scope")

                Text(scopeDescription(viewModel.draftScope))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(String(localized: "apiKeys.create.scope"))
            }

            Section {
                Picker(
                    String(localized: "apiKeys.create.expiry"),
                    selection: $viewModel.draftExpiry
                ) {
                    ForEach(APIKeyExpiryChoice.allCases, id: \.self) { choice in
                        Text(expiryLabel(choice))
                            .tag(choice)
                    }
                }
                .disabled(!viewModel.isCreateFormEnabled)
                .accessibilityIdentifier("settings.apiKeys.create.expiry")
            } header: {
                Text(String(localized: "apiKeys.create.expiry"))
            }

            if let message = viewModel.createErrorMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.apiKeys.create.error")
                }
            }

            if let message = viewModel.createUncertainMessage {
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

                    if viewModel.uncertainMetadataRefreshFailed {
                        Text(String(localized: "apiKeys.create.uncertain.refreshFailed"))
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.apiKeys.create.uncertain.refreshError")
                    }

                    Button(String(localized: "apiKeys.create.refresh")) {
                        Task { await viewModel.refreshMetadataForUncertainCreate() }
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
        .disabled(viewModel.createState == .submitting)
        .accessibilityHidden(viewModel.createState == .submitting)
        .overlay {
            if viewModel.createState == .submitting {
                submittingOverlay
            }
        }
    }

    private var createSubmitBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isNameFocused = false
                Task { await viewModel.submitCreate() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.createState == .submitting {
                        ProgressView()
                            .accessibilityHidden(true)
                    }
                    Text(
                        viewModel.createState == .submitting
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
            .disabled(viewModel.isCreateSubmitDisabled)
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
        case .read:
            return String(localized: "apiKeys.create.scope.readDescription")
        case .readWrite:
            return String(localized: "apiKeys.create.scope.readWriteDescription")
        }
    }

    private func expiryLabel(_ choice: APIKeyExpiryChoice) -> String {
        switch choice {
        case .days30:
            return String(localized: "apiKeys.create.expiry.30Days")
        case .days90:
            return String(localized: "apiKeys.create.expiry.90Days")
        case .days365:
            return String(localized: "apiKeys.create.expiry.365Days")
        case .never:
            return String(localized: "apiKeys.create.expiry.never")
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

                if viewModel.isSecretRevealed {
                    Text(created.secret.value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("settings.apiKeys.secret")

                    Button(String(localized: "apiKeys.secret.hide")) {
                        viewModel.hideSecret()
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
                        viewModel.revealSecret()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.apiKeys.secret.reveal")
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.copySecret()
                    } label: {
                        Label(
                            String(localized: "apiKeys.secret.copy"),
                            systemImage: "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canCopySecret)
                    .accessibilityLabel(String(localized: "apiKeys.secret.copy.accessibility"))
                    .accessibilityIdentifier("settings.apiKeys.secret.copy")

                    switch viewModel.copyState {
                    case .idle:
                        EmptyView()
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
                    viewModel.finishSecretReveal()
                } label: {
                    Text(String(localized: "apiKeys.secret.done"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.apiKeys.secret.done")
            }
            .padding()
            .privacySensitive()
        }
    }

    // MARK: - Helpers

    private var revokeAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.revokeTarget != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelRevoke()
                }
            }
        )
    }

    private func close() {
        guard !viewModel.isBusy else { return }
        viewModel.clearSensitiveStateOnDismissal()
        onClose()
    }
}
