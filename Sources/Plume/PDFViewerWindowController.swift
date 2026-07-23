import AppKit
import PDFKit   // On macOS 14 you can import PDFKit directly; `import Quartz`
                // (the umbrella) also works but pulls in ImageKit/QuickLookUI too.

/// PDFView that opens the in-window find bar on Cmd+F. Handling the key
/// equivalent locally — rather than via a global Edit▸Find menu item — keeps
/// the shortcut scoped to PDF windows and leaves the main Messenger window's
/// own Cmd+F behaviour untouched.
private final class FindablePDFView: PDFView {
    var onFind: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" {
            onFind?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Find-bar container whose background follows the light/dark appearance.
/// A plain CGColor snapshot would not re-resolve when the theme changes.
private final class FindBarStack: NSStackView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }
    func applyBackground() {
        wantsLayer = true
        withEffectiveAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
}

/// A standalone native window that renders a downloaded PDF with PDFKit.
///
/// Usage from anywhere (e.g. after a WKDownload finishes):
///
///     PDFViewerWindowController.open(fileURL)
///
/// The controller keeps itself alive (see `Registry`) so the caller does not
/// have to hold a reference; it releases on `windowWillClose`.
final class PDFViewerWindowController: NSWindowController {

    // MARK: - Lifetime / manager pattern

    /// Owns every live viewer so ARC doesn't deallocate the window out from
    /// under the user. Controllers add themselves on load and remove
    /// themselves in `windowWillClose(_:)`. Nothing else retains them.
    private static var registry: [PDFViewerWindowController] = []

