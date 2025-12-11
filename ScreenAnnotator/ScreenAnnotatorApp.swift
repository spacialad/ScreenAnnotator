import SwiftUI
import AppKit
import Carbon
import Combine // Required for ObservableObject and @Published

// MARK: - Main Entry Point
@main
struct ScreenAnnotatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Standard macOS Settings Window
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
    
    // User Preferences (Persisted)
    @AppStorage("autoHideEnabled") var autoHideEnabled: Bool = true
    @AppStorage("autoHideDelay") var autoHideDelay: Double = 3.0
    
    // Internal Timer logic
    private var hideTimer: Timer?
    
    // Global App State
    @Published var isDrawingMode = false {
        didSet { toggleDrawingMode(isDrawingMode) }
    }
    
    // Annotation Data
    @Published var annotations: [Annotation] = []
    
    // Tools
    @Published var currentTool: ToolType = .pen
    @Published var selectedColor: Color = .red
    @Published var lineWidth: CGFloat = 5.0
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupOverlayWindow()
        setupToolbarWindow()
        setupGlobalHotKey()
    }
    
    // 1. Menu Bar
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "Annotate")
            button.action = #selector(menuBarClicked)
        }
    }
    
    // 2. Global Hotkey
    func setupGlobalHotKey() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == kGlobalToggleKey && event.modifierFlags.contains(kGlobalToggleModifiers) {
                DispatchQueue.main.async { self.isDrawingMode.toggle() }
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == kGlobalToggleKey && event.modifierFlags.contains(kGlobalToggleModifiers) {
                self.isDrawingMode.toggle()
                return nil
            }
            return event
        }
    }
    
    // 3. Overlay Window (Canvas)
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
        // The canvas should be visible in recordings (default sharingType)
        overlayWindow?.orderOut(nil)
    }
    
    // 4. Floating Toolbar
    func setupToolbarWindow() {
        toolbarWindow = ToolbarWindow(
            contentRect: NSRect(x: 100, y: NSScreen.main?.visibleFrame.maxY ?? 800 - 150, width: 380, height: 80),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        let toolbarView = ControlPanel().environmentObject(self)
        toolbarWindow?.contentView = NSHostingView(rootView: toolbarView)
        toolbarWindow?.backgroundColor = .clear
        toolbarWindow?.isOpaque = false
        toolbarWindow?.hasShadow = true
        toolbarWindow?.level = .popUpMenu
        
        // --- STEALTH MODE ---
        // .none means: Visible to user, Invisible to Screenshots/Screen Share/OBS
        toolbarWindow?.sharingType = .none
        
        toolbarWindow?.orderOut(nil)
    }
    
    @objc func menuBarClicked() {
        isDrawingMode.toggle()
    }
    
    func toggleDrawingMode(_ active: Bool) {
        if active {
            overlayWindow?.level = .screenSaver
            overlayWindow?.makeKeyAndOrderFront(nil)
            overlayWindow?.ignoresMouseEvents = false
            
            toolbarWindow?.makeKeyAndOrderFront(nil)
            resetAutoHideTimer() // Start tracking inactivity
            
            NSCursor.crosshair.push()
        } else {
            overlayWindow?.ignoresMouseEvents = true
            overlayWindow?.orderOut(nil)
            
            toolbarWindow?.orderOut(nil)
            hideTimer?.invalidate()
            
            NSCursor.pop()
        }
    }
    
    // MARK: - Auto Hide Logic
    func resetAutoHideTimer() {
        // Cancel existing timer
        hideTimer?.invalidate()
        
        // Ensure visible
        toolbarWindow?.animator().alphaValue = 1.0
        
        guard autoHideEnabled else { return }
        
        // Schedule new fade out
        hideTimer = Timer.scheduledTimer(withTimeInterval: autoHideDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Fade to 0.1 (faintly visible to find it) or 0.0 (invisible)
            // Using 0.0 requires user to remember where it was, but looks cleaner.
            self.toolbarWindow?.animator().alphaValue = 0.0
        }
    }
    
    func userInteractedWithToolbar() {
        // Called when hovering or clicking the toolbar
        resetAutoHideTimer()
    }
    
    // MARK: - Data Management
    func clearAll() { annotations.removeAll() }
    
    func clearArea(in rect: CGRect) {
        annotations.removeAll { annotation in
            switch annotation.type {
            case .path(let points): return points.boundingRect.intersects(rect)
            case .text(_, let location): return CGRect(x: location.x, y: location.y, width: 100, height: 40).intersects(rect)
            case .rectangle(let r), .circle(let r): return r.intersects(rect)
            }
        }
    }
}

// MARK: - Models
enum ToolType: String, CaseIterable {
    case pen, rectangle, circle, text, eraser
}

struct Annotation: Identifiable {
    let id = UUID()
    let type: AnnotationType
    let color: Color
    let width: CGFloat
}

enum AnnotationType {
    case path([CGPoint])
    case text(String, CGPoint)
    case rectangle(CGRect)
    case circle(CGRect)
}

