#!/usr/bin/env swift
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Usage: swift scripts/render_store_assets.swift <native-captures> <output-directory>
// Native input names: promo-{iphone|ipad}-{ko|en}-{01-tasks|02-capture|03-calendar|04-languages}.png
// Uses real screenshots only. No app controls, model results, or account data are synthesized here.
struct Copy {
    let slug: String
    let koreanTitle: String
    let englishTitle: String
    let koreanDetail: String
    let englishDetail: String
    let background: String
    let dark: Bool
}
let cards: [Copy] = [
    Copy(slug: "01-tasks", koreanTitle: "오늘의 일을,\n가볍게 정리.", englishTitle: "A little clarity.\nFor every day.",
         koreanDetail: "실제 마감부터 확인하는 할 일 목록.", englishDetail: "Your tasks. Your deadlines. A clearer day.", background: "F7F7FC", dark: false),
    Copy(slug: "02-capture", koreanTitle: "생각났을 때,\n바로 기록.", englishTitle: "From a thought\nto a to-do.",
         koreanDetail: "제목부터 적고, 필요한 옵션만 더하세요.", englishDetail: "Start with a title. Add only what you need.", background: "ECE9FB", dark: false),
    Copy(slug: "03-calendar", koreanTitle: "목록에서\n날짜로.", englishTitle: "See your day.\nMake it yours.",
         koreanDetail: "할 일과 일정을 한 화면에서 확인하세요.", englishDetail: "Bring tasks and calendar events together.", background: "242433", dark: true),
    Copy(slug: "04-languages", koreanTitle: "내 언어로,\n내 방식대로.", englishTitle: "Your language.\nYour way.",
         koreanDetail: "8개 언어. 필요한 연결만 직접 선택.", englishDetail: "Eight languages. Connections you choose.", background: "F1F0F8", dark: false)
]
func color(_ hex: String) -> NSColor {
    let value = UInt32(hex, radix: 16)!
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
func rectangle(_ rect: NSRect, fill: NSColor, radius: CGFloat = 0) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
          tint: NSColor, lineHeight: CGFloat? = nil, tracking: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    if let lineHeight { paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: tint,
        .paragraphStyle: paragraph, .kern: tracking
    ]
    let string = NSAttributedString(string: value, attributes: attributes)
    let bounds = string.boundingRect(with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
    precondition(bounds.height <= rect.height + 1, "Text exceeds frame: \(value)")
    string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
}
func screenshot(_ image: NSImage, in rect: NSRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: 16)
    shadow.set()
    rectangle(rect.insetBy(dx: -5, dy: -5), fill: color("CAC8D5"), radius: radius + 5)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}
