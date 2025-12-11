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
    
    // Tools
    @Published var currentTool: ToolType = .pen
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
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == kGlobalToggleKey && event.modifierFlags.contains(kGlobalToggleModifiers) {
                DispatchQueue.main.async { self.isDrawingMode.toggle() }
            }
        }
        
        // Also monitor local Escape key to exit
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // Toggle Shortcut
            if event.keyCode == kGlobalToggleKey && event.modifierFlags.contains(kGlobalToggleModifiers) {
                self.isDrawingMode.toggle()
                return nil
            }
            
            // Escape Key to Exit
            if event.keyCode == kVK_Escape && self.isDrawingMode {
                self.isDrawingMode = false
                return nil
            }
            
            return event
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
        
        // CRITICAL: Level must be high enough to draw over apps, but LOWER than the toolbar
        // .screenSaver is usually ~1000.
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
        
        // CRITICAL: Toolbar must be strictly HIGHER than overlay to receive clicks
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
    case pen, highlighter, rectangle, circle, text, eraser
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
            
            // 1. Saved Annotations
            ForEach(appDelegate.annotations) { annotation in
                renderAnnotation(annotation)
            }
            
            // 2. Active Drawing (Live Feedback)
            if let start = dragStart, let current = dragCurrent {
                renderActiveDrag(start: start, current: current)
            } else if !currentPath.isEmpty {
                 Path { p in
                    guard let first = currentPath.first else { return }
                    p.move(to: first)
                    for point in currentPath.dropFirst() { p.addLine(to: point) }
                }
                .stroke(appDelegate.effectiveColor, style: StrokeStyle(lineWidth: appDelegate.effectiveWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0) // 0 distance ensures immediate start
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
            // Commit path
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
            appDelegate.annotations.append(Annotation(type: .text("Double Click", start), color: appDelegate.selectedColor, width: 0))
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
        // Ensure clicks register
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

// MARK: - UI: Text Node
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
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
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
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

class ToolbarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    // Enable dragging
    override func mouseDown(with event: NSEvent) {
        self.performDrag(with: event)
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
