import Cocoa

/// `macos-titlebar-style = tabs` for macOS 13 to 15 (Ventura/Sonoma/Sequoia).
///
/// Historically this class hijacked the system NSTabBar and re-parented it
/// into the titlebar (along with a custom window-buttons backdrop, drag
/// handle, per-tab styling, and the various "make NSTabBar look the way we
/// want" hacks). With the new `tabs-position` system Ghostty renders its own
/// tab bar in `TerminalView`, so the system NSTabBar is suppressed entirely
/// (see `TerminalWindow.addTitlebarAccessoryViewController`). What remains is
/// the titlebar's *visual character*: a transparent titlebar that picks up
/// the terminal background color, plus a unified-compact toolbar with a
/// centered window title and a reset-zoom item. The actual tab list lives
/// elsewhere in the SwiftUI hierarchy.
class TitlebarTabsVenturaTerminalWindow: TerminalWindow {
    /// We render our own tab bar inside the content view, so AppKit's
    /// titlebar accessory tab bar is suppressed and the regular update
    /// accessory works fine alongside our title.
    override var supportsUpdateAccessory: Bool { true }

    /// This is used to determine if certain elements should be drawn light or dark and should
    /// be updated whenever the window background color or surrounding elements changes.
    fileprivate var isLightTheme: Bool = false

    lazy var titlebarColor: NSColor = backgroundColor {
        didSet {
            guard let titlebarContainer else { return }
            titlebarContainer.wantsLayer = true
            titlebarContainer.layer?.backgroundColor = titlebarColor.cgColor
        }
    }

    /// Hide the titlebar's NSVisualEffectView once on first `update()` so the
    /// titlebar's background color shows through cleanly. We can't use
    /// `titlebarAppearsTransparent` because that triggers compositing effects
    /// we don't want.
    private var effectViewIsHidden = false

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        // We render the title via the toolbar (centered), so hide the native
        // titlebar text.
        titleVisibility = .hidden

        // Build our centered-title toolbar.
        generateToolbar()

        // Set the background color of the window
        backgroundColor = derivedConfig.backgroundColor

        // This makes sure our titlebar renders correctly when there is a transparent background
        titlebarColor = derivedConfig.backgroundColor.withAlphaComponent(derivedConfig.backgroundOpacity)
    }

    override func becomeKey() {
        super.becomeKey()

        resetZoomToolbarButton.contentTintColor = .controlAccentColor
    }

    override func resignKey() {
        super.resignKey()

        resetZoomToolbarButton.contentTintColor = .tertiaryLabelColor
    }

    override func becomeMain() {
        super.becomeMain()
        updateTitleTextColor()
    }

    override func resignMain() {
        super.resignMain()
        updateTitleTextColor()
    }

    /// Updates the title text color based on the current light/dark theme
    /// and main-window state, ensuring adequate contrast on dark backgrounds.
    private func updateTitleTextColor() {
        guard let toolbar = toolbar as? TerminalToolbar else { return }
        // Use NSWindow.isMainWindow directly instead of the parent class's
        // private viewModel — NSWindow already exposes this as a public API.
        if isLightTheme {
            toolbar.textColor = isMainWindow
                ? NSColor.labelColor
                : NSColor.secondaryLabelColor
        } else {
            toolbar.textColor = isMainWindow
                ? NSColor.white
                : NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        }
    }

    override func update() {
        super.update()

        if !effectViewIsHidden {
            // By hiding the visual effect view, we allow the titlebar's
            // background color to show through. Setting
            // `titlebarAppearsTransparent` would make the system apply a
            // compositing effect we don't want, so we hide the effect view
            // directly instead.
            if let effectView = titlebarContainer?.descendants(
                withClassName: "NSVisualEffectView").first {
                effectView.isHidden = true
            }

            effectViewIsHidden = true
        }
    }

    // MARK: Appearance

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        // override appearance based on the terminal's background color
        if let preferredBackgroundColor {
            appearance = (preferredBackgroundColor.isLightColor ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua))
        }

        // Update our window light/darkness based on our updated background color
        isLightTheme = OSColor(surfaceConfig.backgroundColor).isLightColor

        // Update title text color for contrast on dark backgrounds.
        updateTitleTextColor()

        // Update our titlebar color
        if let preferredBackgroundColor {
            titlebarColor = preferredBackgroundColor
        } else {
            titlebarColor = derivedConfig.backgroundColor.withAlphaComponent(derivedConfig.backgroundOpacity)
        }
    }

    // MARK: - Split Zoom Button

    private lazy var resetZoomToolbarButton: NSButton = generateResetZoomButton()

    private func generateResetZoomButton() -> NSButton {
        let button = NSButton()
        button.target = nil
        button.action = #selector(TerminalController.splitZoom(_:))
        button.isBordered = false
        button.allowsExpansionToolTips = true
        button.toolTip = "Reset Zoom"
        button.contentTintColor = .controlAccentColor
        button.state = .on
        button.image = NSImage(named: "ResetZoom")
        button.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true

        return button
    }

    // MARK: - Titlebar Font

    // Used to set the titlebar font.
    override var titlebarFont: NSFont? {
        didSet {
            guard let toolbar = toolbar as? TerminalToolbar else { return }
            toolbar.titleFont = titlebarFont ?? .titleBarFont(ofSize: NSFont.systemFontSize)
        }
    }

    // MARK: - Title

    override var title: String {
        didSet {
            // Updating the title text as above automatically reveals the
            // native title view in macOS 15.0 and above. Since we're using
            // a custom view instead, we need to re-hide it.
            titleVisibility = .hidden
            if let toolbar = toolbar as? TerminalToolbar {
                toolbar.titleText = title
            }
        }
    }

    // MARK: - Toolbar

    private func generateToolbar() {
        let terminalToolbar = TerminalToolbar(identifier: "Toolbar")

        toolbar = terminalToolbar
        toolbarStyle = .unifiedCompact
        if let resetZoomItem = terminalToolbar.items.first(where: { $0.itemIdentifier == .resetZoom }) {
            resetZoomItem.view = resetZoomToolbarButton
            resetZoomItem.view!.removeConstraints(resetZoomItem.view!.constraints)
            resetZoomItem.view!.widthAnchor.constraint(equalToConstant: 22).isActive = true
            resetZoomItem.view!.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
    }
}

