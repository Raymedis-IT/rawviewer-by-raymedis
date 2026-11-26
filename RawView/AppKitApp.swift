import AppKit
import Foundation
import UniformTypeIdentifiers

@main
enum RawViewApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        mainWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if let contentView = controller.window?.contentView { controller.window?.makeFirstResponder(contentView) }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { controller.window?.toggleFullScreen(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class ViewerModel {
    var files: [URL] = []
    var selectedIndex = 0
    var currentFrame: RawFrame?
    var previewData: Data?
    var thumbnailCache: [URL: Data] = [:]
    var settings = RawSettings()
    var windowCenter = 32768.0
    var windowWidth = 65535.0
    var inverted = false
    var quarterTurns = 0
    var isLoading = false
    var errorMessage: String?
    var exportFolder: URL?
    var isExporting = false
    var exportProgress = 0.0
    var exportMessage: String?
    private var observers: [UUID: () -> Void] = [:]

    private var renderWork: DispatchWorkItem?
    private var renderGeneration = 0
    private var loadGeneration = 0
    private var thumbnailRequests = Set<URL>()
    private let thumbnailQueue = DispatchQueue(label: "com.rxview.rawviewer.thumbnails", qos: .utility)
    private var inputScopes: [URL] = []
    private var exportScope: URL?

    var currentURL: URL? { files.indices.contains(selectedIndex) ? files[selectedIndex] : nil }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.title = "Open RAW images"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "raw") ?? .data]
        guard panel.runModal() == .OK else { return }
        replaceFiles(panel.urls)
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open a folder of RAW images"
        panel.prompt = "Open Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        loadFolder(folder)
    }

    func openDroppedItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1,
           (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            loadFolder(urls[0])
            return
        }
        let rawFiles = urls.filter { $0.pathExtension.lowercased() == "raw" }
        guard !rawFiles.isEmpty else {
            errorMessage = "Drop .raw images or one folder containing .raw images."
            notify()
            return
        }
        replaceFiles(rawFiles)
    }

    private func loadFolder(_ folder: URL) {
        replaceFiles([], scopedFolder: folder)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            let rawFiles = urls.filter { $0.pathExtension.lowercased() == "raw" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            DispatchQueue.main.async {
                guard let self else { return }
                self.files = rawFiles
                self.selectedIndex = 0
                self.errorMessage = rawFiles.isEmpty ? "No .raw images were found in that folder." : nil
                if !rawFiles.isEmpty { self.select(0) } else { self.notify() }
            }
        }
    }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose an export folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportScope?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        exportScope = url
        exportFolder = url
        notify()
    }

    func replaceFiles(_ urls: [URL], scopedFolder: URL? = nil) {
        inputScopes.forEach { $0.stopAccessingSecurityScopedResource() }
        inputScopes.removeAll()
        if let scopedFolder {
            _ = scopedFolder.startAccessingSecurityScopedResource()
            inputScopes.append(scopedFolder)
        } else {
            urls.forEach { if $0.startAccessingSecurityScopedResource() { inputScopes.append($0) } }
        }
        files = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        selectedIndex = 0
        currentFrame = nil
        previewData = nil
        thumbnailCache.removeAll()
        thumbnailRequests.removeAll()
        errorMessage = nil
        if !files.isEmpty { select(0) } else { notify() }
    }

    func select(_ index: Int) {
        guard files.indices.contains(index) else { return }
        selectedIndex = index
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        currentFrame = nil
        previewData = nil
        errorMessage = nil
        let url = files[index]
        let settings = self.settings
        notify()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let frame = try RawReader.read(url: url, settings: settings)
                let preview = try frame.displayPNG()
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation else { return }
                    self.currentFrame = frame
                    self.previewData = preview
                    self.windowCenter = frame.displayWindow.center
                    self.windowWidth = frame.displayWindow.width
                    self.isLoading = false
                    self.notify()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation else { return }
                    self.currentFrame = nil
                    self.previewData = nil
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    self.notify()
                }
            }
        }
    }

    func selectNext() { if selectedIndex + 1 < files.count { select(selectedIndex + 1) } }
    func selectPrevious() { if selectedIndex > 0 { select(selectedIndex - 1) } }

    @discardableResult
    func observe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func reload() {
        guard !files.isEmpty else { return }
        select(selectedIndex)
    }

    func loadThumbnail(for url: URL) {
        guard thumbnailCache[url] == nil, !thumbnailRequests.contains(url) else { return }
        thumbnailRequests.insert(url)
        let settings = self.settings
        thumbnailQueue.async { [weak self] in
            let png = try? RawReader.read(url: url, settings: settings).thumbnailPNG(maxDimension: 132)
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnailRequests.remove(url)
                if let png { self.thumbnailCache[url] = png; self.notify() }
            }
        }
    }

    func setWindow(center: Double? = nil, width: Double? = nil) {
        if let center { windowCenter = center }
        if let width { windowWidth = width }
        renderPreview()
    }

    func toggleInvert() { inverted.toggle(); renderPreview() }
    func rotate() { quarterTurns = (quarterTurns + 1) % 4; notify() }

    func resetImageControls() {
        if let currentFrame {
            windowCenter = currentFrame.displayWindow.center
            windowWidth = currentFrame.displayWindow.width
        }
        inverted = false
        quarterTurns = 0
        renderPreview()
    }

    func export(format: ExportFormat, allImages: Bool) {
        guard let folder = exportFolder, !files.isEmpty, !isExporting else { return }
        let targets = allImages ? files : (currentURL.map { [$0] } ?? [])
        guard !targets.isEmpty else { return }
        let settings = self.settings
        let selectedWindow = DisplayWindow(center: windowCenter, width: windowWidth)
        let selectedInvert = inverted
        let studyUID = makeUID()
        let seriesUID = makeUID()
        let uniqueNames = outputNames(for: targets, format: format)
        isExporting = true
        exportProgress = 0
        exportMessage = "Preparing export…"
        errorMessage = nil
        notify()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                for (index, url) in targets.enumerated() {
                    let frame = try RawReader.read(url: url, settings: settings)
                    let window = allImages ? frame.displayWindow : selectedWindow
                    let destination = folder.appendingPathComponent(uniqueNames[index])
                    try RawExporter.write(frame, to: destination, format: format, window: window,
                                          inverted: selectedInvert, studyUID: studyUID, seriesUID: seriesUID,
                                          instanceNumber: index + 1)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.exportProgress = Double(index + 1) / Double(targets.count)
                        self.exportMessage = "Saved \(index + 1) of \(targets.count)"
                        self.notify()
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isExporting = false
                    self.exportMessage = "Exported \(targets.count) image\(targets.count == 1 ? "" : "s")."
                    self.notify()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isExporting = false
                    self.errorMessage = error.localizedDescription
                    self.exportMessage = "Export stopped."
                    self.notify()
                }
            }
        }
    }

    private func renderPreview() {
        guard let frame = currentFrame else { return }
        renderWork?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let window = DisplayWindow(center: windowCenter, width: windowWidth)
        let invert = inverted
        let work = DispatchWorkItem { [weak self] in
            let data = try? frame.displayPNG(window: window, inverted: invert)
            DispatchQueue.main.async {
                guard let self, self.renderGeneration == generation else { return }
                if let data { self.previewData = data }
                self.notify()
            }
        }
        renderWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.025, execute: work)
        notify()
    }

    private func outputNames(for urls: [URL], format: ExportFormat) -> [String] {
        let bases = urls.map { $0.deletingPathExtension().lastPathComponent }
        let counts = Dictionary(grouping: bases, by: { $0 }).mapValues(\.count)
        return urls.map { url in
            let base = url.deletingPathExtension().lastPathComponent
            let prefix = (counts[base] ?? 0) > 1 ? url.deletingLastPathComponent().lastPathComponent + "_" : ""
            return prefix + base + "." + format.fileExtension
        }
    }

    private func makeUID() -> String { "2.25.\(UInt64.random(in: 1...UInt64.max))" }
    private func notify() { observers.values.forEach { $0() } }
}

