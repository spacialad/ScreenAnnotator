import SwiftUI
import AppKit
import Carbon
import Combine

// MARK: - Main Entry Point
@main
struct ScreenAnnotatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate)
        }
    }
}

// MARK: - Global Constants
let kGlobalToggleKey: Int = kVK_ANSI_A // 'A' Key
let kGlobalToggleModifiers: NSEvent.ModifierFlags = [.command, .option]

// MARK: - App Delegate & State Management
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem?
    var overlayWindow: OverlayWindow?
    var toolbarWindow: ToolbarWindow?
    
    @AppStorage("autoHideEnabled") var autoHideEnabled: Bool = true
    @AppStorage("autoHideDelay") var autoHideDelay: Double = 3.0
    
    private var hideTimer: Timer?
    
    @Published var isDrawingMode = false {
        didSet { toggleDrawingMode(isDrawingMode) }
    }
    
    @Published var annotations: [Annotation] = []
    @Published var selectedAnnotationID: UUID? = nil
    
    // Triggers focus programmatically
    @Published var idToFocus: UUID? = nil
    
    @Published var currentTool: ToolType = .pen {
        didSet {
            cleanupEmptyTextNodes()
            selectedAnnotationID = nil
        }
    }
    @Published var selectedColor: Color = .red
    @Published var lineWidth: CGFloat = 5.0
    
    var effectiveColor: Color {
        return currentTool == .highlighter ? selectedColor.opacity(0.4) : selectedColor
    }
    
    var effectiveWidth: CGFloat {
        return currentTool == .highlighter ? 25.0 : lineWidth
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupOverlayWindow()
        setupToolbarWindow()
        setupGlobalHotKey()
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "Annotate")
            button.action = #selector(menuBarClicked)
        }
    }
    
    func setupGlobalHotKey() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == kGlobalToggleKey && event.modifierFlags.contains(kGlobalToggleModifiers) {
                DispatchQueue.main.async { self.isDrawingMode.toggle() }
            }
        }
        
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // 1. Toggle Shortcut
            if event.keyCode == kGlobalToggleKey && event.modifierFlags.contains(kGlobalToggleModifiers) {
                self.isDrawingMode.toggle()
                return nil
            }
            
            // 2. Escape Key Handling
            if event.keyCode == kVK_Escape {
                // Check if a Text Field is currently the responder (Edit Mode / Green)
                let isEditing = (NSApp.keyWindow?.firstResponder as? NSTextView) != nil
                
                if isEditing {
                    // State: Editing (Green) -> Escape -> Selected (Blue)
                    // We resign focus, but keep selectedAnnotationID set.
                    self.overlayWindow?.makeFirstResponder(nil)
                    self.idToFocus = nil
                    // IMPORTANT: We do NOT clear selectedAnnotationID here.
                    return nil
                } else if self.selectedAnnotationID != nil {
                    // State: Selected (Blue) -> Escape -> Deselected
                    self.cleanupEmptyTextNodes()
                    self.selectedAnnotationID = nil
                    self.idToFocus = nil
                    return nil
                } else if self.isDrawingMode {
                    // State: Idle -> Escape -> Exit App
                    self.isDrawingMode = false
                    return nil
                }
            }
            
            // 3. Handle Text Box Logic (Delete vs Type)
            if self.selectedAnnotationID != nil {
                let isEditing = (NSApp.keyWindow?.firstResponder as? NSTextView) != nil
                
                // DELETE Key
                if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
                    if isEditing {
                        return event // Let TextField handle text deletion
                    } else {
                        self.deleteSelectedAnnotation() // Delete the whole box
                        return nil
                    }
                }
                
                // PRINTABLE Keys (Auto-switch to Edit Mode)
                if !isEditing,
                   let chars = event.characters,
                   !chars.isEmpty,
                   event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                    
                    self.idToFocus = self.selectedAnnotationID // Enter Edit Mode
                    
                    // Append character manually since focus wasn't there yet
                    if let index = self.annotations.firstIndex(where: { $0.id == self.selectedAnnotationID }) {
                        if case .text(let existingText, let loc) = self.annotations[index].type {
                            self.annotations[index].type = .text(existingText + chars, loc)
                        }
                    }
                    return nil
                }
            }
            
            return event
        }
    }
    
    func deleteSelectedAnnotation() {
        guard let id = selectedAnnotationID else { return }
        annotations.removeAll { $0.id == id }
        selectedAnnotationID = nil
        idToFocus = nil
    }
    
    func cleanupEmptyTextNodes() {
        annotations.removeAll { annotation in
            if case .text(let text, _) = annotation.type {
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }
    
    func setupOverlayWindow() {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        overlayWindow = OverlayWindow(
            contentRect: screenRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        overlayWindow?.contentView = NSHostingView(rootView: CanvasView().environmentObject(self))
        overlayWindow?.backgroundColor = .clear
        overlayWindow?.isOpaque = false
        overlayWindow?.ignoresMouseEvents = true
        overlayWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlayWindow?.level = .screenSaver
        overlayWindow?.orderOut(nil)
    }
    
    func setupToolbarWindow() {
        toolbarWindow = ToolbarWindow(
            contentRect: NSRect(x: 100, y: NSScreen.main?.visibleFrame.maxY ?? 800 - 150, width: 440, height: 80),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let toolbarView = ControlPanel().environmentObject(self)
        toolbarWindow?.contentView = NSHostingView(rootView: toolbarView)
        toolbarWindow?.backgroundColor = .clear
        toolbarWindow?.isOpaque = false
        toolbarWindow?.hasShadow = true
        toolbarWindow?.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1)
        toolbarWindow?.sharingType = .none
        toolbarWindow?.orderOut(nil)
    }
    
    @objc func menuBarClicked() {
        isDrawingMode.toggle()
    }
    
    func toggleDrawingMode(_ active: Bool) {
        if active {
            overlayWindow?.makeKeyAndOrderFront(nil)
            overlayWindow?.ignoresMouseEvents = false
            toolbarWindow?.makeKeyAndOrderFront(nil)
            resetAutoHideTimer()
            NSCursor.crosshair.push()
        } else {
            cleanupEmptyTextNodes() // Clean up before hiding
            overlayWindow?.ignoresMouseEvents = true
            overlayWindow?.orderOut(nil)
            toolbarWindow?.orderOut(nil)
            hideTimer?.invalidate()
            selectedAnnotationID = nil
            idToFocus = nil
            NSCursor.pop()
        }
    }
    
    func resetAutoHideTimer() {
        hideTimer?.invalidate()
        toolbarWindow?.animator().alphaValue = 1.0
        guard autoHideEnabled else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: autoHideDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.toolbarWindow?.animator().alphaValue = 0.0
        }
    }
    
    func userInteractedWithToolbar() { resetAutoHideTimer() }
    func clearAll() { annotations.removeAll(); selectedAnnotationID = nil }
    func clearArea(in rect: CGRect) {
        annotations.removeAll { annotation in
            switch annotation.type {
            case .path(let points): return points.boundingRect.intersects(rect)
            case .text(_, let location): return CGRect(x: location.x, y: location.y, width: 200, height: 50).intersects(rect)
            case .rectangle(let r), .circle(let r): return r.intersects(rect)
            }
        }
        selectedAnnotationID = nil
    }
}

// MARK: - Models
enum ToolType: String, CaseIterable {
    case pen, highlighter, rectangle, circle, text, eraser
}

struct Annotation: Identifiable {
    let id = UUID()
    var type: AnnotationType
    let color: Color
    let width: CGFloat
}

enum AnnotationType {
    case path([CGPoint])
    case text(String, CGPoint)
    case rectangle(CGRect)
    case circle(CGRect)
}

// MARK: - UI: Canvas View
struct CanvasView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var currentPath: [CGPoint] = []
    
    var body: some View {
        ZStack {
            // Background Layer
            Color.white.opacity(0.0001)
                .contentShape(Rectangle())
                .onTapGesture {
                    // CLEANUP on Blur
                    appDelegate.cleanupEmptyTextNodes()
                    
                    // Click outside -> Deselect everything
                    appDelegate.selectedAnnotationID = nil
                    appDelegate.idToFocus = nil
                    
                    // Force unfocus
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            
            // 1. Annotations
            ForEach($appDelegate.annotations) { $annotation in
                renderAnnotation($annotation)
            }
            
            // 2. Active Drawing
            if (appDelegate.currentTool == .pen || appDelegate.currentTool == .highlighter), !currentPath.isEmpty {
                 Path { p in
                    guard let first = currentPath.first else { return }
                    p.move(to: first)
                    for point in currentPath.dropFirst() { p.addLine(to: point) }
                }
                .stroke(appDelegate.effectiveColor, style: StrokeStyle(lineWidth: appDelegate.effectiveWidth, lineCap: .round, lineJoin: .round))
            }
            else if let start = dragStart, let current = dragCurrent {
                renderActiveDrag(start: start, current: current)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    handleDragChange(value)
                    appDelegate.resetAutoHideTimer()
                }
                .onEnded { value in
                    handleDragEnd(value)
                    appDelegate.resetAutoHideTimer()
                }
        )
    }
    
    @ViewBuilder
    func renderAnnotation(_ annotation: Binding<Annotation>) -> some View {
        switch annotation.wrappedValue.type {
        case .path(let points):
            Path { p in
                guard let first = points.first else { return }
                p.move(to: first)
                for point in points.dropFirst() { p.addLine(to: point) }
            }
            .stroke(annotation.wrappedValue.color, style: StrokeStyle(lineWidth: annotation.wrappedValue.width, lineCap: .round, lineJoin: .round))
        case .rectangle(let rect):
            Rectangle().stroke(annotation.wrappedValue.color, lineWidth: annotation.wrappedValue.width)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
        case .circle(let rect):
            Ellipse().stroke(annotation.wrappedValue.color, lineWidth: annotation.wrappedValue.width)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
        case .text(let str, let loc):
            // Use a binding to the text content for the TextField
            TextNodeView(
                text: Binding(
                    get: { str },
                    set: { newVal in annotation.wrappedValue.type = .text(newVal, loc) }
                ),
                color: annotation.wrappedValue.color,
                location: loc,
                id: annotation.wrappedValue.id
            )
        }
    }
    
    @ViewBuilder
    func renderActiveDrag(start: CGPoint, current: CGPoint) -> some View {
        let rect = CGRect(from: start, to: current)
        switch appDelegate.currentTool {
        case .rectangle:
            Rectangle().stroke(appDelegate.selectedColor, lineWidth: appDelegate.lineWidth)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
        case .circle:
            Ellipse().stroke(appDelegate.selectedColor, lineWidth: appDelegate.lineWidth)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
        case .eraser:
            Rectangle().fill(Color.red.opacity(0.2))
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                .overlay(Rectangle().strokeBorder(Color.red, style: StrokeStyle(lineWidth: 1, dash: [5]))
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY))
        default: EmptyView()
        }
    }
    
    private func handleDragChange(_ value: DragGesture.Value) {
        if dragStart == nil { dragStart = value.startLocation }
        dragCurrent = value.location
        if appDelegate.currentTool == .pen || appDelegate.currentTool == .highlighter {
            currentPath.append(value.location)
        }
    }
    
    private func handleDragEnd(_ value: DragGesture.Value) {
        let start = dragStart ?? value.startLocation
        let end = value.location
        let rect = CGRect(from: start, to: end)
        
        switch appDelegate.currentTool {
        case .pen, .highlighter:
            appDelegate.annotations.append(Annotation(type: .path(currentPath), color: appDelegate.effectiveColor, width: appDelegate.effectiveWidth))
            currentPath = []
        case .rectangle:
            appDelegate.annotations.append(Annotation(type: .rectangle(rect), color: appDelegate.selectedColor, width: appDelegate.lineWidth))
        case .circle:
            appDelegate.annotations.append(Annotation(type: .circle(rect), color: appDelegate.selectedColor, width: appDelegate.lineWidth))
        case .text:
            // Start Empty
            let newText = Annotation(type: .text("", end), color: appDelegate.selectedColor, width: 0)
            appDelegate.annotations.append(newText)
            appDelegate.selectedAnnotationID = newText.id
            appDelegate.idToFocus = newText.id // Auto-Enter Edit Mode
        case .eraser:
            appDelegate.clearArea(in: rect)
        }
        dragStart = nil
        dragCurrent = nil
    }
}