// MARK: Toolbar

// Custom NSToolbar subclass that displays a centered window title.
private class TerminalToolbar: NSToolbar, NSToolbarDelegate {
    private let titleTextField = CenteredDynamicLabel(labelWithString: "👻 Ghostty")

    var titleText: String {
        get {
            titleTextField.stringValue
        }

        set {
            titleTextField.stringValue = newValue
        }
    }

    var titleFont: NSFont? {
        get {
            titleTextField.font
        }

        set {
            titleTextField.font = newValue
        }
    }

    var textColor: NSColor? {
        get {
            titleTextField.textColor
        }

        set {
            titleTextField.textColor = newValue
        }
    }

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)

        delegate = self
        centeredItemIdentifiers.insert(.titleText)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        var item: NSToolbarItem

        switch itemIdentifier {
        case .titleText:
            item = NSToolbarItem(itemIdentifier: .titleText)
            item.view = self.titleTextField
            item.visibilityPriority = .user

            // This ensures the title text field doesn't disappear when shrinking the view
            self.titleTextField.translatesAutoresizingMaskIntoConstraints = false
            self.titleTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            self.titleTextField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

            // Add constraints to the toolbar item's view
            NSLayoutConstraint.activate([
                // Set the height constraint to match the toolbar's height
                self.titleTextField.heightAnchor.constraint(equalToConstant: 22), // Adjust as needed
            ])

            item.isEnabled = true
        case .resetZoom:
            item = NSToolbarItem(itemIdentifier: .resetZoom)
        default:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
        }

        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.titleText, .flexibleSpace, .space, .resetZoom]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // These space items are here to ensure that the title remains centered when it starts
        // getting smaller than the max size so starts clipping. Lucky for us, two of the
        // built-in spacers plus the un-zoom button item seems to exactly match the space
        // on the left that's reserved for the window buttons.
        return [.flexibleSpace, .titleText, .flexibleSpace]
    }
}

/// A label that expands to fit whatever text you put in it and horizontally centers itself in the current window.
private class CenteredDynamicLabel: NSTextField {
    override func viewDidMoveToSuperview() {
        // Configure the text field
        isEditable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true

        // Use Auto Layout
        translatesAutoresizingMaskIntoConstraints = false

        // Set content hugging and compression resistance priorities
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    /// Click through, so we can double click here to enlarge current window
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // Vertically center the text
    override func draw(_ dirtyRect: NSRect) {
        guard let attributedString = self.attributedStringValue.mutableCopy() as? NSMutableAttributedString else {
            super.draw(dirtyRect)
            return
        }

        let textSize = attributedString.size()

        let yOffset = (self.bounds.height - textSize.height) / 2 - 1 // -1 to center it better

        let centeredRect = NSRect(x: self.bounds.origin.x, y: self.bounds.origin.y + yOffset,
                                  width: self.bounds.width, height: textSize.height)

        attributedString.draw(in: centeredRect)
    }
}

extension NSToolbarItem.Identifier {
    static let resetZoom = NSToolbarItem.Identifier("ResetZoom")
    static let titleText = NSToolbarItem.Identifier("TitleText")
}
