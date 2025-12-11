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
    
    // Preferences
    @AppStorage("autoHideEnabled") var autoHideEnabled: Bool = true
    @AppStorage("autoHideDelay") var autoHideDelay: Double = 3.0
    
    private var hideTimer: Timer?
    
    // State
    @Published var isDrawingMode = false {
        didSet { toggleDrawingMode(isDrawingMode) }
    }
    
    @Published var annotations: [Annotation] = []
    @Published var selectedAnnotationID: UUID? = nil // For selecting text/shapes
    
    // Tools
    @Published var currentTool: ToolType = .pen {
        didSet {
            // Deselect when changing tools to avoid confusion
            selectedAnnotationID = nil
        }
    }
    @Published var selectedColor: Color = .red
    @Published var lineWidth: CGFloat = 5.0
    
    // Highlighter mode adds transparency to the selected color
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
        // 1. Global Shortcut (Cmd+Opt+A)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == kGlobalToggleKey && event.modifierFlags.contains(kGlobalToggleModifiers) {
                DispatchQueue.main.async { self.isDrawingMode.toggle() }
            }
        }
        
        // 2. Local Monitor (Esc to exit, Delete to remove selection)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // Toggle Shortcut
            if event.keyCode == kGlobalToggleKey && event.modifierFlags.contains(kGlobalToggleModifiers) {
                self.isDrawingMode.toggle()
                return nil
            }
            
            // Escape Key -> Exit Drawing Mode
            if event.keyCode == kVK_Escape && self.isDrawingMode {
                self.isDrawingMode = false
                return nil
            }
            
            // Delete/Backspace Key -> Remove Selected Annotation
            if (event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete) && self.selectedAnnotationID != nil {
                // We only delete if we are NOT currently editing a text field
                // Checking current responder is complex in SwiftUI, but usually TextField eats the event.
                // If the event reaches here, the TextField likely isn't FirstResponder or we are capturing it.
                // Simple logic: Remove the annotation.
                self.deleteSelectedAnnotation()
                return nil
            }
            
            return event
        }
    }
    
    func deleteSelectedAnnotation() {
        guard let id = selectedAnnotationID else { return }
        annotations.removeAll { $0.id == id }
        selectedAnnotationID = nil
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
        
        // Level must be high enough to draw over apps, but LOWER than the toolbar
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
        
        // Toolbar must be strictly HIGHER than overlay to receive clicks
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
            overlayWindow?.ignoresMouseEvents = true
            overlayWindow?.orderOut(nil)
            
            toolbarWindow?.orderOut(nil)
            hideTimer?.invalidate()
            selectedAnnotationID = nil // Reset selection
            
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
    
    func userInteractedWithToolbar() {
        resetAutoHideTimer()
    }
    
    func clearAll() {
        annotations.removeAll()
        selectedAnnotationID = nil
    }
    
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
            // Invisible background to catch clicks
            Color.white.opacity(0.0001)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Clicking background deselects everything
                    appDelegate.selectedAnnotationID = nil
                }
            
            // 1. Saved Annotations
            ForEach(appDelegate.annotations) { annotation in
                renderAnnotation(annotation)
            }
            
            // 2. Active Drawing (Immediate Feedback)
            // Separate logic for Paths vs Shapes to fix "invisible" bug
            if (appDelegate.currentTool == .pen || appDelegate.currentTool == .highlighter), !currentPath.isEmpty {
                 Path { p in
                    guard let first = currentPath.first else { return }
                    p.move(to: first)
                    for point in currentPath.dropFirst() { p.addLine(to: point) }
                }
                .stroke(appDelegate.effectiveColor, style: StrokeStyle(lineWidth: appDelegate.effectiveWidth, lineCap: .round, lineJoin: .round))
            }
            else if let start = dragStart, let current = dragCurrent {
                // Render Shapes/Eraser only when drag data exists
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
    func renderAnnotation(_ annotation: Annotation) -> some View {
        switch annotation.type {
        case .path(let points):
            Path { p in
                guard let first = points.first else { return }
                p.move(to: first)
                for point in points.dropFirst() { p.addLine(to: point) }
            }
            .stroke(annotation.color, style: StrokeStyle(lineWidth: annotation.width, lineCap: .round, lineJoin: .round))
        case .rectangle(let rect):
            Rectangle().stroke(annotation.color, lineWidth: annotation.width)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
        case .circle(let rect):
            Ellipse().stroke(annotation.color, lineWidth: annotation.width)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
        case .text(let str, let loc):
            TextNodeView(text: str, color: annotation.color, location: loc, id: annotation.id)
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
        
        // Immediate feedback for drawing tools
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
            appDelegate.annotations.append(Annotation(
                type: .path(currentPath),
                color: appDelegate.effectiveColor,
                width: appDelegate.effectiveWidth
            ))
            currentPath = []
            
        case .rectangle:
            appDelegate.annotations.append(Annotation(type: .rectangle(rect), color: appDelegate.selectedColor, width: appDelegate.lineWidth))
        case .circle:
            appDelegate.annotations.append(Annotation(type: .circle(rect), color: appDelegate.selectedColor, width: appDelegate.lineWidth))
        case .text:
            // Text is created on click, handled by logic but if dragged we can also place it
            // Only create if we haven't created one via other means.
            // Simplified: Drag creates text at end point
            let newText = Annotation(type: .text("Double Click", end), color: appDelegate.selectedColor, width: 0)
            appDelegate.annotations.append(newText)
            appDelegate.selectedAnnotationID = newText.id // Auto select newly created text
            
        case .eraser:
            appDelegate.clearArea(in: rect)
        }
        dragStart = nil
        dragCurrent = nil
    }
}

