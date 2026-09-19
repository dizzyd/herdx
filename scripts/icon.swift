// Draws HerdX.icns, one size at a time.
//
// Code rather than a checked-in design file: the icon is the app's own window —
// agent status down the sidebar, a prompt in the pane — and every colour in it
// comes from the palettes in Palette.swift. Kept as a drawing, those numbers can
// follow the app; kept as a PNG somebody exported once, they cannot.
//
//   swift scripts/icon.swift <iconset directory>
//
// Every size is drawn at its own scale rather than downsampled from 1024: the
// strokes are thin, and a resampled 32px icon comes out muddy where a drawn one
// stays crisp.

import AppKit

let canvas: CGFloat = 1024

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: icon.swift <iconset directory>\n".data(using: .utf8)!)
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// The palette is the app's: `Theme.dark` for the terminal, the sidebar's agent
// status colours for the dots, and the accent blue the chrome tints with.
let paneBackground = rgb(13, 16, 24)
let sidebarBackground = rgb(28, 33, 46)
let plateTop = rgb(86, 142, 240)
let plateBottom = rgb(38, 72, 170)
let cursorBlue = rgb(160, 200, 255)
let statusColours = [rgb(122, 214, 130), rgb(242, 192, 106), rgb(238, 108, 118)]

/// A superellipse, which is the shape of a Mac app icon.
///
/// Not `CGPath(roundedRect:)`: that corner is a circular arc, and beside the
/// icons already in the Dock it reads as subtly the wrong shape.
func squircle(in rect: CGRect) -> CGPath {
    let exponent: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    let path = CGMutablePath()
    let steps = 1440
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let (ct, st) = (cos(t), sin(t))
        let point = CGPoint(
            x: rect.midX + a * pow(abs(ct), 2 / exponent) * (ct < 0 ? -1 : 1),
            y: rect.midY + b * pow(abs(st), 2 / exponent) * (st < 0 ? -1 : 1))
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// The prompt mark — chevron and cursor — centred in a rect.
func prompt(_ ctx: CGContext, centeredIn rect: CGRect, height: CGFloat) {
    let arm = height / 2
    let barHeight = height * 0.2
    let width = height * 0.13 + height * 0.53 + height * 0.34 + height * 0.92
    let x = rect.midX - width / 2 + height * 0.13
    let y = rect.midY

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(height * 0.26)
    ctx.setStrokeColor(rgb(255, 255, 255))
    ctx.move(to: CGPoint(x: x, y: y + arm))
    ctx.addLine(to: CGPoint(x: x + arm * 1.06, y: y))
    ctx.addLine(to: CGPoint(x: x, y: y - arm))
    ctx.strokePath()

    let bar = CGRect(
        x: x + arm * 1.06 + height * 0.34, y: y - arm - barHeight / 2 + height * 0.06,
        width: height * 0.92, height: barHeight)
    ctx.setFillColor(cursorBlue)
    ctx.addPath(
        CGPath(
            roundedRect: bar, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2,
            transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

func draw(_ ctx: CGContext) {
    // 824 in 1024 is the proportion Apple's own macOS icons leave; filling the
    // square makes the icon look a size larger than everything beside it.
    let inset = (canvas - 824) / 2
    let plate = CGRect(x: inset, y: inset, width: 824, height: 824)
    let platePath = squircle(in: plate)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    ctx.drawLinearGradient(
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [plateTop, plateBottom] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()

    let window = CGRect(
        x: plate.minX + 88, y: plate.minY + 118,
        width: plate.width - 176, height: plate.height - 236)
    let windowPath = CGPath(roundedRect: window, cornerWidth: 58, cornerHeight: 58, transform: nil)

    ctx.saveGState()
    ctx.addPath(windowPath)
    ctx.clip()
    ctx.setFillColor(paneBackground)
    ctx.fill(window)

    let sidebar = CGRect(x: window.minX, y: window.minY, width: 208, height: window.height)
    ctx.setFillColor(sidebarBackground)
    ctx.fill(sidebar)
    ctx.setFillColor(rgb(255, 255, 255, 0.10))
    ctx.fill(CGRect(x: sidebar.maxX - 3, y: sidebar.minY, width: 3, height: sidebar.height))

    // Three agents, one of each state. Blocked is the one that has to catch the
    // eye in the app, so it is the one that has to survive being 32 pixels wide.
    for (row, colour) in statusColours.enumerated() {
        let y = window.midY + 70 - CGFloat(row) * 112
        ctx.setFillColor(colour)
        ctx.fillEllipse(in: CGRect(x: sidebar.minX + 46, y: y, width: 52, height: 52))
        ctx.setFillColor(rgb(255, 255, 255, 0.22))
        let label = CGRect(x: sidebar.minX + 118, y: y + 16, width: 52, height: 20)
        ctx.addPath(CGPath(roundedRect: label, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
    }

    prompt(
        ctx,
        centeredIn: CGRect(
            x: sidebar.maxX, y: window.minY,
            width: window.maxX - sidebar.maxX, height: window.height),
        height: 196)
    ctx.restoreGState()

    // A lit edge on the window, so the dark rectangle reads as sitting on the
    // plate rather than being a hole cut out of it.
    ctx.addPath(windowPath)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.22))
    ctx.setLineWidth(5)
    ctx.strokePath()
}

func write(size: CGFloat, to name: String) {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: size / canvas, y: size / canvas)
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    let url = outputDirectory.appendingPathComponent(name)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try! data.write(to: url)
}

// The ten files `iconutil` expects, by the names it expects.
for point in [16, 32, 128, 256, 512] {
    write(size: CGFloat(point), to: "icon_\(point)x\(point).png")
    write(size: CGFloat(point * 2), to: "icon_\(point)x\(point)@2x.png")
}
print("drew 10 sizes into \(outputDirectory.path)")
