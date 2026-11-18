import SwiftUI

public enum LogEditorField: Hashable, Sendable {
    case amount
    case notes
}

public struct LogEditorView: View {
    @ObservedObject private var viewModel: LogEditorViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedField: LogEditorField?

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    public init(viewModel: LogEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            List {
                errorSection
                headerSection
                amountSection
                mealSection
                notesSection
            }
            actionBar
        }
        .navigationTitle(String(localized: "diary.editor.title"))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                Button(String(localized: "diary.editor.keyboardDone")) {
                    focusedField = nil
                }
                .accessibilityIdentifier("diary.editor.keyboardDone")
            }
        }
#endif
        .confirmationDialog(
            viewModel.deleteConfirmationMessage,
            isPresented: $viewModel.isDeleteConfirmationPresented
        ) {
            Button(String(localized: "diary.editor.delete.confirm.action"), role: .destructive) {
                Task { await viewModel.delete() }
            }
            .accessibilityIdentifier("diary.editor.delete.confirm")
            Button(String(localized: "diary.common.cancel"), role: .cancel) {
                viewModel.cancelDelete()
            }
        }
        .task {
            await viewModel.loadUnits()
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        switch viewModel.state {
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .accessibilityIdentifier("diary.editor.error")
                Button(String(localized: "diary.common.retry")) {
                    viewModel.retry()
                }
                .accessibilityIdentifier("diary.editor.retry")
            }
        case .sessionExpired:
            Section {
                Label(
                    String(localized: "diary.error.sessionExpired"),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(.red)
                .font(.footnote)
                .accessibilityIdentifier("diary.editor.sessionExpired")
            }
        case .saved:
            Section {
                Label(String(localized: "diary.editor.saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("diary.editor.saved")
            }
        case .deleted:
            Section {
                Label(String(localized: "diary.editor.deleted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("diary.editor.deleted")
            }
        default:
            EmptyView()
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = viewModel.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(viewModel.date.diaryDisplayTitle())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("diary.editor.header")
        }
    }

    private var amountSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "foodDetail.amount"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "foodDetail.amount"), text: $viewModel.amount)
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                    .focused($focusedField, equals: .amount)
                    .disabled(!viewModel.canEdit)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "foodDetail.amount"))
                    .accessibilityIdentifier("diary.editor.amount")
            }
            Picker(String(localized: "foodDetail.unit"), selection: $viewModel.unit) {
                ForEach(viewModel.units) { unit in
                    Text(unit.name).tag(unit.code)
                }
            }
            .pickerStyle(.menu)
            .disabled(!viewModel.canEdit)
            .accessibilityIdentifier("diary.editor.unit")
        } footer: {
            if let message = viewModel.validationMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .accessibilityIdentifier("diary.editor.validation")
            }
        }
    }

    private var mealSection: some View {
        Section {
            Picker(String(localized: "foodDetail.mealSlot"), selection: $viewModel.mealSlot) {
                Text(String(localized: "foodDetail.mealSlot.none")).tag(MealSlot?.none)
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    Text(DiaryLabels.mealSlotName(slot)).tag(MealSlot?.some(slot))
                }
            }
            .disabled(!viewModel.canEdit)
            .accessibilityIdentifier("diary.editor.mealSlot")
        }
    }

    private var notesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "foodDetail.notes"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "foodDetail.notes"), text: $viewModel.notes, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focusedField, equals: .notes)
                    .disabled(!viewModel.canEdit)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "foodDetail.notes"))
                    .accessibilityIdentifier("diary.editor.notes")
            }
        }
    }

    /// Actions live outside the scrolling form so they stay reachable with the
    /// keyboard up and at accessibility text sizes on small phones/iPads.
    /// Saving and deleting replace the actions with an explicit progress row so
    /// the operation cannot be dismissed or hidden behind a disappearing bar.
    @ViewBuilder
    private var actionBar: some View {
        if viewModel.isBusy {
            HStack(spacing: 10) {
                ProgressView()
                Text(viewModel.busyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("diary.editor.progress")
        } else if viewModel.canEdit {
            VStack(spacing: usesAccessibilityLayout ? 10 : 8) {
                if usesAccessibilityLayout {
                    saveButton
                    deleteButton
                } else {
                    HStack(spacing: 12) {
                        saveButton
                        deleteButton
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityIdentifier("diary.editor.actions")
        }
    }

    private var saveButton: some View {
        Button {
            focusedField = nil
            Task { await viewModel.save() }
        } label: {
            if case .saving = viewModel.state {
                ProgressView()
            } else {
                Text(String(localized: "diary.editor.save"))
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.validationMessage != nil || viewModel.state.isBusy)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("diary.editor.save")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            focusedField = nil
            viewModel.requestDelete()
        } label: {
            Text(String(localized: "diary.editor.delete"))
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.state.isBusy)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("diary.editor.delete")
    }
}
