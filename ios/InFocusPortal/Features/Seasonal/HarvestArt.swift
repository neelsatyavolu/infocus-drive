import SwiftUI

/// Flat vector art for the harvest visitors (SwiftUI shapes, no image files), and the seasonal
/// brand images (`WordmarkHarvest`, `BrandMarkHarvest`, from the Portal's public/thanksgiving/).
enum HarvestArt {
    static let leafColors: [Color] = [Color(hex: 0xC2571A), Color(hex: 0xE0892B), Color(hex: 0xA4471C),
                                      Color(hex: 0xD9A21B), Color(hex: 0x8C2F1B)]
    static let brown = Color(hex: 0x6B3A1E)
    static let darkBrown = Color(hex: 0x4A2612)
    static let gold = Color(hex: 0xF2A93B)
    static let orange = Color(hex: 0xD9731F)
    static let cranberry = Color(hex: 0xC23A52)
    static let crust = Color(hex: 0xD99A4E)
    static let filling = Color(hex: 0xB8561C)
    static let bone = Color(hex: 0xEFE3C8)

    /// The wordmark the app shows today.
    static var wordmark: String { HarvestPalette.isActive ? "WordmarkHarvest" : "Wordmark" }
    /// The square mark the app shows today.
    static var brandMark: String { HarvestPalette.isActive ? "BrandMarkHarvest" : "BrandMark" }
}

/// A falling leaf: an SF Symbol in one of the harvest colors.
struct LeafArt: View {
    let variant: Int

    var body: some View {
        Image(systemName: "leaf.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(HarvestArt.leafColors[variant % HarvestArt.leafColors.count])
    }
}

/// A pumpkin pie in its tin, seen from the side.
struct PieArt: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .bottom) {
                // Filling dome.
                Ellipse().fill(HarvestArt.filling)
                    .frame(width: w * 0.92, height: h * 0.7)
                    .offset(y: -h * 0.28)
                // Crust rim.
                Capsule().fill(HarvestArt.crust)
                    .frame(width: w, height: h * 0.22)
                    .offset(y: -h * 0.42)
                // Tin.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.45))
                    path.addLine(to: CGPoint(x: w, y: h * 0.45))
                    path.addLine(to: CGPoint(x: w * 0.88, y: h))
                    path.addLine(to: CGPoint(x: w * 0.12, y: h))
                    path.closeSubpath()
                }
                .fill(HarvestArt.crust.opacity(0.85))
                // A dollop of cream.
                Ellipse().fill(Color(hex: 0xFFF6E6))
                    .frame(width: w * 0.28, height: h * 0.2)
                    .offset(y: -h * 0.6)
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(1.5, contentMode: .fit)
    }
}

/// A turkey facing right: a fanned tail, a round body, head, beak, wattle and legs.
struct TurkeyArt: View {
    var pardoned = false

    private static let feathers: [Color] = [HarvestArt.cranberry, HarvestArt.orange, HarvestArt.gold,
                                            HarvestArt.orange, HarvestArt.brown, HarvestArt.orange, HarvestArt.cranberry]

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width / 1.15, proxy.size.height)
            ZStack {
                // Tail fan behind the body.
                ForEach(Array(Self.feathers.enumerated()), id: \.offset) { index, color in
                    Capsule()
                        .fill(color)
                        .frame(width: s * 0.2, height: s * 0.62)
                        .offset(y: -s * 0.22)
                        .rotationEffect(.degrees(Double(index - 3) * 22), anchor: .center)
                        .offset(x: -s * 0.12, y: -s * 0.02)
                }
                // Legs.
                ForEach([-0.08, 0.06], id: \.self) { dx in
                    Capsule().fill(HarvestArt.orange)
                        .frame(width: s * 0.05, height: s * 0.2)
                        .offset(x: s * dx, y: s * 0.38)
                }
                // Body.
                Ellipse().fill(HarvestArt.brown)
                    .frame(width: s * 0.56, height: s * 0.5)
                    .offset(y: s * 0.12)
                Ellipse().fill(HarvestArt.darkBrown)
                    .frame(width: s * 0.3, height: s * 0.22)
                    .offset(x: -s * 0.06, y: s * 0.16)
                // Neck and head.
                Capsule().fill(HarvestArt.brown)
                    .frame(width: s * 0.14, height: s * 0.32)
                    .rotationEffect(.degrees(15))
                    .offset(x: s * 0.24, y: -s * 0.06)
                Circle().fill(Color(hex: 0xC9A27A))
                    .frame(width: s * 0.2, height: s * 0.2)
                    .offset(x: s * 0.3, y: -s * 0.22)
                Circle().fill(HarvestArt.darkBrown)
                    .frame(width: s * 0.04, height: s * 0.04)
                    .offset(x: s * 0.33, y: -s * 0.25)
                Triangle().fill(HarvestArt.gold)
                    .frame(width: s * 0.1, height: s * 0.07)
                    .offset(x: s * 0.44, y: -s * 0.2)
                Capsule().fill(HarvestArt.cranberry)
                    .frame(width: s * 0.05, height: s * 0.13)
                    .offset(x: s * 0.38, y: -s * 0.1)
                if pardoned {
                    Image(systemName: "medal.fill")
                        .font(.system(size: s * 0.2))
                        .foregroundStyle(HarvestArt.gold)
                        .offset(x: s * 0.06, y: s * 0.04)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// A wishbone: a rounded, upside-down V.
struct WishboneArt: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: w * 0.12, y: h * 0.95))
                path.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.12), control: CGPoint(x: w * 0.22, y: h * 0.3))
                path.addQuadCurve(to: CGPoint(x: w * 0.88, y: h * 0.95), control: CGPoint(x: w * 0.78, y: h * 0.3))
            }
            .stroke(HarvestArt.bone, style: StrokeStyle(lineWidth: max(3, w * 0.12), lineCap: .round, lineJoin: .round))
            .overlay(
                Circle().fill(HarvestArt.bone).frame(width: w * 0.26, height: w * 0.26).position(x: w * 0.5, y: h * 0.14)
            )
        }
        .aspectRatio(0.8, contentMode: .fit)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
