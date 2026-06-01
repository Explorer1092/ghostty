import AppKit
import SwiftUI

/// `macos-titlebar-style = tabs` for macOS 26 (Tahoe) and later.
///
/// Historically this class hijacked the system NSTabBar and re-parented it into
/// the titlebar. With the new `tabs-position` system Ghostty renders its own
/// tab bar in `TerminalView`, so the system NSTabBar is suppressed entirely
/// (see `TerminalWindow.addTitlebarAccessoryViewController`). What remains is
/// the titlebar's *visual character*: a transparent, toolbar-style titlebar
/// with a centered window title. The actual tab list lives elsewhere in the
/// SwiftUI hierarchy.
class TitlebarTabsTahoeTerminalWindow: TransparentTitlebarTerminalWindow, NSToolbarDelegate {
    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    /// We render our own tab bar inside the content view, so AppKit's
    /// titlebar accessory tab bar is suppressed and the regular update
    /// accessory works fine alongside our title.
    override var supportsUpdateAccessory: Bool { true }

    // MARK: NSWindow

    override var titlebarFont: NSFont? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.titleFont = self.titlebarFont
            }
        }
    }

    override var title: String {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.title = self.title
            }
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        // We render the title via the toolbar (centered), so hide the native
        // titlebar text.
        titleVisibility = .hidden

        // Create a toolbar
        let toolbar = NSToolbar(identifier: "TerminalToolbar")
        toolbar.delegate = self
        toolbar.centeredItemIdentifiers.insert(.title)
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
    }

    override func becomeMain() {
        super.becomeMain()
        viewModel.isMainWindow = true
    }

    override func resignMain() {
        super.resignMain()
        viewModel.isMainWindow = false
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.title, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, .title, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .title:
            let item = NSToolbarItem(itemIdentifier: .title)
            item.view = ClickThroughHostingView(rootView: TitleItem(viewModel: viewModel))
            // Fix: https://github.com/ghostty-org/ghostty/discussions/9027
            item.view?.setContentCompressionResistancePriority(.required, for: .horizontal)
            item.visibilityPriority = .user
            item.isEnabled = false

            // This is the documented way to avoid the glass view on an item.
            // We don't want glass on our title.
            item.isBordered = false

            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }

    // MARK: SwiftUI

    class ViewModel: ObservableObject {
        @Published var titleFont: NSFont?
        @Published var title: String = "👻 Ghostty"
        @Published var isMainWindow: Bool = true
    }
}

extension NSToolbarItem.Identifier {
    /// Displays the title of the window
    static let title = NSToolbarItem.Identifier("Title")
}

extension TitlebarTabsTahoeTerminalWindow {
    /// Displays the window title
    struct TitleItem: View {
        @ObservedObject var viewModel: ViewModel

        var title: String {
            // An empty title makes this view zero-sized and NSToolbar on macOS
            // tahoe just deletes the item when that happens. So we use a space
            // instead to ensure there's always some size.
            return viewModel.title.isEmpty ? " " : viewModel.title
        }

        var body: some View {
            Text(title)
                .font(viewModel.titleFont.flatMap(Font.init(_:)))
                .foregroundStyle(viewModel.isMainWindow ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .greatestFiniteMagnitude, alignment: .center)
        }
    }
}

/// A "Ghosting" Hosting View, that acts like it's not there
private class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