// MARK: - UI: Toolbar (Control Panel)
struct ControlPanel: View {
    @EnvironmentObject var appDelegate: AppDelegate
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
            
            // Tool Group
            HStack(spacing: 4) {
                ToolButton(icon: "pencil", tool: .pen)
                ToolButton(icon: "highlighter", tool: .highlighter)
                ToolButton(icon: "square", tool: .rectangle)
                ToolButton(icon: "circle", tool: .circle)
                ToolButton(icon: "textformat", tool: .text)
                ToolButton(icon: "eraser", tool: .eraser)
            }
            .padding(4)
            .background(Color.black.opacity(0.1))
            .cornerRadius(8)
            
            Divider().frame(height: 24)
            
            ColorPicker("", selection: $appDelegate.selectedColor)
                .labelsHidden()
                .frame(width: 30)
            
            if [.pen, .rectangle, .circle].contains(appDelegate.currentTool) {
                Slider(value: $appDelegate.lineWidth, in: 2...20)
                    .frame(width: 40)
                    .accentColor(appDelegate.selectedColor)
            }
            
            Spacer()
            
            // Actions
            Button(action: { appDelegate.clearAll() }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Clear All")
            
            Button(action: { appDelegate.isDrawingMode = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Exit (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .shadow(radius: 5)
        .onHover { hovering in
            if hovering { appDelegate.userInteractedWithToolbar() }
        }
        .onTapGesture {
            appDelegate.userInteractedWithToolbar()
        }
    }
    
    func ToolButton(icon: String, tool: ToolType) -> some View {
        Button(action: {
            appDelegate.currentTool = tool
            appDelegate.userInteractedWithToolbar()
        }) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(appDelegate.currentTool == tool ? .white : .secondary)
                .frame(width: 26, height: 26)
                .background(appDelegate.currentTool == tool ? Color.blue : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - UI: Text Node with Selection
struct TextNodeView: View {
    @State var text: String
    var color: Color
    var location: CGPoint
    var id: UUID
    
    @EnvironmentObject var appDelegate: AppDelegate
    
    var isSelected: Bool {
        appDelegate.selectedAnnotationID == id
    }
    
    var body: some View {
        TextField("Type here", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(color)
            .padding(8)
            .background(
                // Selection Border
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
            )
            .frame(width: 300)
            .position(location)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
            .onTapGesture {
                // Select this text node
                appDelegate.selectedAnnotationID = id
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    appDelegate.selectedAnnotationID = id
                }
            )
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
                    Slider(value: $autoHideDelay, in: 1.0...10.0, step: 0.5) {
                        Text("Delay: \(String(format: "%.1f", autoHideDelay))s")
                    }
                }
            }
            Section(header: Text("Shortcuts")) {
                HStack { Text("Toggle Overlay"); Spacer(); Text("⌘⌥A").foregroundColor(.secondary) }
                HStack { Text("Exit Overlay"); Spacer(); Text("Esc").foregroundColor(.secondary) }
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Helpers

// 1. Fixed "First Click" Issue
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    // This allows the window to receive the first click immediately without needing to be "activated" first
    override var acceptsFirstResponder: Bool { true }
    
    // This is the critical fix for "First interaction fails"
    override func mouseDown(with event: NSEvent) {
        // Pass event to responder chain (SwiftUI)
        super.mouseDown(with: event)
    }
}

// 2. Fixed "Snapping" Issue
class ToolbarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        self.performDrag(with: event)
    }
    
    // Snap to edges when drag ends
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        snapToEdges()
    }
    
    func snapToEdges() {
        guard let screen = self.screen else { return }
        let visibleFrame = screen.visibleFrame
        var newOrigin = self.frame.origin
        let snapDistance: CGFloat = 30.0
        
        // Snap Left
        if abs(self.frame.minX - visibleFrame.minX) < snapDistance {
            newOrigin.x = visibleFrame.minX
        }
        // Snap Right
        if abs(self.frame.maxX - visibleFrame.maxX) < snapDistance {
            newOrigin.x = visibleFrame.maxX - self.frame.width
        }
        // Snap Bottom
        if abs(self.frame.minY - visibleFrame.minY) < snapDistance {
            newOrigin.y = visibleFrame.minY
        }
        // Snap Top
        if abs(self.frame.maxY - visibleFrame.maxY) < snapDistance {
            newOrigin.y = visibleFrame.maxY - self.frame.height
        }
        
        self.setFrameOrigin(newOrigin)
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
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
