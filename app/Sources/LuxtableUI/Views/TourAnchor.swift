import LuxtableCore
import SwiftUI

/// The frames of the parts the Getting Started tour can light, collected up the view
/// tree to the main window's overlay.
package struct TourAnchorKey: PreferenceKey {
    package static let defaultValue: [TourAnchor: Anchor<CGRect>] = [:]

    package static func reduce(value: inout [TourAnchor: Anchor<CGRect>], nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// This view is `anchor` for the Getting Started tour.
    package func tourAnchor(_ anchor: TourAnchor) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}
