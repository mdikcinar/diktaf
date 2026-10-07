// Renders each HTML mockup to a PNG at twice its CSS size, cropped to the
// page's `.stage` element. WebKit rather than a browser, so it needs nothing
// beyond the Xcode command line tools and asks for no permission.
import AppKit
import WebKit

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render-mockups <out-dir> <page.html>...\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: arguments.first!)
let pages = arguments.dropFirst().map { URL(fileURLWithPath: $0) }

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    private let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1200))
    private let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1400, height: 1200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
    private var loaded: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.contentView = web
        window.orderBack(nil)
    }

    func render(_ page: URL, into dir: URL) async throws {
        await withCheckedContinuation { continuation in
            loaded = continuation
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        // Grown to the page first: a snapshot only sees what is inside the view.
        let height = try await web.evaluateJavaScript("document.documentElement.scrollHeight") as! Double
        if height > web.frame.height {
            window.setContentSize(NSSize(width: web.frame.width, height: height))
            web.frame = NSRect(x: 0, y: 0, width: web.frame.width, height: height)
        }
        try await Task.sleep(for: .milliseconds(300))
        let box = try await web.evaluateJavaScript("""
            (() => { const r = document.querySelector('.stage').getBoundingClientRect();
                     return [r.x, r.y, r.width, r.height]; })()
            """) as! [Double]
        let rect = NSRect(x: box[0], y: box[1], width: box[2], height: box[3])
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.snapshotWidth = NSNumber(value: rect.width)
        let image = try await web.takeSnapshot(configuration: config)
        let scale = 2.0
        let size = NSSize(width: rect.width * scale, height: rect.height * scale)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                      pixelsHigh: Int(size.height), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: rect.size))
        NSGraphicsContext.restoreGraphicsState()
        let out = dir.appendingPathComponent(page.deletingPathExtension().lastPathComponent + ".png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: out)
        print("  ✓ \(out.lastPathComponent)  \(Int(rect.width))×\(Int(rect.height))")
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let renderer = Renderer()
    // The window's backing scale decides the snapshot's pixel density.
    for page in pages {
        do { try await renderer.render(page, into: outDir) }
        catch { print("  ✗ \(page.lastPathComponent): \(error)"); exit(1) }
    }
    exit(0)
}
app.run()