@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let model = ViewerModel()
    private let root = KeyboardRootView(frame: .zero)
    private let galleryTable = NSTableView()
    private let imageView = AspectFitImageBox(frame: .zero)
    private let openFilesEmptyButton = NSButton()
    private let openFolderEmptyButton = NSButton()
    private let emptyPrompt = NSStackView()
    private let emptyTitleLabel = NSTextField(labelWithString: "Open RAW images")
    private let emptySubtitleLabel = NSTextField(labelWithString: "Click anywhere, drop RAW files, or choose a source.")
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let zoomDisplay = NSView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let galleryCountLabel = NSTextField(labelWithString: "")
    private let levelSlider = NSSlider(value: 32768, minValue: 0, maxValue: 65535, target: nil, action: nil)
    private let widthSlider = NSSlider(value: 65535, minValue: 1, maxValue: 65535, target: nil, action: nil)
    private let levelLabel = controlLabel("LEVEL")
    private let widthLabel = controlLabel("WIDTH")
    private let levelValue = NSTextField(labelWithString: "")
    private let widthValue = NSTextField(labelWithString: "")
    private let invertButton = NSButton(title: "", target: nil, action: nil)
    private var lastSelectedRow = -1
    private var lastFiles: [URL] = []
    private var lastDisplayedURL: URL?
    private let loadingIndicator = NSProgressIndicator()
    private var exportController: ExportWindowController?
    private var modelObserver: UUID?
    private var keyboardMonitor: Any?

    deinit {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }

    init() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initialSize = NSSize(width: visibleFrame.width, height: visibleFrame.height)
        let window = NSWindow(contentRect: visibleFrame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.setFrame(visibleFrame, display: false)
        window.title = "RAW Viewer by Raymedis"
        window.minSize = NSSize(width: min(900, initialSize.width), height: min(580, initialSize.height))
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = AppColors.background
        super.init(window: window)
        buildInterface()
        modelObserver = model.observe { [weak self] in self?.updateInterface() }
        root.onNavigate = { [weak self] keyCode in self?.handleArrowKey(keyCode) ?? false }
        window.contentView = root
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleArrowKey(event.keyCode) ? nil : event
        }
        updateInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        root.wantsLayer = true
        root.layer?.backgroundColor = AppColors.background.cgColor
        let header = buildHeader()
        let content = buildContent()
        root.addSubview(header)
        root.addSubview(content)
        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 64),
            content.topAnchor.constraint(equalTo: header.bottomAnchor), content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func buildHeader() -> NSView {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = AppColors.background.cgColor
        let title = NSTextField(labelWithString: "RAW Viewer")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = AppColors.primaryText
        let logo = NSImageView()
        if let logoURL = Bundle.main.url(forResource: "RaymedisLogo", withExtension: "png") {
            logo.image = NSImage(contentsOf: logoURL)
        }
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("Raymedis")
        logo.translatesAutoresizingMaskIntoConstraints = false
        let branding = horizontalStack([title, logo], spacing: 12)
        let openFiles = button("Open files", symbol: "doc.badge.plus", action: #selector(openFiles))
        openFiles.target = self
        let openFolder = button("Open folder", symbol: "folder", action: #selector(openFolder))
        openFolder.target = self
        let settings = iconButton("slider.horizontal.3", tooltip: "RAW format settings", action: #selector(openSettings))
        settings.target = self
        let export = button("Export", symbol: "square.and.arrow.up", accent: true, action: #selector(openExport))
        export.target = self
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([branding, spacer, settings, openFiles, openFolder, export], spacing: 10)
        header.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 126), logo.heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20), row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        addHairline(to: header, atBottom: true)
        return header
    }

    private func buildContent() -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = AppColors.imageField.cgColor
        let sidebar = buildGallery()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let viewer = buildViewer()
        viewer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        content.addSubview(viewer)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.20),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 176),
            sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 270),
            viewer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            viewer.topAnchor.constraint(equalTo: content.topAnchor), viewer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        return content
    }

    private func buildGallery() -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = AppColors.panel.cgColor
        let heading = NSTextField(labelWithString: "IMAGES")
        heading.font = .systemFont(ofSize: 10, weight: .bold)
        heading.textColor = AppColors.secondaryText
        galleryCountLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        galleryCountLabel.textColor = AppColors.secondaryText
        let top = horizontalStack([heading, flexibleSpace(), galleryCountLabel], spacing: 8)
        panel.addSubview(top)
        top.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        galleryTable.headerView = nil
        galleryTable.backgroundColor = AppColors.panel
        galleryTable.rowHeight = 70
        galleryTable.intercellSpacing = NSSize(width: 0, height: 3)
        galleryTable.selectionHighlightStyle = .none
        galleryTable.frame = scroll.contentView.bounds
        galleryTable.autoresizingMask = [.width]
        galleryTable.dataSource = self
        galleryTable.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("raw-file"))
        column.width = 200
        column.minWidth = 150
        column.maxWidth = 600
        galleryTable.addTableColumn(column)
        galleryTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = galleryTable
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14), top.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            top.topAnchor.constraint(equalTo: panel.topAnchor, constant: 15), top.heightAnchor.constraint(equalToConstant: 16),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
        addHairline(to: panel, atBottom: false, trailing: true)
        return panel
    }

    private func buildViewer() -> NSView {
        let viewer = NSView()
        viewer.wantsLayer = true
        viewer.layer?.backgroundColor = AppColors.imageField.cgColor

        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = AppColors.panel.cgColor
        filenameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        filenameLabel.textColor = AppColors.primaryText
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = AppColors.secondaryText
        let labels = verticalStack([filenameLabel, detailLabel], spacing: 3)
        let fit = iconButton("arrow.up.left.and.arrow.down.right", tooltip: "Fit image to window", action: #selector(fitImage))
        fit.target = self
        let zoomOut = iconButton("minus.magnifyingglass", tooltip: "Zoom out", action: #selector(zoomOut))
        zoomOut.target = self
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        zoomLabel.textColor = AppColors.secondaryText
        zoomLabel.alignment = .center
        zoomLabel.maximumNumberOfLines = 1
        zoomDisplay.wantsLayer = true
        zoomDisplay.layer?.cornerRadius = 8
        zoomDisplay.layer?.backgroundColor = AppColors.panelRaised.cgColor
        zoomDisplay.layer?.borderWidth = 1
        zoomDisplay.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        zoomDisplay.addSubview(zoomLabel)
        zoomDisplay.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            zoomDisplay.widthAnchor.constraint(equalToConstant: 36),
            zoomDisplay.heightAnchor.constraint(equalToConstant: 36),
            zoomLabel.centerXAnchor.constraint(equalTo: zoomDisplay.centerXAnchor),
            zoomLabel.centerYAnchor.constraint(equalTo: zoomDisplay.centerYAnchor),
            zoomLabel.leadingAnchor.constraint(greaterThanOrEqualTo: zoomDisplay.leadingAnchor, constant: 1),
            zoomLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomDisplay.trailingAnchor, constant: -1)
        ])
        imageView.onZoomChanged = { [weak self] factor in
            guard let self else { return }
            self.zoomLabel.stringValue = "\(Int((factor * 100).rounded()))%"
        }
        let zoomIn = iconButton("plus.magnifyingglass", tooltip: "Zoom in", action: #selector(zoomIn))
        zoomIn.target = self
        let rotate = iconButton("rotate.right", tooltip: "Rotate 90 degrees", action: #selector(rotateImage))
        rotate.target = self
        invertButton.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Invert grayscale")
        invertButton.imagePosition = .imageOnly
        invertButton.target = self
        invertButton.action = #selector(toggleInvert)
        invertButton.toolTip = "Invert grayscale"
        invertButton.setAccessibilityLabel("Invert grayscale")
        invertButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        styleButton(invertButton, iconOnly: true)
        invertButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let reset = iconButton("arrow.counterclockwise", tooltip: "Reset image adjustments", action: #selector(resetControls))
        reset.target = self
        let previous = iconButton("chevron.up", tooltip: "Previous image (↑ or ←)", action: #selector(previousImage))
        previous.target = self
        let next = iconButton("chevron.down", tooltip: "Next image (↓ or →)", action: #selector(nextImage))
        next.target = self
        let controls = horizontalStack([fit, zoomOut, zoomDisplay, zoomIn, rotate, invertButton, reset, previous, next], spacing: 5)
        toolbar.addSubview(labels)
        toolbar.addSubview(controls)
        labels.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 18), labels.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14), controls.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -10)
        ])

        let imageField = ImportCanvasView(frame: .zero)
        imageField.wantsLayer = true
        imageField.layer?.backgroundColor = AppColors.imageField.cgColor
        imageField.isEmptyState = { [weak self] in self?.model.files.isEmpty == true }
        imageField.onEmptyClick = { [weak self] in
            guard let self, self.model.files.isEmpty, !self.model.isLoading else { return false }
            self.model.openFiles()
            return true
        }
        imageField.onDrop = { [weak self] urls in self?.model.openDroppedItems(urls) }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageField.addSubview(imageView)
        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)!)
        emptyIcon.contentTintColor = AppColors.accent
        emptyTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyTitleLabel.textColor = AppColors.primaryText
        emptySubtitleLabel.font = .systemFont(ofSize: 12)
        emptySubtitleLabel.textColor = AppColors.secondaryText
        openFilesEmptyButton.title = "Open files"
        openFilesEmptyButton.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Open RAW files")
        openFilesEmptyButton.imagePosition = .imageLeading
        openFilesEmptyButton.target = self
        openFilesEmptyButton.action = #selector(openFiles)
        styleButton(openFilesEmptyButton, accent: true)
        openFolderEmptyButton.title = "Open folder"
        openFolderEmptyButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open RAW folder")
        openFolderEmptyButton.imagePosition = .imageLeading
        openFolderEmptyButton.target = self
        openFolderEmptyButton.action = #selector(openFolder)
        styleButton(openFolderEmptyButton)
        let emptyActions = horizontalStack([openFilesEmptyButton, openFolderEmptyButton], spacing: 9)
        emptyPrompt.orientation = .vertical
        emptyPrompt.alignment = .centerX
        emptyPrompt.distribution = .fill
        emptyPrompt.spacing = 11
        emptyPrompt.addArrangedSubview(emptyIcon)
        emptyPrompt.addArrangedSubview(emptyTitleLabel)
        emptyPrompt.addArrangedSubview(emptySubtitleLabel)
        emptyPrompt.addArrangedSubview(emptyActions)
        imageField.addSubview(emptyPrompt)
        emptyPrompt.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isDisplayedWhenStopped = false
        imageField.addSubview(loadingIndicator)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: imageField.leadingAnchor, constant: 22),
            imageView.trailingAnchor.constraint(equalTo: imageField.trailingAnchor, constant: -22),
            imageView.topAnchor.constraint(equalTo: imageField.topAnchor, constant: 18),
            imageView.bottomAnchor.constraint(equalTo: imageField.bottomAnchor, constant: -18),
            emptyIcon.widthAnchor.constraint(equalToConstant: 39), emptyIcon.heightAnchor.constraint(equalToConstant: 39),
            emptyPrompt.centerXAnchor.constraint(equalTo: imageField.centerXAnchor), emptyPrompt.centerYAnchor.constraint(equalTo: imageField.centerYAnchor),
            emptyPrompt.leadingAnchor.constraint(greaterThanOrEqualTo: imageField.leadingAnchor, constant: 20),
            emptyPrompt.trailingAnchor.constraint(lessThanOrEqualTo: imageField.trailingAnchor, constant: -20),
            loadingIndicator.centerXAnchor.constraint(equalTo: imageField.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: imageField.centerYAnchor)
        ])

        let controlsView = buildWindowControls()
        controlsView.wantsLayer = true
        controlsView.layer?.backgroundColor = AppColors.panel.cgColor
        let status = NSView()
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = AppColors.secondaryText
        status.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -18),
            statusLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor), status.heightAnchor.constraint(equalToConstant: 30)
        ])

        [toolbar, imageField, controlsView, status].forEach { viewer.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: viewer.topAnchor), toolbar.leadingAnchor.constraint(equalTo: viewer.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), toolbar.heightAnchor.constraint(equalToConstant: 54),
            imageField.topAnchor.constraint(equalTo: toolbar.bottomAnchor), imageField.leadingAnchor.constraint(equalTo: viewer.leadingAnchor),
            imageField.trailingAnchor.constraint(equalTo: viewer.trailingAnchor),
            controlsView.topAnchor.constraint(equalTo: imageField.bottomAnchor), controlsView.leadingAnchor.constraint(equalTo: viewer.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), controlsView.heightAnchor.constraint(equalToConstant: 74),
            status.topAnchor.constraint(equalTo: controlsView.bottomAnchor), status.leadingAnchor.constraint(equalTo: viewer.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), status.bottomAnchor.constraint(equalTo: viewer.bottomAnchor),
            imageField.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        addHairline(to: toolbar, atBottom: true)
        addHairline(to: status, atBottom: false)
        return viewer
    }

    private func buildWindowControls() -> NSView {
        let container = NSView()
        levelSlider.toolTip = "Focus this slider, then use ↑ or ← to lower Level and ↓ or → to raise it."
        widthSlider.toolTip = "Focus this slider, then use ↑ or ← to lower Width and ↓ or → to raise it."
        levelValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        widthValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        levelValue.textColor = AppColors.secondaryText
        widthValue.textColor = AppColors.secondaryText
        levelSlider.target = self
        levelSlider.action = #selector(levelChanged)
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        levelSlider.isContinuous = true
        widthSlider.isContinuous = true
        levelSlider.trackFillColor = AppColors.accent
        widthSlider.trackFillColor = AppColors.accent
        let first = horizontalStack([levelLabel, levelSlider, levelValue], spacing: 9)
        let second = horizontalStack([widthLabel, widthSlider, widthValue], spacing: 9)
        [first, second].forEach { container.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            levelLabel.widthAnchor.constraint(equalToConstant: 42), widthLabel.widthAnchor.constraint(equalToConstant: 42),
            levelValue.widthAnchor.constraint(equalToConstant: 48), widthValue.widthAnchor.constraint(equalToConstant: 48),
            first.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 19), first.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -19),
            first.topAnchor.constraint(equalTo: container.topAnchor, constant: 13), first.heightAnchor.constraint(equalToConstant: 20),
            second.leadingAnchor.constraint(equalTo: first.leadingAnchor), second.trailingAnchor.constraint(equalTo: first.trailingAnchor),
            second.topAnchor.constraint(equalTo: first.bottomAnchor, constant: 7), second.heightAnchor.constraint(equalToConstant: 20)
        ])
        return container
    }

    private func updateInterface() {
        galleryCountLabel.stringValue = "\(model.files.count)"
        if lastFiles != model.files {
            lastFiles = model.files
            lastSelectedRow = -1
        }
        galleryTable.reloadData()
        if lastSelectedRow != model.selectedIndex {
            lastSelectedRow = model.selectedIndex
            if model.files.indices.contains(model.selectedIndex) {
                galleryTable.selectRowIndexes(IndexSet(integer: model.selectedIndex), byExtendingSelection: false)
                galleryTable.scrollRowToVisible(model.selectedIndex)
            } else {
                galleryTable.deselectAll(nil)
            }
        }
        if let url = model.currentURL {
            filenameLabel.stringValue = url.lastPathComponent
        } else {
            filenameLabel.stringValue = ""
        }
        if let frame = model.currentFrame {
            detailLabel.stringValue = "\(frame.width) × \(frame.height)   ·   \(frame.bitDepth)-bit   ·   \(model.selectedIndex + 1) of \(model.files.count)"
            levelSlider.maxValue = Double(frame.maximum)
            widthSlider.maxValue = Double(frame.maximum)
            widthSlider.minValue = 1
            levelSlider.doubleValue = model.windowCenter
            widthSlider.doubleValue = model.windowWidth
            levelValue.stringValue = String(Int(model.windowCenter.rounded()))
            widthValue.stringValue = String(Int(model.windowWidth.rounded()))
            invertButton.layer?.backgroundColor = model.inverted ? AppColors.accent.withAlphaComponent(0.45).cgColor : AppColors.panelRaised.cgColor
        } else {
            detailLabel.stringValue = ""
        }
        let selectedURL = model.currentURL
        let imageChanged = selectedURL != lastDisplayedURL
        lastDisplayedURL = selectedURL
        let preview = model.previewData.flatMap { NSImage(data: $0) }.map(rotatedImage)
        imageView.setImage(preview, resetZoom: imageChanged)
        zoomLabel.stringValue = "\(Int((imageView.zoomFactor * 100).rounded()))%"
        if let message = model.errorMessage {
            emptyTitleLabel.stringValue = "Could not open this RAW image"
            emptySubtitleLabel.stringValue = message
        } else {
            emptyTitleLabel.stringValue = "Open RAW images"
            emptySubtitleLabel.stringValue = "Click anywhere, drop RAW files, or choose a source."
        }
        emptyPrompt.isHidden = model.previewData != nil || model.isLoading
        model.isLoading ? loadingIndicator.startAnimation(nil) : loadingIndicator.stopAnimation(nil)
        if model.isLoading { statusLabel.stringValue = "Reading RAW image…" }
        else if let message = model.errorMessage { statusLabel.stringValue = message }
        else { statusLabel.stringValue = model.exportMessage ?? "" }
        root.needsLayout = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.files.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("gallery-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? GalleryItemView) ?? GalleryItemView(frame: .zero)
        cell.identifier = identifier
        cell.configure(url: model.files[row], number: row + 1)
        cell.setSelected(row == model.selectedIndex)
        if let image = model.thumbnailCache[model.files[row]] { cell.setThumbnail(image) }
        else { model.loadThumbnail(for: model.files[row]) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = galleryTable.selectedRow
        if model.files.indices.contains(row), model.selectedIndex != row { model.select(row) }
    }

    private func rotatedImage(_ image: NSImage) -> NSImage {
        guard model.quarterTurns != 0 else { return image }
        let swapsAxes = model.quarterTurns % 2 == 1
        let outputSize = swapsAxes ? NSSize(width: image.size.height, height: image.size.width) : image.size
        let output = NSImage(size: outputSize)
        output.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else { output.unlockFocus(); return image }
        context.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
        context.rotate(by: CGFloat(model.quarterTurns) * .pi / 2)
        image.draw(in: NSRect(x: -image.size.width / 2, y: -image.size.height / 2,
                              width: image.size.width, height: image.size.height))
        output.unlockFocus()
        return output
    }

    @objc private func openFiles() { model.openFiles() }
    @objc private func openFolder() { model.openFolder() }
    @objc private func previousImage() { window?.makeFirstResponder(root); model.selectPrevious() }
    @objc private func nextImage() { window?.makeFirstResponder(root); model.selectNext() }
    @objc private func fitImage() {
        imageView.fitToWindow()
    }
    @objc private func zoomIn() { imageView.zoomIn() }
    @objc private func zoomOut() { imageView.zoomOut() }
    @objc private func rotateImage() { model.rotate() }
    @objc private func toggleInvert() { model.toggleInvert() }
    @objc private func resetControls() { model.resetImageControls() }
    @objc private func levelChanged() { model.setWindow(center: levelSlider.doubleValue) }
    @objc private func widthChanged() { model.setWindow(width: widthSlider.doubleValue) }

    private func handleArrowKey(_ keyCode: UInt16) -> Bool {
        guard let window else { return false }

        if window.firstResponder === levelSlider || window.firstResponder === widthSlider {
            let decrement = keyCode == 126 || keyCode == 123
            let increment = keyCode == 125 || keyCode == 124
            guard decrement || increment else { return false }
            let direction = decrement ? -1.0 : 1.0
            if window.firstResponder === levelSlider {
                let step = max(1, levelSlider.maxValue / 100)
                levelSlider.doubleValue = min(levelSlider.maxValue, max(levelSlider.minValue, levelSlider.doubleValue + direction * step))
                model.setWindow(center: levelSlider.doubleValue)
            } else {
                let step = max(1, widthSlider.maxValue / 100)
                widthSlider.doubleValue = min(widthSlider.maxValue, max(widthSlider.minValue, widthSlider.doubleValue + direction * step))
                model.setWindow(width: widthSlider.doubleValue)
            }
            return true
        }

        switch keyCode {
        case 126, 123: model.selectPrevious(); return true
        case 125, 124: model.selectNext(); return true
        default: return false
        }
    }

    @objc private func openSettings() {
        let alert = NSAlert()
        alert.messageText = "RAW format settings"
        alert.informativeText = "Auto detects 8 or 16 bit pixels and a 0 or 200 byte header from file size."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let widthField = NSTextField(string: String(model.settings.width))
        let heightField = NSTextField(string: String(model.settings.height))
        let depthPopup = NSPopUpButton()
        RawSettings.BitDepth.allCases.forEach { depthPopup.addItem(withTitle: $0.rawValue) }
        depthPopup.selectItem(withTitle: model.settings.bitDepth.rawValue)
        let headerPopup = NSPopUpButton()
        RawSettings.HeaderSize.allCases.forEach { headerPopup.addItem(withTitle: $0.rawValue) }
        headerPopup.selectItem(withTitle: model.settings.header.rawValue)
        let fields = verticalStack([
            horizontalStack([controlLabel("Width"), widthField], spacing: 8),
            horizontalStack([controlLabel("Height"), heightField], spacing: 8),
            horizontalStack([controlLabel("Pixel depth"), depthPopup], spacing: 8),
            horizontalStack([controlLabel("Header"), headerPopup], spacing: 8)
        ], spacing: 8)
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 116)
        alert.accessoryView = fields
        if alert.runModal() == .alertFirstButtonReturn {
            if let width = Int(widthField.stringValue), let height = Int(heightField.stringValue), width > 0, height > 0 {
                model.settings.width = width
                model.settings.height = height
                model.settings.bitDepth = RawSettings.BitDepth(rawValue: depthPopup.titleOfSelectedItem ?? "Auto") ?? .automatic
                model.settings.header = RawSettings.HeaderSize(rawValue: headerPopup.titleOfSelectedItem ?? "Auto") ?? .automatic
                model.reload()
            }
        }
    }

    @objc private func openExport() {
        let controller = ExportWindowController(model: model)
        exportController = controller
        if let child = controller.window, let parent = window {
            parent.beginSheet(child, completionHandler: nil)
        }
    }
}