// MARK: - UI: Text Node with Auto-Resize
struct TextNodeView: View {
    @Binding var text: String
    var color: Color
    var location: CGPoint
    var id: UUID
    
    @EnvironmentObject var appDelegate: AppDelegate
    @FocusState private var isFocused: Bool
    
    var isSelected: Bool { appDelegate.selectedAnnotationID == id }
    
    var body: some View {
        // ZStack technique for Auto-Width TextField
        ZStack {
            // 1. Invisible Text used for sizing
            // We verify text is not empty for size calc, else use placeholder size
            Text(text.isEmpty ? "Type here" : text)
                .font(.system(size: 24, weight: .bold))
                .opacity(0)
                .padding(8)
            
            // 2. The Actual Input Field
            TextField("Type here", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(color)
                .padding(8)
                // Ensure it has at least some width to be clickable if empty
                .frame(minWidth: 50)
                .focused($isFocused)
        }
        // This fixedSize tells the parent to respect the ideal size (determined by the hidden Text)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor, lineWidth: 2)
                .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
        )
        // Position centers the view at the coordinates
        .position(location)
        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
        // Handle Interactions
        .onTapGesture {
            appDelegate.selectedAnnotationID = id
            // Single tap on Blue = Blue. Single tap on unselected = Blue.
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                // Double click -> Edit Mode
                appDelegate.selectedAnnotationID = id
                appDelegate.idToFocus = id
            }
        )
        .onChange(of: appDelegate.idToFocus) { newId in
            if newId == id { isFocused = true }
        }
        .onChange(of: isFocused) { focused in
            if focused {
                // If focus gained, ensure we track selection
                appDelegate.selectedAnnotationID = id
            }
            // If focus lost, we don't clear selectedAnnotationID here, allowing the "Blue" state.
        }
    }
    
    var borderColor: Color {
        if isSelected {
            return isFocused ? .green : .blue
        }
        return .clear
    }
}

