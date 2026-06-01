import SwiftUI
import Cocoa

/// A unified tab bar that renders Ghostty's tab list in either a vertical
/// sidebar (used for `tabs-position` left/right) or a horizontal strip
/// (used for `tabs-position` top/bottom).
///
/// The data model is shared across orientations - `TabModel` simply holds
/// a flat list of `NSWindow` entries with assigned colors. Rendering and
/// chrome (resize handle, footer, scroll axis) differ per orientation.
struct TerminalTabBar: View {
    /// The orientation of the tab bar.
    enum Orientation {
        case horizontal
        case vertical
    }

    /// Which edge of the parent the tab bar lives on. Determines which side
    /// the resize handle sits on for vertical bars and which edge gets the
    /// border line for horizontal bars.
    enum Side {
        case top
        case bottom
        case leading
        case trailing
    }

    /// Whether tab color-coding is enabled (read from config by the parent view)
    var tabColorEnabled: Bool

    /// Border color for the selected tab row.
    var selectedBorderColor: Color

    /// The window controller that manages the tabs
    weak var windowController: BaseTerminalController?

    /// Layout configuration.
    ///
    /// `orientation` and `side` are always derived from the same `TabsPosition`
    /// value (e.g. `.left` → `vertical` + `leading`) and can never disagree.
    /// They are kept as separate parameters rather than a single `TabsPosition`
    /// because TerminalTabBar is a SwiftUI view struct — a single enum parameter
    /// would require a `switch` in every layout branch anyway, and the two-field
    /// decomposition lets each branch read its relevant axis directly without
    /// re-deriving it from TabsPosition each time.
    var orientation: Orientation
    var side: Side

    /// The tab data model that tracks all tabs
    @ObservedObject private var tabModel: TabModel

    /// Safety-net timer for refreshing the tab list (5s, only catches stale
    /// state that notifications missed).
    @State private var refreshTimer: Timer?

    /// NotificationCenter observers for event-driven tab refresh. Stored so
    /// we can remove them in onDisappear.
    @State private var notificationObservers: [NSObjectProtocol] = []

    /// For the rename dialog
    @State private var isShowingRenameDialog: Bool = false
    @State private var renameText: String = ""
    @State private var windowToRename: NSWindow?

    /// Sidebar width - persisted in UserDefaults (vertical only)
    @AppStorage("verticalTabSidebarWidth") private var sidebarWidth: Double = 200

    /// Whether we're currently resizing
    @State private var isResizing: Bool = false

    /// Minimum and maximum width constraints
    private let minWidth: CGFloat = 120
    private let maxWidth: CGFloat = 400

    init(
        tabColorEnabled: Bool,
        selectedBorderColor: Color,
        windowController: BaseTerminalController?,
        orientation: Orientation,
        side: Side
    ) {
        self.tabColorEnabled = tabColorEnabled
        self.selectedBorderColor = selectedBorderColor
        self.windowController = windowController
        self.orientation = orientation
        self.side = side
        self._tabModel = ObservedObject(
            wrappedValue: (windowController as? TerminalController)?.tabBarModel ?? TabModel()
        )
    }

    var body: some View {
        Group {
            switch orientation {
            case .vertical:
                verticalBody
            case .horizontal:
                horizontalBody
            }
        }
        .onAppear {
            refreshTabs()
            registerNotificationObservers()
            startRefreshTimer()
        }
        .onDisappear {
            removeNotificationObservers()
            stopRefreshTimer()
        }
        .sheet(isPresented: $isShowingRenameDialog) {
            RenameTabSheet(
                title: $renameText,
                isPresented: $isShowingRenameDialog,
                onSave: {
                    if let window = windowToRename {
                        (window.windowController as? BaseTerminalController)?
                            .titleOverride = renameText.isEmpty ? nil : renameText
                        refreshTabs()
                    }
                }
            )
        }
    }

    // MARK: Vertical Layout (left/right sidebar)

