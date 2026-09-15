import CopyCore
import SwiftUI

/// Hosts the shelf's modal content (edit / create / adjust color / tips) centered over a
/// dim backdrop. Lives in a full-screen child window of the shelf panel
/// (`ShelfPanelController.presentModal`) so the content is fully visible above the
/// bottom-anchored shelf rather than overflowing off the bottom as an attached sheet did.
/// `ShelfRootView` drives show/hide (it's always on screen while the shelf is open), so
/// this view just renders whichever modal is active.
struct ShelfModalHostView: View {
    @Bindable var viewModel: ShelfViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(viewModel.settings.shelfTheme == .dark ? Tokens.electricBlue : nil)
    }

    @ViewBuilder
    private var content: some View {
        if let item = viewModel.editingItem {
            EditItemSheet(
                item: item,
                store: viewModel.store,
                onCancel: { viewModel.editingItem = nil },
                onSave: { viewModel.commitEdit(attributed: $0) }
            )
        } else if viewModel.creatingItem {
            CreateItemSheet(
                onCancel: { viewModel.creatingItem = false },
                onCreate: { text, title in viewModel.commitCreate(text: text, title: title) }
            )
        } else if let item = viewModel.adjustingColorItem {
            ColorAdjustSheet(
                item: item,
                onCancel: { viewModel.adjustingColorItem = nil },
                onCopy: { viewModel.commitAdjustColor($0) }
            )
        } else if viewModel.showingTips {
            TipsSheet(onDone: { viewModel.showingTips = false })
        }
    }
}
