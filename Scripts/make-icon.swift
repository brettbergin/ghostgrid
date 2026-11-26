// Draws ghostgrid's app icon: a 2x2 grid of terminal panes on Mocha Black,
// the top-left pane focused with a Catppuccin blue border and a prompt.
// Usage: swift Scripts/make-icon.swift <output.png>   (1024x1024)
// Scripts/bundle.sh turns it into AppIcon.icns with sips and iconutil.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let blue = color(0x89B4FA), lavender = color(0xB4BEFE), surface = color(0x45475A)
let black = color(0x0A0A0A), base = color(0x141414), text = color(0xCDD6F4)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: the shape sits inside a 824pt square with a ~185pt radius.
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -14)
NSGraphicsContext.saveGraphicsState()
shadow.set()
black.setFill()
NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).fill()
NSGraphicsContext.restoreGraphicsState()

// A soft blue glow in the top-left, behind the focused pane.
let glow = NSGradient(colors: [blue.withAlphaComponent(0.28), blue.withAlphaComponent(0)])!
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).addClip()
glow.draw(fromCenter: NSPoint(x: tile.minX + 250, y: tile.maxY - 250), radius: 0,
          toCenter: NSPoint(x: tile.minX + 250, y: tile.maxY - 250), radius: 520, options: [])
NSGraphicsContext.restoreGraphicsState()

// Four panes with the grid's gap.
let gap: CGFloat = 34
let margin: CGFloat = 88
let area = tile.insetBy(dx: margin, dy: margin)
let cell = NSSize(width: (area.width - gap) / 2, height: (area.height - gap) / 2)
for row in 0..<2 {
    for column in 0..<2 {
        let rect = NSRect(x: area.minX + CGFloat(column) * (cell.width + gap),
                          y: area.maxY - CGFloat(row + 1) * cell.height - CGFloat(row) * gap,
                          width: cell.width, height: cell.height)
        let focused = row == 0 && column == 0
        let pane = NSBezierPath(roundedRect: rect, xRadius: 34, yRadius: 34)
        base.setFill()
        pane.fill()
        (focused ? blue : surface).setStroke()
        pane.lineWidth = focused ? 14 : 7
        pane.stroke()

        // A prompt: "❯" and a few lines of text.
        let left = rect.minX + 38
        var y = rect.maxY - 70
        (focused ? blue : surface).setFill()
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: left, y: y + 18))
        chevron.line(to: NSPoint(x: left + 22, y: y))
        chevron.line(to: NSPoint(x: left, y: y - 18))
        chevron.lineWidth = 9
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        (focused ? lavender : surface).setStroke()
        chevron.stroke()
        let widths: [CGFloat] = focused ? [150, 0, 210, 120] : [120, 180, 90]
        for width in widths {
            if width > 0 {
                (focused ? text.withAlphaComponent(0.85) : surface).setFill()
                NSBezierPath(roundedRect: NSRect(x: left + (y == rect.maxY - 70 ? 44 : 0), y: y - 7,
                                                 width: width, height: 14), xRadius: 7, yRadius: 7).fill()
            }
            y -= 46
        }
        if focused {
            blue.setFill()
            NSBezierPath(rect: NSRect(x: left + 210, y: rect.maxY - 70 - 46 * 4 - 14, width: 18, height: 34)).fill()
        }
    }
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("could not render the icon") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
