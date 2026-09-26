// Renders the README's menu images, light and dark, from synthetic content: a plain backdrop and menu
// bar drawn here, and the menu laid out by MenuHub's own code, so nothing from the machine that runs it
// appears. Needs MenuHub checked out (swift package resolve):
//   swiftc -O -parse-as-library Tools/make-readme-assets.swift .build/checkouts/menuhub/Sources/MenuHub/*.swift \
//     -o .build/make-readme-assets
//   .build/make-readme-assets assets
import AppKit

// A menu is only drawn on screen, so each one is shown briefly and its window captured. Capturing this
// process's own windows needs no Screen Recording permission. The call is gone from the SDK but not
// from the system.
typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?
let createImage = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray")!,
                                to: CreateImageFromArray.self)

let size = NSSize(width: 440, height: 214)
let barHeight: CGFloat = 24

/// The menu as MXSwipe shows it on its own, with the mouse connected.
@MainActor func makeMenu() -> NSMenu {
    let mxswipe = Member(pid: 1, name: "MXSwipe", launched: Date(), revision: 0, isActive: true,
                         header: MenuHeader(title: "MX Master 4", detail: .battery(83)), items: [
                             .action("Turn Gestures Off") {}, .separator,
                             .action("Open at Login", isOn: true) {}, .action("Check for Updates…") {},
                         ])
    let menu = NSMenu()
    MenuHub.populate(menu, with: [mxswipe], version: "0.3.0", target: nil)
    return menu
}

/// A plain desktop and menu bar: this app's icon, highlighted as it is while its menu is open, then the
/// usual system items and Apple's 9:41.
final class BackdropView: NSView {
    let iconFrame = NSRect(x: 136, y: size.height - barHeight + 2, width: 32, height: barHeight - 4)
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(srgbRed: 0.90, green: 0.88, blue: 0.84, alpha: 1)).setFill()
        bounds.fill()
        (dark ? NSColor(white: 0.26, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight).fill()
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: iconFrame, xRadius: 5, yRadius: 5).fill()
        drawSymbol("computermouse", centeredAt: iconFrame.midX)
        var x = iconFrame.maxX + 20
        for name in ["wifi", "magnifyingglass", "switch.2"] {
            drawSymbol(name, centeredAt: x)
            x += 32
        }
        let clock = NSAttributedString(string: "Tue 9:41 AM", attributes: [
            .font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        clock.draw(at: NSPoint(x: size.width - 14 - clock.size().width,
                               y: size.height - barHeight / 2 - clock.size().height / 2))
    }

    private func drawSymbol(_ name: String, centeredAt x: CGFloat) {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: NSRect(x: (x - symbol.size.width / 2).rounded(), y: (iconFrame.midY - symbol.size.height / 2).rounded(),
                               width: symbol.size.width, height: symbol.size.height))
    }
}

@MainActor func render(_ appearance: NSAppearance.Name, to url: URL) {
    NSApp.appearance = NSAppearance(named: appearance)
    let screen = NSScreen.main!.frame
    let frame = NSRect(x: screen.minX + 120, y: screen.maxY - 120 - size.height, width: size.width, height: size.height)
    let backdrop = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    let view = BackdropView(frame: NSRect(origin: .zero, size: size))
    backdrop.contentView = view
    backdrop.orderFrontRegardless()

    nonisolated(unsafe) let menu = makeMenu()
    let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
        MainActor.assumeIsolated {
            let pid = getpid()
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
            // Front to back: the menu, then the backdrop.
            var ids = windows.filter { $0[kCGWindowOwnerPID as String] as? Int32 == pid }
                .compactMap { ($0[kCGWindowNumber as String] as? CGWindowID).map { UnsafeRawPointer(bitPattern: UInt($0)) } }
            let array = CFArrayCreate(nil, &ids, ids.count, nil)!
            let rect = CGRect(x: frame.minX, y: NSScreen.screens[0].frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            let image = createImage(rect, array, [.bestResolution])!.takeRetainedValue()
            let rounded = NSImage(size: size, flipped: false) { bounds in
                NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
                NSImage(cgImage: image, size: size).draw(in: bounds)
                return true
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            rounded.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote \(url.path)")
            menu.cancelTracking()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    let anchor = backdrop.convertPoint(toScreen: NSPoint(x: view.iconFrame.minX, y: view.iconFrame.minY - 4))
    menu.popUp(positioning: nil, at: anchor, in: nil)
    backdrop.orderOut(nil)
}

@main
enum MakeReadmeAssets {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One appearance per process: a second menu in the same process never tracks.
        if CommandLine.arguments.count > 2 {
            let dark = CommandLine.arguments[2] == "dark"
            render(dark ? .darkAqua : .aqua, to: directory.appendingPathComponent(dark ? "menu-dark.png" : "menu-light.png"))
        } else {
            for mode in ["light", "dark"] {
                let child = Process()
                child.executableURL = Bundle.main.executableURL
                child.arguments = [directory.path, mode]
                try! child.run()
                child.waitUntilExit()
            }
        }
    }
}