// MARK: - UI: Settings View
struct SettingsView: View {
    @AppStorage("autoHideEnabled") var autoHideEnabled: Bool = true
    @AppStorage("autoHideDelay") var autoHideDelay: Double = 3.0
    
    var body: some View {
        Form {
            Section(header: Text("Toolbar Appearance")) {
                Toggle("Auto-hide Toolbar", isOn: $autoHideEnabled)
                    .toggleStyle(.switch)
                
                if autoHideEnabled {
                    VStack(alignment: .leading) {
                        Text("Hide after \(String(format: "%.1f", autoHideDelay)) seconds")
                        Slider(value: $autoHideDelay, in: 1.0...10.0, step: 0.5)
                    }
                }
                
                Text("Note: The toolbar is invisible to screen recordings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Shortcuts")) {
                HStack {
                    Text("Toggle Overlay")
                    Spacer()
                    Text("⌘ + ⌥ + A")
                        .padding(4)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .padding()
        .frame(width: 350, height: 200)
    }
}

// MARK: - UI: Floating Toolbar
struct ControlPanel: View {
    @EnvironmentObject var appDelegate: AppDelegate
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
            
            HStack(spacing: 8) {
                ToolButton(icon: "pencil", tool: .pen)
                ToolButton(icon: "square", tool: .rectangle)
                ToolButton(icon: "circle", tool: .circle)
                ToolButton(icon: "textformat", tool: .text)
                ToolButton(icon: "eraser", tool: .eraser)
            }
            .padding(6)
            .background(Color.black.opacity(0.1))
            .cornerRadius(8)
            
            Divider().frame(height: 30)
            
            ColorPicker("", selection: $appDelegate.selectedColor).labelsHidden()
            
            if [.pen, .rectangle, .circle].contains(appDelegate.currentTool) {
                Slider(value: $appDelegate.lineWidth, in: 2...20)
                    .frame(width: 50)
                    .accentColor(appDelegate.selectedColor)
            }
            
            Spacer()
            
            Button(action: { appDelegate.clearAll() }) {
                Image(systemName: "trash").font(.system(size: 14)).foregroundColor(.red)
            }
            .buttonStyle(.plain)
            
            Button(action: { appDelegate.isDrawingMode = false }) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.2), lineWidth: 1))
        // INTERACTION TRACKING
        .onHover { hovering in
            if hovering {
                appDelegate.userInteractedWithToolbar()
            }
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
                .font(.system(size: 16))
                .foregroundColor(appDelegate.currentTool == tool ? .white : .secondary)
                .frame(width: 28, height: 28)
                .background(appDelegate.currentTool == tool ? Color.blue : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - UI: Canvas View
struct CanvasView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var currentPath: [CGPoint] = []
    
    var body: some View {
        ZStack {
            Color.white.opacity(0.0001)
            
            ForEach(appDelegate.annotations) { annotation in
                renderAnnotation(annotation)
            }
            
            if let start = dragStart, let current = dragCurrent {
                renderActiveDrag(start: start, current: current)
            } else if !currentPath.isEmpty {
                 Path { p in
                    p.move(to: currentPath.first!)
                    for point in currentPath.dropFirst() { p.addLine(to: point) }
                }
                .stroke(appDelegate.selectedColor, style: StrokeStyle(lineWidth: appDelegate.lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleDragChange(value)
                    appDelegate.resetAutoHideTimer() // Touching canvas keeps toolbar alive? Option: Remove this line if you want toolbar to hide while drawing
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
            TextNodeView(text: str, color: annotation.color, location: loc)
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
        if appDelegate.currentTool == .pen { currentPath.append(value.location) }
    }
    
    private func handleDragEnd(_ value: DragGesture.Value) {
        let start = dragStart ?? value.startLocation
        let end = value.location
        let rect = CGRect(from: start, to: end)
        
        switch appDelegate.currentTool {
        case .pen:
            appDelegate.annotations.append(Annotation(type: .path(currentPath), color: appDelegate.selectedColor, width: appDelegate.lineWidth))
            currentPath = []
        case .rectangle:
            appDelegate.annotations.append(Annotation(type: .rectangle(rect), color: appDelegate.selectedColor, width: appDelegate.lineWidth))
        case .circle:
            appDelegate.annotations.append(Annotation(type: .circle(rect), color: appDelegate.selectedColor, width: appDelegate.lineWidth))
        case .text:
            appDelegate.annotations.append(Annotation(type: .text("Double Click", start), color: appDelegate.selectedColor, width: 0))
        case .eraser:
            appDelegate.clearArea(in: rect)
        }
        dragStart = nil
        dragCurrent = nil
    }
}

struct TextNodeView: View {
    @State var text: String
    var color: Color
    var location: CGPoint
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(color)
            .frame(width: 300)
            .position(location)
    }
}

// MARK: - Helpers
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

class ToolbarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { self.performDrag(with: event) }
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
