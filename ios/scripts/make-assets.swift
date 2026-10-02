// Renders the app's brand images into InFocusPortal/Assets.xcassets from the
// InFocus 2026 logo package (DESIGN.md §1), flat per the design system:
//   AppIcon      the icon in one color (Soft White) on InFocus Green. The color
//                icon's green ring would vanish on a green tile, and the mono
//                look also sets the Portal apart from the public InFocus app.
//   LaunchMark   the color icon for the launch screen (on Ink)
//   BrandMark    the color icon for in-app screens
//   Wordmark     color wordmark (light) / white wordmark (dark)
// Run from ios/:  swift scripts/make-assets.swift "<path to 01 Logos>"
import AppKit

guard CommandLine.arguments.count == 2 else {
    print("usage: swift scripts/make-assets.swift \"<path to 01 Logos>\"")
    exit(2)
}
let logos = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = URL(fileURLWithPath: "InFocusPortal/Assets.xcassets")

func load(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: logos.appendingPathComponent(path)) else {
        FileHandle.standardError.write("missing \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return image
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let infocusGreen = color(0x0B6E3E)
let softWhite = color(0xECEFEA)

/// Draws into a sRGB bitmap and returns PNG data (`opaque` drops the alpha channel).
func png(width: Int, height: Int, opaque: Bool = false, draw: (CGContext, CGRect) -> Void) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    context.interpolationQuality = .high
    draw(context, CGRect(x: 0, y: 0, width: width, height: height))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func cg(_ image: NSImage) -> CGImage {
    image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

/// `image` in a single color: its shape, filled.
func mono(_ image: NSImage, _ tint: NSColor) -> CGImage {
    let data = png(width: 1024, height: 1024) { context, rect in
        context.draw(cg(image), in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(tint.cgColor)
        context.fill(rect)
    }
    return cg(NSImage(data: data)!)
}

func write(_ data: Data, _ set: String, _ name: String) {
    let folder = assets.appendingPathComponent(set)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try! data.write(to: folder.appendingPathComponent(name))
}

func writeJSON(_ json: String, _ folder: String) {
    let url = assets.appendingPathComponent(folder)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try! json.write(to: url.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

let icon = load("Icon/infocus-icon-color.png")
let iconWhite = load("Icon/infocus-icon-white.png")
let wordmarkColor = load("Wordmark/infocus-wordmark-color.png")
let wordmarkWhite = load("Wordmark/infocus-wordmark-white.png")

// App icon: full-bleed 1024, no alpha (iOS applies the mask).
let markOnGreen = mono(iconWhite, softWhite)
write(png(width: 1024, height: 1024, opaque: true) { context, rect in
    context.setFillColor(infocusGreen.cgColor)
    context.fill(rect)
    let side = rect.width * 0.62
    context.draw(markOnGreen, in: CGRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2, width: side, height: side))
}, "AppIcon.appiconset", "AppIcon.png")
writeJSON("""
{
  "images" : [ { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "AppIcon.appiconset")

/// A square image at @2x and @3x for `points`.
func scaled(_ image: NSImage, points: Int, set: String) {
    let name = String(set.prefix { $0 != "." })
    for scale in [2, 3] {
        let side = points * scale
        write(png(width: side, height: side) { context, rect in context.draw(cg(image), in: rect) }, set, "\(name)@\(scale)x.png")
    }
    writeJSON("""
    {
      "images" : [
        { "idiom" : "universal", "scale" : "1x" },
        { "filename" : "\(name)@2x.png", "idiom" : "universal", "scale" : "2x" },
        { "filename" : "\(name)@3x.png", "idiom" : "universal", "scale" : "3x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """, set)
}

scaled(icon, points: 120, set: "LaunchMark.imageset")
scaled(icon, points: 96, set: "BrandMark.imageset")

// Wordmark: 4107 × 1100 masters → 220pt wide, color in light mode, white in dark.
let wordWidth = 220, wordHeight = Int((Double(wordWidth) * 1100 / 4107).rounded())
for (image, suffix) in [(wordmarkColor, ""), (wordmarkWhite, "-dark")] {
    for scale in [2, 3] {
        write(png(width: wordWidth * scale, height: wordHeight * scale) { context, rect in context.draw(cg(image), in: rect) },
              "Wordmark.imageset", "Wordmark\(suffix)@\(scale)x.png")
    }
}
writeJSON("""
{
  "images" : [
    { "idiom" : "universal", "scale" : "1x" },
    { "filename" : "Wordmark@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "Wordmark@3x.png", "idiom" : "universal", "scale" : "3x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "idiom" : "universal", "scale" : "1x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "Wordmark-dark@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "Wordmark-dark@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "Wordmark.imageset")

// The launch screen is Ink in both appearances (the Portal is dark by default).
writeJSON("""
{
  "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "0x0F", "green" : "0x11", "red" : "0x0F" } }, "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "LaunchBackground.colorset")
writeJSON("""
{ "info" : { "author" : "xcode", "version" : 1 } }
""", "")
print("wrote InFocusPortal/Assets.xcassets")
