import LuxtableCore
import SwiftUI

// Dragging photos out of the grid or the filmstrip to the Finder or another app (macOS).
// The drop receives copies of the originals (`PhotoFile`), and only a copy is offered.

/// On a cell: it can be dragged out. In Map mode the cell carries photos onto the map
/// instead (`MapDragSource`).
struct PhotoFileDragSource: ViewModifier {
    @Bindable var model: AppModel
    let id: PhotoID

    func body(content: Content) -> some View {
        #if os(macOS)
        if model.browserMode == .map {
            content
        } else {
            content.draggable(containerItemID: id)
        }
        #else
        content
        #endif
    }
}

/// On the grid or filmstrip that holds the cells: what a drag carries (the selection when
/// it starts on a selected photo, else that photo).
struct PhotoFileDragContainer: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .dragContainer(for: PhotoFile.self, itemID: \.id) { (ids: [PhotoID]) in model.dragFiles(for: ids) }
            .dragContainerSelection(model.dragSelection)
            .dragConfiguration(DragConfiguration(
                operationsWithinApp: .init(allowCopy: true, allowMove: false, allowDelete: false),
                operationsOutsideApp: .init(allowCopy: true, allowMove: false, allowDelete: false)))
        #else
        content
        #endif
    }
}
