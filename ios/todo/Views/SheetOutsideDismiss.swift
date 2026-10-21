import SwiftUI

extension View {
    /// Native popovers dismiss on outside clicks. Compact devices adapt to a
    /// sheet; roomy devices keep a fitted editor without enabling backing controls.
    func outsideDismissSheet<Sheet: View>(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        let anchor = PopoverAttachmentAnchor.point(.top)
        #else
        let anchor = PopoverAttachmentAnchor.rect(.bounds)
        #endif
        return popover(isPresented: isPresented, attachmentAnchor: anchor, arrowEdge: .top) {
            content()
        }
        .onChange(of: isPresented.wrappedValue) { previous, current in
            if previous && !current { onDismiss() }
        }
    }

    func outsideDismissSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        popover(item: item, attachmentAnchor: .point(.top), arrowEdge: .top, content: content)
            .onChange(of: item.wrappedValue?.id) { previous, current in
                if previous != nil && current == nil { onDismiss() }
            }
    }
}