@MainActor
final class ExportWindowController: NSWindowController {
    private let model: ViewerModel
    private let formatPopup = NSPopUpButton()
    private let allCheckbox = NSButton(checkboxWithTitle: "Export all images", target: nil, action: nil)
    private let destinationLabel = NSTextField(labelWithString: "No destination selected")
    private let progress = NSProgressIndicator()
    private let message = NSTextField(labelWithString: "")
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private var modelObserver: UUID?

    init(model: ViewerModel) {
        self.model = model
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 350),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Export images"
        panel.isFloatingPanel = true
        super.init(window: panel)
        buildPanel()
        modelObserver = model.observe { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildPanel() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = AppColors.background.cgColor
        let title = NSTextField(labelWithString: "Export images")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Choose a format and destination.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = AppColors.secondaryText
        let formatLabel = controlLabel("FORMAT")
        ExportFormat.allCases.forEach { formatPopup.addItem(withTitle: $0.rawValue) }
        stylePopup(formatPopup)
        allCheckbox.state = .on
        allCheckbox.font = .systemFont(ofSize: 12)
        allCheckbox.target = self
        allCheckbox.action = #selector(toggleAll)
        destinationLabel.font = .systemFont(ofSize: 10)
        destinationLabel.textColor = AppColors.secondaryText
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        let choose = button("Choose folder…", symbol: "folder", action: #selector(chooseFolder))
        choose.target = self
        let destination = horizontalStack([destinationLabel, choose], spacing: 10)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        progress.controlSize = .small
        message.font = .systemFont(ofSize: 10)
        message.textColor = AppColors.secondaryText
        let cancel = button("Close", action: #selector(closePanel))
        cancel.target = self
        exportButton.target = self
        exportButton.action = #selector(startExport)
        styleButton(exportButton, accent: true)
        let buttons = horizontalStack([flexibleSpace(), cancel, exportButton], spacing: 8)
        let stack = verticalStack([title, subtitle, spacer(height: 8), horizontalStack([formatLabel, formatPopup], spacing: 10),
                                   allCheckbox, spacer(height: 3), destination, spacer(height: 8), progress, message,
                                   spacer(height: 8), buttons], spacing: 8)
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            formatLabel.widthAnchor.constraint(equalToConstant: 58), destination.heightAnchor.constraint(equalToConstant: 38),
            progress.heightAnchor.constraint(equalToConstant: 10), buttons.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func refresh() {
        destinationLabel.stringValue = model.exportFolder?.path ?? "No destination selected"
        progress.doubleValue = model.exportProgress
        message.stringValue = model.exportMessage ?? ""
        exportButton.title = model.isExporting ? "Exporting…" : "Export"
        exportButton.isEnabled = !model.isExporting && model.exportFolder != nil && !model.files.isEmpty
    }

    @objc private func chooseFolder() { model.chooseExportFolder() }
    @objc private func toggleAll() { model.exportMessage = nil }
    @objc private func closePanel() {
        guard let sheet = window else { return }
        modelObserver.map { model.removeObserver($0) }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
    }
    @objc private func startExport() {
        guard let format = ExportFormat(rawValue: formatPopup.titleOfSelectedItem ?? "PNG") else { return }
        model.export(format: format, allImages: allCheckbox.state == .on)
    }
}

final class GalleryItemView: NSTableCellView {
    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let numberLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.backgroundColor = AppColors.imageField.cgColor
        thumbnailView.layer?.cornerRadius = 5
        nameLabel.font = .systemFont(ofSize: 10)
        nameLabel.textColor = AppColors.primaryText
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        numberLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        numberLabel.textColor = AppColors.secondaryText
        [thumbnailView, nameLabel, numberLabel].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 46), thumbnailView.heightAnchor.constraint(equalToConstant: 57),
            nameLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 9), nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 7), nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -5),
            numberLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), numberLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            numberLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(url: URL, number: Int) { nameLabel.stringValue = url.deletingPathExtension().lastPathComponent; numberLabel.stringValue = String(format: "%02d", number) }
    func setThumbnail(_ data: Data) { thumbnailView.image = NSImage(data: data) }
    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected ? AppColors.accent.withAlphaComponent(0.17).cgColor : NSColor.clear.cgColor
        nameLabel.font = .systemFont(ofSize: 10, weight: selected ? .semibold : .regular)
        layer?.borderWidth = selected ? 2 : 0
        layer?.borderColor = selected ? AppColors.accent.cgColor : NSColor.clear.cgColor
    }
}