    /// The last window frame we placed, used to cascade subsequent windows so
    /// two PDFs don't open exactly on top of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    /// Open (or, if already open for this file, just focus) a viewer for `url`.
    /// Returns the controller in case the caller wants it; safe to ignore.
    @discardableResult
    static func open(_ url: URL) -> PDFViewerWindowController {
        // Re-focus an existing window for the same file instead of duplicating.
        if let existing = registry.first(where: {
            $0.fileURL.standardizedFileURL == url.standardizedFileURL
        }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }

        let controller = PDFViewerWindowController(fileURL: url)
        registry.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    // MARK: - Stored state

    let fileURL: URL
    private let pdfView = FindablePDFView()

    /// Search field lives in a hidden accessory bar toggled by Cmd+F
    /// (via `FindablePDFView`) or the toolbar's Find button.
    private let findBar = FindBarStack()
    private let searchField = NSSearchField()
    private var findBarHeight: NSLayoutConstraint!
    private var searchMatches: [PDFSelection] = []
    private var currentMatchIndex = -1

    // MARK: - Init

    init(fileURL: URL) {
        self.fileURL = fileURL

        // Sensible default size; centred-then-cascaded below.
        let content = NSRect(x: 0, y: 0, width: 800, height: 900)
        let window = NSWindow(
            contentRect: content,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.minSize = NSSize(width: 480, height: 480)
        window.tabbingMode = .disallowed          // each PDF is its own window
        window.isReleasedWhenClosed = false       // ARC + our registry own it

        super.init(window: window)

        window.delegate = self
        cascadeWindow(window)
        buildUI()
        loadDocument()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Window placement

    private func cascadeWindow(_ window: NSWindow) {
        if Self.lastCascadePoint == .zero {
            window.center()
            Self.lastCascadePoint = window.frame.origin
        } else {
            // cascadeTopLeft returns the next point to use.
            let topLeft = NSPoint(x: Self.lastCascadePoint.x + 26,
                                  y: Self.lastCascadePoint.y - 26)
            Self.lastCascadePoint = window.cascadeTopLeft(from: topLeft)
        }
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let window = window else { return }

        // --- PDFView configuration -----------------------------------------
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true                       // fit width, reflow on resize
        pdfView.displayMode = .singlePageContinuous     // vertical scroll of all pages
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true               // gaps + shadow between pages
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = Theme.stateBackground // matches app light/dark surface
        // Pinch-to-zoom and the zoomIn/zoomOut actions are enabled by default;
        // we just bound the range so users can't zoom to uselessness.
        pdfView.maxScaleFactor = 6.0
        pdfView.minScaleFactor = 0.25
        pdfView.onFind = { [weak self] in self?.showFindBar() }   // Cmd+F

        // --- Toolbar --------------------------------------------------------
        let toolbar = NSToolbar(identifier: "PDFViewerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        if #available(macOS 11.0, *) { window.toolbarStyle = .unified }
        window.toolbar = toolbar

        // --- Find bar (hidden until Cmd+F) ----------------------------------
        buildFindBar()

        // --- Layout ---------------------------------------------------------
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(findBar)
        container.addSubview(pdfView)
        window.contentView = container

        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: container.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBarHeight,

            pdfView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Selection-change notification drives find-result highlighting.
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange),
            name: .PDFViewSelectionChanged, object: pdfView)
    }

    private func buildFindBar() {
        findBar.orientation = .horizontal
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        findBar.spacing = 8
        findBar.applyBackground()
        findBar.isHidden = true

        searchField.placeholderString = L.t("Tìm trong tài liệu", "Find in document")
        searchField.target = self
        searchField.action = #selector(performFind(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up",
                                           accessibilityDescription: "Previous")!,
                            target: self, action: #selector(findPrevious))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down",
                                           accessibilityDescription: "Next")!,
                            target: self, action: #selector(findNext))
        let done = NSButton(title: L.t("Xong", "Done"),
                            target: self, action: #selector(hideFindBar))
        for b in [prev, next] { b.bezelStyle = .rounded; b.setButtonType(.momentaryPushIn) }
        done.bezelStyle = .rounded

        findBar.addArrangedSubview(searchField)
        findBar.addArrangedSubview(prev)
        findBar.addArrangedSubview(next)
        findBar.addArrangedSubview(done)
    }

    // MARK: - Document loading & failure handling

    private func loadDocument() {
        // PDFDocument(url:) returns nil for missing/corrupt/encrypted-unreadable
        // files. We never force-unwrap it, so a bad file shows an inline message
        // instead of crashing.
        guard let document = PDFDocument(url: fileURL) else {
            showFailurePlaceholder()
            return
        }
        pdfView.document = document
    }

    private func showFailurePlaceholder() {
        guard let container = window?.contentView else { return }
        pdfView.isHidden = true

        let label = NSTextField(labelWithString: L.t(
            "Không mở được PDF này.\nTệp có thể bị hỏng hoặc không phải PDF hợp lệ.",
            "Couldn't open this PDF.\nThe file may be corrupt or not a valid PDF."))
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.textColor = Theme.textSecondary
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false

        let reveal = NSButton(title: L.t("Hiện trong Finder", "Reveal in Finder"),
                              target: self, action: #selector(revealInFinder))
        reveal.bezelStyle = .rounded
        reveal.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(reveal)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -16),
            reveal.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            reveal.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
        ])
    }

    // MARK: - Actions: Save a Copy

    @objc private func saveCopy(_ sender: Any?) {
        guard let window = window else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileURL.lastPathComponent
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.pdf]
        } else {
            panel.allowedFileTypes = ["pdf"]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: self.fileURL, to: dest)
            } catch {
                self.showError(error)
            }
        }
    }

    // MARK: - Actions: Reveal in Finder

    @objc private func revealInFinder(_ sender: Any? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - Actions: Find (Cmd+F wiring)

    /// Invoked by the toolbar's Find button (and would also serve a standard
    /// Edit ▸ Find menu item, if one is ever added). Cmd+F itself is handled
    /// locally by `FindablePDFView` so it doesn't shadow the main window's
    /// shortcut. Drives our own in-window find bar.
    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .nextMatch:      findNext()
        case .previousMatch:  findPrevious()
        default:              showFindBar()
        }
    }

    /// Enable the Find menu items while this window is key.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performFindPanelAction(_:)) {
            return pdfView.document != nil
        }
        return true
    }

    private func showFindBar() {
        findBar.isHidden = false
        findBarHeight.constant = 40
        window?.makeFirstResponder(searchField)
    }

    @objc private func hideFindBar() {
        findBar.isHidden = true
        findBarHeight.constant = 0
        pdfView.highlightedSelections = nil
        searchMatches = []
        currentMatchIndex = -1
        window?.makeFirstResponder(pdfView)
    }

    @objc private func performFind(_ sender: Any?) {
        guard let document = pdfView.document else { return }
        let query = searchField.stringValue
        pdfView.highlightedSelections = nil
        searchMatches = []
        currentMatchIndex = -1

        guard !query.isEmpty else { return }
        // Synchronous find across the whole document. For very large PDFs you
        // could switch to document.beginFindString(_:withOptions:) which reports
        // matches asynchronously via .PDFDocumentDidFindMatch.
        searchMatches = document.findString(query, withOptions: [.caseInsensitive])
        pdfView.highlightedSelections = searchMatches.isEmpty ? nil : searchMatches
        if !searchMatches.isEmpty { advanceMatch(by: 1) }
    }

    @objc private func findNext() { advanceMatch(by: 1) }
    @objc private func findPrevious() { advanceMatch(by: -1) }

    private func advanceMatch(by delta: Int) {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + delta + searchMatches.count) % searchMatches.count
        let match = searchMatches[currentMatchIndex]
        pdfView.setCurrentSelection(match, animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    @objc private func selectionDidChange(_ note: Notification) {
        // Keep the coloured highlights visible even as the current selection
        // (the "active" match) moves; nothing extra needed here today, but this
        // hook is where you'd update a "3 of 12" match counter label.
    }

    // MARK: - Actions: Zoom (toolbar) — PDFView provides these for free

    @objc private func zoomIn(_ sender: Any?)  { pdfView.zoomIn(sender) }
    @objc private func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc private func actualSize(_ sender: Any?) {
        // autoScales must be off first, or setting scaleFactor is discarded
        // when PDFView re-fits to the view.
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
    }

    // MARK: - Error presentation

    private func showError(_ error: Error) {
        guard let window = window else { NSAlert(error: error).runModal(); return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}

// MARK: - NSWindowDelegate (lifetime release)

extension PDFViewerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        // Drop our self-reference so ARC can deallocate the controller (and the
        // window it owns). This is what prevents the leak.
        Self.registry.removeAll { $0 === self }
    }
}