    private var verticalBody: some View {
        HStack(spacing: 0) {
            // Resize handle on the left if sidebar is on the right
            if side == .trailing {
                resizeHandle
            }

            // Main sidebar content
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tabModel.tabs) { tab in
                            tabRowFor(tab)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                // Footer with new tab button
                HStack(spacing: 8) {
                    Button(action: createNewTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("New Tab")

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: sidebarWidth)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            // Resize handle on the right if sidebar is on the left
            if side == .leading {
                resizeHandle
            }
        }
    }

    // MARK: Horizontal Layout (top/bottom strip)

    private var horizontalBody: some View {
        VStack(spacing: 0) {
            // Top border line for bottom-side bars
            if side == .bottom {
                Divider()
            }

            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabModel.tabs) { tab in
                            tabRowFor(tab)
                                .frame(minWidth: 120, idealWidth: 180, maxWidth: 240)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }

                // Trailing footer with new tab button
                Button(action: createNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("New Tab")
                .padding(.horizontal, 12)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            // Bottom border line for top-side bars
            if side == .top {
                Divider()
            }
        }
    }

    // Build a tab row reused by both layouts.
    @ViewBuilder
    private func tabRowFor(_ tab: TabData) -> some View {
        TabRow(
            title: tab.title,
            isSelected: tab.isSelected,
            keyEquivalent: tab.index < 9 ? "\(tab.index + 1)" : nil,
            hasCustomTitle: tab.hasCustomTitle,
            color: tabColorEnabled ? tab.color : nil,
            selectedBorderColor: selectedBorderColor,
            onSelect: {
                selectTab(tab.window)
            },
            onClose: {
                closeTab(tab.window)
            },
            onRename: {
                windowToRename = tab.window
                renameText = tab.titleOverride ?? tab.title
                isShowingRenameDialog = true
            },
            onClearCustomTitle: {
                (tab.window.windowController as? BaseTerminalController)?
                    .titleOverride = nil
                refreshTabs()
            },
            onDragEnded: { screenPoint in
                handleTabDragEnded(window: tab.window, endedAt: screenPoint)
            },
            isVerticalLayout: orientation == .vertical
        )
    }

    /// The resize handle view (vertical-orientation only).
    private var resizeHandle: some View {
        ZStack {
            // Subtle border line
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            // Wider invisible hit area for dragging
            Rectangle()
                .fill(isResizing ? Color.accentColor.opacity(0.3) : Color.clear)
                .frame(width: 6)
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isResizing = true
                    let delta = side == .trailing ? -value.translation.width : value.translation.width
                    let newWidth = sidebarWidth + delta
                    sidebarWidth = min(maxWidth, max(minWidth, newWidth))
                }
                .onEnded { _ in
                    isResizing = false
                }
        )
    }

    // MARK: - Rename Sheet

    struct RenameTabSheet: View {
        @Binding var title: String
        @Binding var isPresented: Bool
        let onSave: () -> Void

        var body: some View {
            VStack(spacing: 16) {
                Text("Rename Tab")
                    .font(.headline)

                TextField("Tab title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit {
                        save()
                    }

                Text("Leave empty to use automatic title")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape)

                    Button("Save", action: save)
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(minWidth: 300)
        }

        private func save() {
            onSave()
            isPresented = false
        }
    }

    // MARK: - Tab Data Model