// MARK: - UI: Control Panel
struct ControlPanel: View {
    @EnvironmentObject var appDelegate: AppDelegate
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundColor(.secondary)
            HStack(spacing: 4) {
                ToolButton(icon: "pencil", tool: .pen)
                ToolButton(icon: "highlighter", tool: .highlighter)
                ToolButton(icon: "square", tool: .rectangle)
                ToolButton(icon: "circle", tool: .circle)
                ToolButton(icon: "textformat", tool: .text)
                ToolButton(icon: "eraser", tool: .eraser)
            }
            .padding(4).background(Color.black.opacity(0.1)).cornerRadius(8)
            Divider().frame(height: 24)
            ColorPicker("", selection: $appDelegate.selectedColor).labelsHidden().frame(width: 30)
            if [.pen, .rectangle, .circle].contains(appDelegate.currentTool) {
                Slider(value: $appDelegate.lineWidth, in: 2...20).frame(width: 40).accentColor(appDelegate.selectedColor)
            }
            Spacer()
            Button(action: { appDelegate.clearAll() }) {
                Image(systemName: "trash").foregroundColor(.red).frame(width: 24, height: 24)
            }.buttonStyle(.plain)
            Button(action: { appDelegate.isDrawingMode = false }) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(.gray).frame(width: 24, height: 24)
            }.buttonStyle(.plain)
        }
        .padding(12).background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .onHover { if $0 { appDelegate.userInteractedWithToolbar() } }
        .onTapGesture { appDelegate.userInteractedWithToolbar() }
    }
    
    func ToolButton(icon: String, tool: ToolType) -> some View {
        Button(action: {
            appDelegate.currentTool = tool
            appDelegate.userInteractedWithToolbar()
        }) {
            Image(systemName: icon).font(.system(size: 14))
                .foregroundColor(appDelegate.currentTool == tool ? .white : .secondary)
                .frame(width: 26, height: 26)
                .background(appDelegate.currentTool == tool ? Color.blue : Color.clear).cornerRadius(6)
        }.buttonStyle(.plain)
    }
}

