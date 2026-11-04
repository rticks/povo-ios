import SwiftUI
import UIKit
import PovoKit

// One measured, single-series meter palette. Text keeps semantic ink; charts
// never use the brand-yellow or status colours as arbitrary series colours.
enum PovoStyle {
    static let chartSurface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1A1A19) : UIColor(hex: 0xFCFCFB) })
    static let meter = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x3987E5) : UIColor(hex: 0x2A78D6) })
    static let meterTrack = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x184F95) : UIColor(hex: 0xCDE2FB) })
    static let brand = Color(uiColor: UIColor(hex: 0xF2D544))
    static let brandInk = Color(uiColor: UIColor(hex: 0x25251F))
}
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct UsageMeter: View {
    let fraction: Double?
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(PovoStyle.meterTrack)
                    if let fraction {
                        Capsule().fill(PovoStyle.meter).frame(width: geometry.size.width * CGFloat(min(1, max(0, fraction))))
                    }
                }
            }.frame(height: 6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(fraction.map { "残り \(Int($0 * 100)) パーセント" } ?? "割合は不明")
        .help(label)
    }
}

/// Circular ratio meter retained for the Android single-account widget, not a
/// categorical donut. It is always accompanied by the actual amounts and date.
struct RemainingRing: View {
    let fraction: Double?
    let remaining: String
    let total: String
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().stroke(PovoStyle.meterTrack, lineWidth: max(5, side * 0.055))
                if let fraction, fraction > 0 {
                    Circle().trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                        .stroke(PovoStyle.meter, style: StrokeStyle(lineWidth: max(5, side * 0.055), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 3) {
                    Text("残り").font(.system(size: max(10, side * 0.085))).foregroundStyle(.secondary)
                    Text(remaining).font(.system(size: max(15, side * 0.14), weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("/ \(total)").font(.system(size: max(10, side * 0.085))).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }.padding(side * 0.1)
            }
            .frame(width: side - 12, height: side - 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("データ残量 \(remaining)、合計 \(total)")
        .help("残量 \(remaining) / 合計 \(total)")
    }
}