func image(at url: URL) throws -> NSImage {
    guard let image = NSImage(contentsOf: url), image.isValid else {
        throw NSError(domain: "StoreAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing native capture: \(url.path)"])
    }
    return image
}
func render(width: Int, height: Int, to url: URL, draw: () -> Void) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    print("\(width)x\(height) RGB \(url.path)")
}
let arguments = CommandLine.arguments
if arguments.count != 3 {
    fputs("Usage: swift scripts/render_store_assets.swift <native-captures> <output-directory>\n", stderr)
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let icon = try image(at: URL(fileURLWithPath: "ios/todo/Assets.xcassets/AppIcon.appiconset/icon_v1.png"))
var manifest: [[String: Any]] = []
for locale in ["ko", "en"] {
    for device in ["iphone", "ipad"] {
        let tablet = device == "ipad"
        let width = tablet ? 2732 : 1206
        let height = tablet ? 2048 : 2622
        for (index, card) in cards.enumerated() {
            let sourceName = "promo-\(device)-\(locale)-\(card.slug).png"
            let source = try image(at: input.appendingPathComponent(sourceName))
            let path = "\(locale)/\(device)-\(card.slug).png"
            let target = output.appendingPathComponent(path)
            let foreground = color(card.dark ? "FFFFFF" : "20202E")
            let muted = color(card.dark ? "CBC9DB" : "646274")
            try render(width: width, height: height, to: target) {
                rectangle(NSRect(x: 0, y: 0, width: width, height: height), fill: color(card.background))
                let margin: CGFloat = tablet ? 140 : 96
                icon.draw(in: NSRect(x: margin, y: tablet ? 142 : 76, width: 70, height: 70), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                text("SIFT", rect: NSRect(x: margin + 94, y: tablet ? 149 : 83, width: 280, height: 70),
                     size: 45, weight: .bold, tint: foreground, tracking: 2)
                text(String(format: "%02d / 04", index + 1), rect: NSRect(x: CGFloat(width) - margin - 180, y: tablet ? 162 : 95, width: 180, height: 50),
                     size: 29, weight: .medium, tint: muted, tracking: 2)
                let title = locale == "ko" ? card.koreanTitle : card.englishTitle
                let detail = locale == "ko" ? card.koreanDetail : card.englishDetail
                if tablet {
                    text(title, rect: NSRect(x: margin, y: 490, width: 780, height: 350), size: 91,
                         weight: .bold, tint: foreground, lineHeight: 120, tracking: -3)
                    text(detail, rect: NSRect(x: margin, y: 820, width: 690, height: 190), size: 37,
                         tint: muted, lineHeight: 57)
                    rectangle(NSRect(x: margin, y: 1140, width: 86, height: 7), fill: color(card.dark ? "B9B3FF" : "6556D9"))
                    text("iPad", rect: NSRect(x: margin, y: 1190, width: 500, height: 80), size: 32, weight: .medium, tint: muted)
                    let shotWidth: CGFloat = 1640
                    let shotHeight = shotWidth * source.size.height / source.size.width
                    screenshot(source, in: NSRect(x: 950, y: (CGFloat(height) - shotHeight) / 2 + 70, width: shotWidth, height: shotHeight), radius: 30)
                } else {
                    text(title, rect: NSRect(x: margin, y: 220, width: 1014, height: 245), size: 91,
                         weight: .bold, tint: foreground, lineHeight: 112, tracking: -3)
                    text(detail, rect: NSRect(x: margin, y: 480, width: 1014, height: 100), size: 34,
                         tint: muted, lineHeight: 51)
                    let shotWidth: CGFloat = 880
                    let shotHeight = shotWidth * source.size.height / source.size.width
                    precondition(shotHeight < 1950, "Expected portrait iPhone screenshot")
                    screenshot(source, in: NSRect(x: (CGFloat(width) - shotWidth) / 2, y: 622, width: shotWidth, height: shotHeight), radius: 48)
                }
            }
            manifest.append(["path": path, "locale": locale, "device": device, "width": width, "height": height,
                             "source": "captures/\(sourceName)", "syntheticSampleData": true, "alpha": false])
        }
    }
    let tasks = try image(at: input.appendingPathComponent("promo-iphone-\(locale)-01-tasks.png"))
    let calendar = try image(at: input.appendingPathComponent("promo-iphone-\(locale)-03-calendar.png"))
    for social in [false, true] {
        let width = social ? 1200 : 1600
        let height = social ? 630 : 1000
        let path = "\(locale)/\(social ? "social-preview" : "web-preview").png"
        try render(width: width, height: height, to: output.appendingPathComponent(path)) {
            rectangle(NSRect(x: 0, y: 0, width: width, height: height), fill: color("F1EFF9"))
            let margin: CGFloat = social ? 72 : 100
            icon.draw(in: NSRect(x: margin, y: social ? 70 : 100, width: 64, height: 64), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            text("SIFT", rect: NSRect(x: margin + 84, y: social ? 76 : 106, width: 250, height: 65),
                 size: 41, weight: .bold, tint: color("20202E"), tracking: 2)
            text(locale == "ko" ? "할 일과 일정,\n한곳에서." : "A clearer day.\nOne place.",
                 rect: NSRect(x: margin, y: social ? 205 : 310, width: social ? 700 : 830, height: 260),
                 size: social ? 72 : 99, weight: .bold, tint: color("20202E"), lineHeight: social ? 88 : 120, tracking: -3)
            text(locale == "ko" ? "기록하고. 확인하고. 시작하세요." : "Capture. Review. Get on with your day.",
                 rect: NSRect(x: margin, y: social ? 420 : 620, width: social ? 680 : 820, height: 120),
                 size: social ? 25 : 31, tint: color("646274"), lineHeight: 46)
            text("iPhone · iPad", rect: NSRect(x: margin, y: CGFloat(height) - 110, width: 500, height: 60),
                 size: social ? 22 : 28, weight: .medium, tint: color("6556D9"), tracking: 1)
            if social {
                screenshot(tasks, in: NSRect(x: 864, y: 55, width: 240, height: 240 * tasks.size.height / tasks.size.width), radius: 20)
            } else {
                screenshot(calendar, in: NSRect(x: 1194, y: 115, width: 302, height: 302 * calendar.size.height / calendar.size.width), radius: 24)
                screenshot(tasks, in: NSRect(x: 890, y: 244, width: 306, height: 306 * tasks.size.height / tasks.size.width), radius: 24)
            }
        }
        manifest.append(["path": path, "locale": locale, "device": "web", "width": width, "height": height,
                         "sources": ["captures/promo-iphone-\(locale)-01-tasks.png"] + (social ? [] : ["captures/promo-iphone-\(locale)-03-calendar.png"]),
                         "syntheticSampleData": true, "alpha": false])
    }
}
for index in manifest.indices {
    let file = output.appendingPathComponent(manifest[index]["path"] as! String)
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    manifest[index]["bytes"] = data.count
    manifest[index]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: output.appendingPathComponent("manifest.json"))
