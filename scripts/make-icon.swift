import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.98, green: 0.84, blue: 0.27, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 200, yRadius: 200).fill()
NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.13, alpha: 1).setFill()
let cloud = NSBezierPath(roundedRect: NSRect(x: 240, y: 320, width: 555, height: 230), xRadius: 115, yRadius: 115)
cloud.appendOval(in: NSRect(x: 330, y: 405, width: 320, height: 320))
cloud.appendOval(in: NSRect(x: 540, y: 365, width: 220, height: 220))
cloud.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
