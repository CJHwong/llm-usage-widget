import AppKit
import SwiftUI

class DragView: NSView {
  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
  override func rightMouseDown(with event: NSEvent) {
    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }
}

struct WindowAccessor: NSViewRepresentable {
  @Binding var window: NSWindow?

  func makeNSView(context: Context) -> NSView {
    let v = DragView()
    DispatchQueue.main.async {
      guard let w = v.window else { return }
      window = w
      w.isOpaque = false
      w.backgroundColor = .clear
      w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
      w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
      w.isExcludedFromWindowsMenu = true
      w.hidesOnDeactivate = false
      w.styleMask.remove(.resizable)
      w.styleMask.remove(.closable)
      w.styleMask.remove(.miniaturizable)
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      w.styleMask.insert(.fullSizeContentView)
      if #available(macOS 14.0, *) { w.titlebarSeparatorStyle = .none }
      w.isMovableByWindowBackground = true
      w.standardWindowButton(.closeButton)?.isHidden = true
      w.standardWindowButton(.miniaturizeButton)?.isHidden = true
      w.standardWindowButton(.zoomButton)?.isHidden = true
      w.contentView?.wantsLayer = true
      w.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard let screen = NSScreen.screens.first else { return }
        let f = w.frame
        w.setFrameOrigin(
          NSPoint(
            x: screen.visibleFrame.maxX - f.width - 20,
            y: screen.visibleFrame.maxY - f.height - 4
          ))
      }
    }
    return v
  }
  func updateNSView(_: NSView, context: Context) {}
}

struct VisualEffectView: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = material
    v.blendingMode = blendingMode
    v.state = .active
    return v
  }
  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