// MARK: - NSToolbarDelegate

extension PDFViewerWindowController: NSToolbarDelegate {

    private static let saveItemID   = NSToolbarItem.Identifier("pdf.saveCopy")
    private static let revealItemID = NSToolbarItem.Identifier("pdf.reveal")
    private static let findItemID   = NSToolbarItem.Identifier("pdf.find")
    private static let zoomItemID   = NSToolbarItem.Identifier("pdf.zoom")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.zoomItemID, .flexibleSpace, Self.findItemID,
         Self.revealItemID, Self.saveItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.saveItemID:
            return button(id, symbol: "square.and.arrow.down",
                          label: L.t("Lưu bản sao", "Save a Copy"),
                          action: #selector(saveCopy(_:)))
        case Self.revealItemID:
            return button(id, symbol: "folder",
                          label: L.t("Hiện trong Finder", "Reveal in Finder"),
                          action: #selector(revealInFinder(_:)))
        case Self.findItemID:
            return button(id, symbol: "magnifyingglass",
                          label: L.t("Tìm", "Find"),
                          action: #selector(performFindPanelAction(_:)))
        case Self.zoomItemID:
            return zoomSegmentedItem(id)
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, symbol: String,
                        label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    private func zoomSegmentedItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let seg = NSSegmentedControl(labels: ["−", "1:1", "+"],
                                     trackingMode: .momentary,
                                     target: self, action: #selector(zoomSegmentChanged(_:)))
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = seg
        item.label = L.t("Thu phóng", "Zoom")
        return item
    }

    @objc private func zoomSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: zoomOut(sender)
        case 1: actualSize(sender)
        default: zoomIn(sender)
        }
    }
}
