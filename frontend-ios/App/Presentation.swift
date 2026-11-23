import SwiftUI

/// Browsing routes stay in their stack; logging routes are presented as tasks.
enum NativePresentation {
    static func pagePath(_ path: [Pane]) -> [Pane] {
        path.filter { pane in
            switch pane {
            case .foodDetail, .foodLog: return false
            default: return true
            }
        }
    }

    static func loggingFoodID(in pane: Pane?) -> String? {
        switch pane {
        case .foodDetail(let id), .foodLog(let id): return id
        default: return nil
        }
    }
}

struct FoodLogTaskView: View {
    @ObservedObject var viewModel: FoodDetailViewModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            FoodDetailView(viewModel: viewModel, compactStyle: true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "diary.common.cancel"), action: onClose)
                            .disabled(viewModel.isBusy)
                            .accessibilityIdentifier("foodDetail.cancel")
                    }
                }
        }
        .interactiveDismissDisabled(viewModel.isBusy)
        .presentationDetents([.large])
        .onChange(of: viewModel.didSubmitSuccessfully) { _, success in
            if success { onClose() }
        }
        .accessibilityIdentifier("foodDetail.logSheet")
    }
}
