import AppKit
import HouseUIKit

extension MenuPanelModel: MenuPanelModeling {}

/// Cotype's panel window.
@MainActor
final class MenuBarPanelController: MenuPanelController<MenuBarPanelView, MenuPanelModel> {
    init() {
        let model = MenuPanelModel()
        super.init(model: model, width: MenuBarPanelView.width, rootView: { MenuBarPanelView(model: model) })
    }

    override func panelWillShow() {
        model.selection = 0
    }
}
