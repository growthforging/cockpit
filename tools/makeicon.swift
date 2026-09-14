import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
// Apple's icon grid: 824pt squircle centred in 1024.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)
// soft drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor(calibratedWhite: 0.05, alpha: 1).setFill(); squircle.fill()
ctx.restoreGState()
// body gradient
ctx.saveGState(); squircle.addClip()
let g = NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.145, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.025, alpha: 1)])!
g.draw(in: rect, angle: -90)
// top inner highlight
let hl = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
hl.lineWidth = 3; NSColor.white.withAlphaComponent(0.08).setStroke(); hl.stroke()
ctx.restoreGState()
// gauge ring: 270° sweep, open at the bottom
let c = CGPoint(x: size/2, y: size/2 + 8)
let r: CGFloat = 250
let lw: CGFloat = 62
func arc(_ from: CGFloat, _ to: CGFloat) -> NSBezierPath {
    let p = NSBezierPath(); p.appendArc(withCenter: c, radius: r, startAngle: from, endAngle: to, clockwise: true)
    p.lineWidth = lw; p.lineCapStyle = .round; return p
}
NSColor.white.withAlphaComponent(0.10).setStroke(); arc(225, -45).stroke()
// progress ~ 68% of the sweep, emerald with a mint tip glow
let sweep: CGFloat = 270 * 0.68
let endAngle = 225 - sweep
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 28, color: NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.6, alpha: 0.55).cgColor)
NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1).setStroke(); arc(225, endAngle).stroke()
ctx.restoreGState()
// bright tip dot
let tip = CGPoint(x: c.x + r * cos(endAngle * .pi/180), y: c.y + r * sin(endAngle * .pi/180))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: NSColor.white.withAlphaComponent(0.9).cgColor)
NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: tip.x - 20, y: tip.y - 20, width: 40, height: 40)).fill()
ctx.restoreGState()
// centre readout mark: a small white bar (the notch) under the ring centre
let bar = NSBezierPath(roundedRect: CGRect(x: c.x - 70, y: c.y - 16, width: 140, height: 32), xRadius: 16, yRadius: 16)
NSColor.white.withAlphaComponent(0.92).setFill(); bar.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote", CommandLine.arguments[1])
