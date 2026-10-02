import CoreText
import SwiftUI

/// The app's color roles, from server/web/src/styles.css's
/// `--md-sys-color-*` tokens.
struct Palette: Sendable {
  let primary: Color
  let onPrimary: Color
  let surface: Color
  let surfaceContainer: Color
  let onSurface: Color
  let onSurfaceVariant: Color

  static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? .dark : .light }

  static let light = Palette(
    primary: Color(hex: 0x6F19FF),
    onPrimary: Color(hex: 0xFFFFFF),
    surface: Color(hex: 0xFDF7FF),
    surfaceContainer: Color(hex: 0xF2EBFA),
    onSurface: Color(hex: 0x1D1A24),
    onSurfaceVariant: Color(hex: 0x494453)
  )

  static let dark = Palette(
    primary: Color(hex: 0xCFBCFF),
    onPrimary: Color(hex: 0x3A0092),
    surface: Color(hex: 0x15121C),
    surfaceContainer: Color(hex: 0x211E28),
    onSurface: Color(hex: 0xE7E0EF),
    onSurfaceVariant: Color(hex: 0xCBC3D5)
  )
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double(hex >> 16 & 0xFF) / 255,
      green: Double(hex >> 8 & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}

/// One of mobile/lib/theme.dart's `_flex` text styles: Roboto Flex at an
/// exact weight and width, with `opsz` following the size as CSS does.
struct FlexStyle: Sendable {
  let size: CGFloat
  let lineHeight: CGFloat
  let weight: CGFloat
  var width: CGFloat = 100
  var tracking: CGFloat = 0
  var tabular = false

  static let bodyLarge = FlexStyle(size: 16, lineHeight: 24, weight: 400)
  static let bodyMedium = FlexStyle(size: 14, lineHeight: 20, weight: 400)

  var ctFont: CTFont {
    _ = Self.registered
    var attributes: [CFString: Any] = [
      kCTFontNameAttribute: "RobotoFlex-Regular",
      kCTFontVariationAttribute: [
        Self.axis("wght"): weight,
        Self.axis("wdth"): width,
        Self.axis("opsz"): size,
      ],
    ]
    if tabular {
      attributes[kCTFontFeatureSettingsAttribute] = [
        [kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1]
      ]
    }
    let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
  }

  private static func axis(_ tag: String) -> NSNumber {
    NSNumber(value: tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
  }

  // The extension bundles the app's RobotoFlex.ttf. Registering it again
  // fails harmlessly: the name still finds the copy registered first.
  private static let registered: Bool = {
    guard let url = Bundle.main.url(forResource: "RobotoFlex", withExtension: "ttf") else {
      return false
    }
    return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }()
}

extension View {
  func flex(_ style: FlexStyle) -> some View {
    let font = style.ctFont
    let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    return self.font(Font(font))
      .tracking(style.tracking)
      .lineSpacing(max(style.lineHeight - natural, 0))
  }

  /// One line of `style`, cut off with an ellipsis, in a box of `height`
  /// (the style's line height by default) that it may overhang a little.
  func flexLine(_ style: FlexStyle, height: CGFloat? = nil) -> some View {
    flex(style)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .frame(height: height ?? style.lineHeight)
  }
}

/// mobile/lib/screens/motion.dart's springs.
extension Animation {
  static var fastSpatial: Animation { spring(ratio: 0.6, stiffness: 800) }
  static var defaultSpatial: Animation { spring(ratio: 0.8, stiffness: 380) }
  static var effects: Animation { spring(ratio: 1, stiffness: 1600) }
  static var layout: Animation { spring(ratio: 0.72, stiffness: 380) }

  private static func spring(ratio: Double, stiffness: Double) -> Animation {
    .interpolatingSpring(
      mass: 1,
      stiffness: stiffness,
      damping: 2 * ratio * stiffness.squareRoot(),
      initialVelocity: 0
    )
  }
}

/// A list's rows touch, with small inner corners and large outer ones, like
/// the app's `rowRadius`.
func rowShape(first: Bool, last: Bool, outer: CGFloat) -> UnevenRoundedRectangle {
  let inner: CGFloat = 4
  return UnevenRoundedRectangle(
    topLeadingRadius: first ? outer : inner,
    bottomLeadingRadius: last ? outer : inner,
    bottomTrailingRadius: last ? outer : inner,
    topTrailingRadius: first ? outer : inner,
    style: .circular
  )
}

/// The web checkmark's path, in its 24-unit viewBox.
struct CheckTick: Shape {
  func path(in rect: CGRect) -> Path {
    polyline([(5.5, 12.5), (9.7, 16.7), (18.5, 7.3)], units: 24, in: rect)
  }
}

/// The tick of server/web/src/favicon.svg, in its 32-unit space.
struct LogoTick: Shape {
  func path(in rect: CGRect) -> Path {
    polyline([(9, 16.5), (13.5, 21), (23, 11.5)], units: 32, in: rect)
  }
}

private func polyline(_ points: [(CGFloat, CGFloat)], units: CGFloat, in rect: CGRect) -> Path {
  let scale = rect.width / units
  var path = Path()
  path.addLines(points.map { CGPoint(x: rect.minX + $0.0 * scale, y: rect.minY + $0.1 * scale) })
  return path
}