final class AspectFitImageBox: NSView {
    private let imageView = NSImageView(frame: .zero)
    private var image: NSImage?
    private var panOffset = NSPoint.zero
    private var lastDragLocation: NSPoint?
    private(set) var zoomFactor: CGFloat = 1
    var onZoomChanged: ((CGFloat) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: NSImage?, resetZoom: Bool) {
        self.image = image
        imageView.image = image
        imageView.needsDisplay = true
        if resetZoom {
            zoomFactor = 1
            panOffset = .zero
            onZoomChanged?(zoomFactor)
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            imageView.frame = bounds
            return
        }
        let insetX = min(28, max(8, bounds.width * 0.025))
        let insetY = min(28, max(8, bounds.height * 0.025))
        let availableWidth = max(1, bounds.width - insetX * 2)
        let availableHeight = max(1, bounds.height - insetY * 2)
        let scale = min(availableWidth / image.size.width, availableHeight / image.size.height) * zoomFactor
        let fittedSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let maxPanX = max(0, (fittedSize.width - bounds.width) / 2)
        let maxPanY = max(0, (fittedSize.height - bounds.height) / 2)
        panOffset.x = min(max(panOffset.x, -maxPanX), maxPanX)
        panOffset.y = min(max(panOffset.y, -maxPanY), maxPanY)
        imageView.frame = NSRect(x: bounds.midX - fittedSize.width / 2 + panOffset.x,
                                 y: bounds.midY - fittedSize.height / 2 + panOffset.y,
                                 width: fittedSize.width, height: fittedSize.height)
    }