    /// Generate a tab color for the nth tab using golden-ratio hue spacing.
    /// Saturation and brightness also rotate so adjacent tabs don't feel like
    /// the same color treatment with a different hue.
    private static func tabColor(at index: Int) -> Color {
        let goldenRatioConjugate = 0.618033988749895
        let hue = (Double(index) * goldenRatioConjugate).truncatingRemainder(dividingBy: 1.0)
        let saturations = [1.0, 0.92, 0.78, 0.96, 0.84, 0.70]
        let brightnesses = [0.54, 0.70, 0.46, 0.62, 0.78, 0.50]
        let saturation = saturations[index % saturations.count]
        let brightness = brightnesses[(index / saturations.count + index) % brightnesses.count]
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Represents a single tab's data
    struct TabData: Identifiable {
        let id: ObjectIdentifier
        let window: NSWindow
        let titleOverride: String?
        let title: String
        let index: Int
        let isSelected: Bool
        let color: Color
        let colorIndex: Int
        let hasCustomTitle: Bool

        init(
            window: NSWindow,
            controller: BaseTerminalController?,
            index: Int,
            isSelected: Bool,
            resolvedTitle: String,
            colorIndex: Int
        ) {
            self.window = window
            self.titleOverride = controller?.titleOverride
            self.index = index
            self.isSelected = isSelected
            self.color = TerminalTabBar.tabColor(at: colorIndex)
            self.colorIndex = colorIndex
            self.id = ObjectIdentifier(window)
            self.hasCustomTitle = self.titleOverride != nil
            self.title = self.titleOverride ?? resolvedTitle
        }
    }

    /// Observable model that holds the tab list and shared sidebar state.
    class TabModel: ObservableObject {
        @Published var tabs: [TabData] = []
        /// Persistent generated color index assigned to each window for the session.
        var tabColorIndexes: [ObjectIdentifier: Int] = [:]
        /// Index for the next generated tab color.
        var nextColorIndex: Int = 0

        func colorIndex(for window: NSWindow) -> Int {
            let id = ObjectIdentifier(window)
            if let index = tabColorIndexes[id] {
                return index
            }

            let index = nextColorIndex
            tabColorIndexes[id] = index
            nextColorIndex += 1
            return index
        }
    }

    /// Get the title for a window
    private func resolveTitle(for window: NSWindow, controller: BaseTerminalController?) -> String {
        return controller?.titleOverride ?? window.title
    }

    // MARK: - Tab Row

    struct TabRow: View {
        let title: String
        let isSelected: Bool
        let keyEquivalent: String?
        let hasCustomTitle: Bool
        let color: Color?
        let selectedBorderColor: Color
        let onSelect: () -> Void
        let onClose: () -> Void
        let onRename: () -> Void
        let onClearCustomTitle: () -> Void
        /// Called when a drag of this tab finishes. The point is in screen
        /// coordinates (bottom-left origin), suitable for direct comparison
        /// against `NSWindow.frame`. Layer 8 uses this to drive
        /// drag-to-detach / drag-to-merge behaviors.
        let onDragEnded: (CGPoint) -> Void
        /// Whether the tab bar is vertically oriented. Used to filter
        /// drag direction so that scroll-axis drags (horizontal in a
        /// horizontal bar, vertical in a vertical bar) go to ScrollView
        /// instead of triggering tab detach.
        let isVerticalLayout: Bool

        @State private var isHovering: Bool = false
        /// Visual offset applied while the user is dragging this tab. We use
        /// `.offset` so the tab visually follows the cursor without disturbing
        /// the layout of sibling tabs.
        @State private var dragOffset: CGSize = .zero
        /// Whether this tab is currently being dragged. We dim the tab so
        /// the user gets a visual signal that drag has been recognized.
        @State private var isDragging: Bool = false

        /// Minimum movement before we treat input as a drag, not a click.
        /// Tuned so a sloppy click doesn't accidentally start a tab tear-off.
        private static let dragThreshold: CGFloat = 12

        private var backgroundFill: Color {
            if let c = color {
                return c.opacity(isSelected ? 0.55 : isHovering ? 0.40 : 0.28)
            }
            if isSelected { return Color.accentColor.opacity(0.2) }
            if isHovering { return Color.primary.opacity(0.05) }
            return Color.clear
        }

        private var borderColor: Color {
            guard isSelected else { return Color.clear }
            return selectedBorderColor
        }

        var body: some View {
            HStack(spacing: 6) {
                // Key equivalent badge
                if let keyEquiv = keyEquivalent {
                    Text("⌘\(keyEquiv)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 28)
                }

                // Custom title indicator
                if hasCustomTitle {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor.opacity(0.7))
                }

                // Tab title
                Text(title.isEmpty ? "Ghostty" : title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(isSelected ? .primary : .secondary)

                Spacer()

                // Close button (shown on hover)
                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 2.5 : 0)
            )
            .contentShape(Rectangle())
            // Visual feedback while dragging: offset follows the cursor and
            // the tab is dimmed so the user knows the drag was recognized.
            .offset(dragOffset)
            .opacity(isDragging ? 0.55 : 1.0)
            .onTapGesture {
                onSelect()
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onRename()
                    }
            )
            // Layer 8: tab tear-off / merge drag.
            //
            // - `minimumDistance: dragThreshold` ensures sloppy clicks do not
            //   trigger drag (the .onTapGesture above still fires).
            // - `simultaneousGesture` avoids cancelling the tap gesture chain.
            // - On end, we read `NSEvent.mouseLocation` (screen coordinates,
            //   bottom-left origin) and forward to the parent. The parent
            //   decides whether to no-op, merge into another window's tab
            //   group, or detach into a standalone window.
            .simultaneousGesture(
                DragGesture(minimumDistance: TabRow.dragThreshold)
                    .onChanged { value in
                        // Filter out drags that are primarily in the
                        // scroll-axis direction. In a horizontal bar the
                        // scroll axis is horizontal (X), so we only
                        // activate on vertical drags. In a vertical bar
                        // the scroll axis is vertical (Y), so we only
                        // activate on horizontal drags. This prevents
                        // ScrollView scrolling from accidentally triggering
                        // tab detach.
                        let tx = abs(value.translation.width)
                        let ty = abs(value.translation.height)
                        let isScrollAxisDrag: Bool
                        if isVerticalLayout {
                            // Vertical bar: scroll axis is Y; ignore
                            // primarily-vertical drags
                            isScrollAxisDrag = ty > tx * 1.5
                        } else {
                            // Horizontal bar: scroll axis is X; ignore
                            // primarily-horizontal drags
                            isScrollAxisDrag = tx > ty * 1.5
                        }
                        if isScrollAxisDrag {
                            // Reset drag state so ScrollView handles this
                            isDragging = false
                            dragOffset = .zero
                            return
                        }
                        if !isDragging { isDragging = true }
                        dragOffset = value.translation
                    }
                    .onEnded { _ in
                        // Capture screen point BEFORE we reset state; the
                        // gesture system fires this on the same run loop tick
                        // as the mouseUp so NSEvent.mouseLocation is accurate.
                        let screenPoint = NSEvent.mouseLocation
                        isDragging = false
                        dragOffset = .zero
                        onDragEnded(screenPoint)
                    }
            )
            .onHover { hovering in
                isHovering = hovering
            }
            .contextMenu {
                Button("Rename Tab...") {
                    onRename()
                }
                if hasCustomTitle {
                    Button("Clear Custom Title") {
                        onClearCustomTitle()
                    }
                }
                Divider()
                Button("Close Tab") {
                    onClose()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Actions

    private func refreshTabs() {
        guard let window = windowController?.window else {
            tabModel.tabs = []
            return
        }

        // Get all tabbed windows and the selected one
        let windows: [NSWindow]
        let selectedWindow: NSWindow?

        if let tabGroup = window.tabGroup {
            windows = tabGroup.windows
            selectedWindow = tabGroup.selectedWindow
        } else {
            windows = [window]
            selectedWindow = window
        }

        // If the window list shrank but the "missing" windows are still in our
        // tabGroup, we're in a transitional state (AppKit mid-merge). Skip this
        // tick; the next refresh will have the full list. If the missing windows
        // have left our tabGroup (detach/merge to another window), they are
        // genuinely gone and should be removed from our tab list.
        if !tabModel.tabs.isEmpty && windows.count < tabModel.tabs.count {
            let currentTabGroup = window.tabGroup
            let hasLivingMissingWindow = tabModel.tabs.contains { tab in
                let tabWindow = tab.window
                // Only treat as transitional if the window is still in our
                // tabGroup. If it left (detach/merge), it should be removed.
                return tabWindow.tabGroup == currentTabGroup
            }
            if hasLivingMissingWindow { return }
        }

        // Build the tab data with current titles
        let newTabs = windows.enumerated().map { index, win in
            let controller = win.windowController as? BaseTerminalController
            let resolvedTitle = resolveTitle(for: win, controller: controller)
            let colorIndex = tabModel.colorIndex(for: win)

            return TabData(
                window: win,
                controller: controller,
                index: index,
                isSelected: win == selectedWindow,
                resolvedTitle: resolvedTitle,
                colorIndex: colorIndex
            )
        }

        let changed = newTabs.count != tabModel.tabs.count ||
            zip(newTabs, tabModel.tabs).contains { new, old in
                new.id != old.id ||
                new.isSelected != old.isSelected ||
                new.title != old.title ||
                new.hasCustomTitle != old.hasCustomTitle ||
                new.colorIndex != old.colorIndex
            }

        if changed {
            tabModel.tabs = newTabs
        }
    }

    private func selectTab(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        refreshTabs()
    }

    private func closeTab(_ window: NSWindow) {
        // Route through TerminalController.closeTab so that confirmation
        // prompts (needsConfirmQuit) and undo registration are respected,
        // rather than calling NSWindow.close() directly.
        guard let controller = window.windowController as? TerminalController else {
            window.close()
            return
        }

        controller.closeTab(nil)

        // Refresh after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshTabs()
        }
    }

    private func createNewTab() {
        guard let surface = windowController?.focusedSurface?.surface else { return }
        windowController?.ghostty.newTab(surface: surface)

        // Refresh after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshTabs()
        }
    }

    // MARK: - Layer 8: Drag-to-Detach / Drag-to-Merge

    /// Handle the end of a tab drag.
    ///
    /// Decision tree (in order):
    ///   1. If the source window is full-screen → no-op. Detach during full-
    ///      screen produces weird AppKit behavior; we just refuse cleanly.
    ///   2. If the source window has a single tab (no tab group, or
    ///      `tabGroup.windows.count == 1`) → no-op. Detach would just be the
    ///      window dragging itself, which the user can already do via the
    ///      titlebar.
    ///   3. If the drop point is inside the source window's frame → no-op.
    ///      The user dragged but never left the original window.
    ///   4. If the drop point is inside another visible Ghostty window
    ///      (`BaseTerminalController` controller, not full-screen) → merge:
    ///      add the source window to the target's tab group.
    ///   5. Otherwise → detach: remove the source window from its tab group,
    ///      reposition it so the cursor sits roughly at its center, and bring
    ///      it forward as a standalone window.
    ///
    /// The drop point is in screen coordinates (bottom-left origin), as
    /// returned by `NSEvent.mouseLocation`. This matches `NSWindow.frame`'s
    /// coordinate space so we can compare directly with `frame.contains(_:)`.
    private func handleTabDragEnded(window: NSWindow, endedAt: CGPoint) {
        // (1) Refuse detach for full-screen source windows.
        if window.styleMask.contains(.fullScreen) { return }

        // (2) Single-tab windows have nothing to detach.
        guard let tabGroup = window.tabGroup, tabGroup.windows.count > 1 else {
            return
        }

        // (3) Drag ended inside the source window → no-op.
        // (Note: this also catches the common "drag back into original tab
        // bar" case — which we want to treat as a cancelled drag.)
        if window.frame.contains(endedAt) {
            return
        }

        // (4) Try to merge into another Ghostty window whose frame contains
        // the drop point. We use z-order (front-to-back stacking) rather than
        // NSApp.windows creation order so that if two Ghostty windows overlap,
        // the merge target is the one the user actually sees on top — not a
        // hidden window buried underneath.
        //
        // Strategy: ask AppKit for the topmost window number at the drop point,
        // then check whether that window belongs to Ghostty (has a
        // BaseTerminalController). If it does, use it. If it's a non-Ghostty
        // window (e.g. Finder), walk downward by window number until we find a
        // qualifying Ghostty window, or give up.
        var mergeTarget: NSWindow?
        var candidateNumber = NSWindow.windowNumber(
            at: endedAt,
            belowWindowWithWindowNumber: 0
        )
        // Walk the z-order stack from front to back at the drop point.
        // Each call returns the next window below `candidateNumber`; 0 means
        // no more windows.
        while candidateNumber != 0 {
            if let candidate = NSApp.windows.first(where: {
                $0.windowNumber == candidateNumber
            }) {
                if candidate != window
                    && candidate.windowController is BaseTerminalController
                    && !candidate.styleMask.contains(.fullScreen)
                    && candidate.isVisible
                    && candidate.frame.contains(endedAt) {
                    mergeTarget = candidate
                    break
                }
            }
            candidateNumber = NSWindow.windowNumber(
                at: endedAt,
                belowWindowWithWindowNumber: candidateNumber
            )
        }

        if let target = mergeTarget {
            // Merge into the target's tab group. After this, the source
            // window becomes a tab in the target's group.
            target.addTabbedWindowSafely(window, ordered: .above)
            target.tabGroup?.selectedWindow = window
            // Force a tab list refresh; the timer will catch up within ~500ms
            // anyway, but doing it now keeps the UI snappy.
            refreshTabs()
            return
        }

        // (5) No merge target → detach into a standalone window. We move the
        // window so the cursor sits roughly at its center, then call
        // `tabGroup.removeWindow(_:)` to break it out of the tab group.
        let frame = window.frame
        let newOrigin = CGPoint(
            x: endedAt.x - frame.width / 2,
            y: endedAt.y - frame.height / 2
        )
        window.setFrameOrigin(newOrigin)

        // `removeWindow` detaches `window` from its tab group, leaving it as
        // a standalone NSWindow. The window remains visible/ordered.
        tabGroup.removeWindow(window)
        window.makeKeyAndOrderFront(nil)
        refreshTabs()
    }

    // MARK: - Notification-driven Refresh

    /// Register NotificationCenter observers for events that change the tab
    /// list. This replaces the old 0.5s polling approach with event-driven
    /// updates so N windows no longer burn N timers.
    private func registerNotificationObservers() {
        let center = NotificationCenter.default

        // Tab mutations (move, close, goto)
        let tabMutationNames: [Notification.Name] = [
            .ghosttyMoveTab,
            .ghosttyCloseTab,
            .ghosttyCloseOtherTabs,
            .ghosttyCloseTabsOnTheRight,
            .ghosttyGotoTab,
            .ghosttySetTabsPosition,
        ]

        for name in tabMutationNames {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                refreshTabs()
            }
            notificationObservers.append(observer)
        }

        // Window key-state changes (tab selection)
        let windowNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]

        for name in windowNames {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                refreshTabs()
            }
            notificationObservers.append(observer)
        }

        // Config changes (title override, color settings, etc.)
        let configObserver = center.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main
        ) { _ in
            refreshTabs()
        }
        notificationObservers.append(configObserver)
    }

    /// Remove all NotificationCenter observers registered by
    /// registerNotificationObservers.
    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    // MARK: - Safety-net Timer

    /// 5-second safety-net timer that refreshes tabs in case a notification
    /// was missed. This is a 10x reduction from the previous 0.5s polling
    /// timer while still ensuring the tab list never goes permanently stale.
    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            refreshTabs()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Preview

#if DEBUG
struct TerminalTabBar_Previews: PreviewProvider {
    static var previews: some View {
        TerminalTabBar(
            tabColorEnabled: true,
            selectedBorderColor: Color(red: Double(0x39) / 255, green: 1, blue: Double(0x14) / 255),
            windowController: nil,
            orientation: .vertical,
            side: .leading
        )
            .frame(height: 400)
    }
}
#endif