// MARK: - UI: Settings
struct SettingsView: View {
    @AppStorage("autoHideEnabled") var autoHideEnabled: Bool = true
    @AppStorage("autoHideDelay") var autoHideDelay: Double = 3.0
    var body: some View {
        Form {
            Section(header: Text("Toolbar")) {
                Toggle("Auto-hide Toolbar", isOn: $autoHideEnabled)
                if autoHideEnabled {
                    Slider(value: $autoHideDelay, in: 1.0...10.0, step: 0.5) { Text("\(String(format: "%.1f", autoHideDelay))s") }
                }
            }
        }
        .padding().frame(width: 300)
    }
}

// MARK: - Helpers

// 1. Fixed "First Click" Issue by forcing Key Window status
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        // FORCE this window to be the key window on the very first click
        // preventing the "one click to wake, two clicks to work" issue.
        self.makeKey()
        super.mouseDown(with: event)
    }
}

// 2. Toolbar Snapping
class ToolbarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        // performDrag blocks until the user releases the mouse button
        self.performDrag(with: event)
        // Since execution resumes here AFTER drag ends, we snap immediately
        snapToEdges()
    }
    
    func snapToEdges() {
        if let screen = self.screen {
            let visible = screen.visibleFrame
            var origin = self.frame.origin
            let snap: CGFloat = 30.0
            
            // Snap logic
            if abs(frame.minX - visible.minX) < snap { origin.x = visible.minX }
            if abs(frame.maxX - visible.maxX) < snap { origin.x = visible.maxX - frame.width }
            if abs(frame.minY - visible.minY) < snap { origin.y = visible.minY }
            if abs(frame.maxY - visible.maxY) < snap { origin.y = visible.maxY - frame.height }
            
            self.setFrameOrigin(origin)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = blendingMode; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { nsView.material = material; nsView.blendingMode = blendingMode }
}

extension CGRect {
    init(from p1: CGPoint, to p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
}

extension Array where Element == CGPoint {
    var boundingRect: CGRect {
        guard let first = self.first else { return .zero }
        var r = CGRect(origin: first, size: .zero)
        for p in self { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }
}