    func zoomIn() { setZoom(min(4, zoomFactor * 1.25)) }
    func zoomOut() { setZoom(max(1, zoomFactor / 1.25)) }

    private func setZoom(_ value: CGFloat) {
        guard value != zoomFactor else { return }
        zoomFactor = value
        if zoomFactor <= 1 { panOffset = .zero }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onZoomChanged?(zoomFactor)
    }

    func fitToWindow() {
        zoomFactor = 1
        panOffset = .zero
        needsLayout = true
        layoutSubtreeIfNeeded()
        imageView.needsDisplay = true
        onZoomChanged?(zoomFactor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let superview {
            let localPoint = convert(point, from: superview)
            if bounds.contains(localPoint) { return self }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if let contentView = window?.contentView { window?.makeFirstResponder(contentView) }
        if zoomFactor > 1.001 { lastDragLocation = convert(event.locationInWindow, from: nil) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastDragLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        panOffset.x += current.x - previous.x
        panOffset.y += current.y - previous.y
        lastDragLocation = current
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
    }
}

final class ImportCanvasView: NSView {
    var isEmptyState: (() -> Bool)?
    var onEmptyClick: (() -> Bool)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard isEmptyState?() == true, let hit else { return hit }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        if onEmptyClick?() == true { return }
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

final class KeyboardRootView: NSView {
    var onNavigate: ((UInt16) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onNavigate?(event.keyCode) != true { super.keyDown(with: event) }
    }
}

private enum AppColors {
    static let background = NSColor(hex: 0x121212)
    static let panel = NSColor(hex: 0x1E1E1E)
    static let panelRaised = NSColor(hex: 0x282828)
    static let controlSurface = NSColor(hex: 0x353535)
    static let accent = NSColor(hex: 0xEC641C)
    static let primaryText = NSColor.white
    static let secondaryText = NSColor(hex: 0xA0A0A0)
    static let imageField = NSColor(hex: 0x080808)
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = spacing
    return stack
}

private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = spacing
    return stack
}

private func flexibleSpace() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return view
}

private func spacer(height: CGFloat) -> NSView {
    let view = NSView()
    view.heightAnchor.constraint(equalToConstant: height).isActive = true
    return view
}

private func controlLabel(_ value: String) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: 9, weight: .bold)
    label.textColor = AppColors.secondaryText
    return label
}

