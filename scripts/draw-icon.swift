import AppKit
let destination = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.17, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 1000, height: 1000), xRadius: 220, yRadius: 220).fill()
let track = NSBezierPath()
track.appendArc(withCenter: NSPoint(x: 512, y: 490), radius: 300, startAngle: 215, endAngle: -35, clockwise: true)
track.lineWidth = 62; track.lineCapStyle = .round
NSColor(calibratedRed: 0.31, green: 0.38, blue: 0.41, alpha: 1).setStroke(); track.stroke()
let progress = NSBezierPath()
progress.appendArc(withCenter: NSPoint(x: 512, y: 490), radius: 300, startAngle: 215, endAngle: 50, clockwise: true)
progress.lineWidth = 62; progress.lineCapStyle = .round
NSColor(calibratedRed: 0.75, green: 0.91, blue: 0.51, alpha: 1).setStroke(); progress.stroke()
let needle = NSBezierPath(); needle.move(to: NSPoint(x: 512, y: 490)); needle.line(to: NSPoint(x: 658, y: 654)); needle.lineWidth = 48; needle.lineCapStyle = .round
NSColor.white.setStroke(); needle.stroke()
NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 467, y: 445, width: 90, height: 90)).fill()
let base = NSBezierPath(); base.move(to: NSPoint(x: 384, y: 252)); base.line(to: NSPoint(x: 640, y: 252)); base.lineWidth = 42; base.lineCapStyle = .round
NSColor(calibratedRed: 0.75, green: 0.91, blue: 0.51, alpha: 1).setStroke(); base.stroke()
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
try png.write(to: URL(fileURLWithPath: destination))
