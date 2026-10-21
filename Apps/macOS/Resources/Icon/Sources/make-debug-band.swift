import AppKit

let size = 1024
let ctx = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Band near the bottom, full width: the system mask rounds its ends with the icon.
let bandTop = 300.0, bandHeight = 170.0  // in CG coordinates (origin bottom-left)
ctx.setFillColor(CGColor(srgbRed: 0.84, green: 0.11, blue: 0.13, alpha: 1))
ctx.fill(CGRect(x: 0, y: bandTop - bandHeight, width: Double(size), height: bandHeight))
let font = NSFont.systemFont(ofSize: 120, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: 8]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "DEBUG", attributes: attrs))
let b = CTLineGetImageBounds(line, ctx)
ctx.textPosition = CGPoint(
  x: (Double(size) - b.width) / 2 - b.minX,
  y: bandTop - bandHeight / 2 - b.height / 2 - b.minY)
CTLineDraw(line, ctx)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(
  to: URL(fileURLWithPath: CommandLine.arguments[1]))