private func button(_ title: String, symbol: String? = nil, accent: Bool = false,
                    action: Selector) -> NSButton {
    let button = NSButton(title: title, target: nil, action: action)
    if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); button.imagePosition = .imageLeading }
    styleButton(button, accent: accent)
    return button
}

private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
    let button = NSButton(title: "", target: nil, action: action)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    styleButton(button, iconOnly: true)
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.widthAnchor.constraint(equalToConstant: 36).isActive = true
    return button
}

private func styleButton(_ button: NSButton, accent: Bool = false, iconOnly: Bool = false) {
    button.isBordered = false
    button.bezelStyle = .rounded
    button.font = .systemFont(ofSize: 12, weight: .semibold)
    button.contentTintColor = .white
    button.imageHugsTitle = !button.title.isEmpty
    if !button.title.isEmpty {
        button.title = "\u{2009}\(button.title)\u{2009}"
    }
    button.wantsLayer = true
    button.layer?.cornerRadius = 8
    button.layer?.backgroundColor = (accent ? AppColors.accent : (iconOnly ? AppColors.panelRaised : AppColors.controlSurface)).cgColor
    button.layer?.borderWidth = 1
    button.layer?.borderColor = NSColor.white.withAlphaComponent(accent ? 0.2 : (iconOnly ? 0.07 : 0.13)).cgColor
    button.setButtonType(.momentaryPushIn)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.heightAnchor.constraint(equalToConstant: 36).isActive = true
}

private func stylePopup(_ popup: NSPopUpButton) {
    popup.font = .systemFont(ofSize: 11)
    popup.controlSize = .regular
}

private func addHairline(to view: NSView, atBottom: Bool, trailing: Bool = false) {
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(line)
    if trailing {
        NSLayoutConstraint.activate([line.topAnchor.constraint(equalTo: view.topAnchor), line.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     line.trailingAnchor.constraint(equalTo: view.trailingAnchor), line.widthAnchor.constraint(equalToConstant: 1)])
    } else {
        NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: view.leadingAnchor), line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                     (atBottom ? line.bottomAnchor.constraint(equalTo: view.bottomAnchor) : line.topAnchor.constraint(equalTo: view.topAnchor)),
                                     line.heightAnchor.constraint(equalToConstant: 1)])
    }
}
