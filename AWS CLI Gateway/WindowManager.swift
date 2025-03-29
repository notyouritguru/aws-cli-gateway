import SwiftUI
import Cocoa

class WindowManager {
    static let shared = WindowManager()
    
    private var windows: [String: NSWindow] = [:]
    
    private init() {}
    
    func showWindow<Content: View>(
        id: String,
        title: String,
        size: NSSize,
        style: NSWindow.StyleMask = [.titled, .closable],
        content: Content
    ) where Content: View {
        // If there's already a window with the same ID, bring it to front instead of making a new one
        if let existingWindow = windows[id] {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create and configure the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        
        // Keep a reference so we can clean up later
        let delegate = WindowDelegate(id: id)
        window.delegate = delegate
        
        // Associate the delegate with the window
        objc_setAssociatedObject(
            window,
            "delegateKey",
            delegate,
            .OBJC_ASSOCIATION_RETAIN
        )
        
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeWindow(id: String) {
        windows[id]?.close()
        windows.removeValue(forKey: id)
    }
    
    // MARK: - Show Add Profile Window
    func showAddProfileWindow() {
        showWindow(
            id: "addProfile",
            title: "Add AWS SSO Profile",
            size: NSSize(width: 400, height: 400),
            // Pass a closure for onClose, so the “Cancel” or “Save” button can close the window
            content: AddProfileView(onClose: {
                self.closeWindow(id: "addProfile")
            })
        )
    }
}

private class WindowDelegate: NSObject, NSWindowDelegate {
    let windowId: String
    
    init(id: String) {
        self.windowId = id
        super.init()
    }
    
}
