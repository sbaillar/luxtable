#if os(macOS)
import AppKit
#else
import Foundation
#endif

/// The system share picker (Messages, Mail, AirDrop, Notes, Photos…) for files.
/// iPadOS (unverified) would use `UIActivityViewController`; for now it reports `.unavailable`.
@MainActor
public final class PlatformSharePicker: NSObject, SharePresenting {
    #if os(macOS)
    /// The view the picker points at (the toolbar's Share button); without one, the
    /// key window's content.
    public weak var anchor: NSView?
    private var completion: (@MainActor (ShareChoice) -> Void)?
    private var picker: NSSharingServicePicker?

    public func present(_ files: [URL], completion: @escaping @MainActor (ShareChoice) -> Void) {
        let anchored = anchor.flatMap { $0.window?.isVisible == true ? $0 : nil }
        guard let view = anchored ?? NSApplication.shared.keyWindow?.contentView else {
            completion(.unavailable)
            return
        }
        // Without the button, the picker points at the top middle of the window.
        let rect = anchored != nil ? view.bounds
            : NSRect(x: view.bounds.midX, y: view.isFlipped ? 0 : view.bounds.maxY - 1, width: 1, height: 1)
        self.completion?(.dismissed) // a picker still open is replaced
        self.completion = completion
        let picker = NSSharingServicePicker(items: files)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
    #else
    public func present(_ files: [URL], completion: @escaping @MainActor (ShareChoice) -> Void) {
        completion(.unavailable)
    }
    #endif
}

#if os(macOS)
extension PlatformSharePicker: NSSharingServicePickerDelegate {
    public nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                                 didChoose service: NSSharingService?) {
        let title = service?.title
        MainActor.assumeIsolated {
            let done = completion
            completion = nil
            picker = nil
            done?(title.map { .chosen($0) } ?? .dismissed)
        }
    }
}
#endif
