import AppIntents
import SwiftUI
import WidgetKit

/// The app's list spacing, scaled down to rows one line high. `fit` and the
/// views share it, so what's measured is what's drawn.
private struct Metrics {
  /// Replaces iOS's own content margins, which the widget turns off.
  var margin: CGFloat = 12
  var headingHeight: CGFloat = 16
  var headingGap: CGFloat = 2
  var sectionGap: CGFloat = 6
  var rowHeight: CGFloat = 26
  var rowGap: CGFloat = 2
  var moreGap: CGFloat = 2
  var moreHeight: CGFloat = 14
  /// The app's 22pt outer corners on its 56pt rows, scaled to these.
  var rowRadius: CGFloat = 10
  var boxSize: CGFloat = 16
  var boxInset: CGFloat = 8
  var titleGap: CGFloat = 8
  var rowTrailing: CGFloat = 8

  /// Headings and `+N more` sit just inside the checkboxes' edge, as in the
  /// app.
  var headingInset: CGFloat { boxInset + 2 }

  static let compact = Metrics()
}

private struct FittedSection: Identifiable {
  let id: String
  let heading: String?
  let items: [WidgetItem]
}

private struct Fitted {
  let sections: [FittedSection]
  /// Open items left out; just-checked ones don't count.
  let more: Int
}

/// Lays the sections out top-down into `height` and keeps what fits. Rows
/// stay in list order, so once a section is cut off nothing after it shows.
private func fit(_ sections: [WidgetSection], height: CGFloat, metrics M: Metrics) -> Fitted {
  func top(_ index: Int, _ section: WidgetSection) -> CGFloat {
    (index == 0 ? 0 : M.sectionGap)
      + (section.title == nil ? 0 : M.headingHeight + M.headingGap)
  }
  func rows(_ count: Int) -> CGFloat {
    CGFloat(count) * M.rowHeight + CGFloat(max(count - 1, 0)) * M.rowGap
  }
  // Half a point of slack for widget sizes that aren't whole points.
  let slack: CGFloat = 0.5

  let whole = sections.enumerated().reduce(0) { y, pair in
    y + top(pair.offset, pair.element) + rows(pair.element.items.count)
  }
  if whole <= height + slack {
    return Fitted(
      sections: sections.map { FittedSection(id: $0.id, heading: $0.title, items: $0.items) },
      more: 0
    )
  }

  let budget = height + slack - M.moreGap - M.moreHeight
  var y: CGFloat = 0
  var fitted: [FittedSection] = []
  for (index, section) in sections.enumerated() {
    let start = y + top(index, section)
    let count = section.items.indices.last { start + rows($0 + 1) <= budget }.map { $0 + 1 } ?? 0
    guard count > 0 else { break }
    let items = Array(section.items.prefix(count))
    fitted.append(FittedSection(id: section.id, heading: section.title, items: items))
    y = start + rows(count)
    if count < section.items.count { break }
  }
  let shown = Set(fitted.flatMap { $0.items.map(\.id) })
  let more = sections.flatMap(\.items).filter { !$0.checked && !shown.contains($0.id) }.count
  return Fitted(sections: fitted, more: more)
}

struct ChecklistWidgetView: View {
  let entry: ChecklistEntry
  let family: WidgetFamily

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    content
      .padding(Metrics.compact.margin)
      .containerBackground(Palette.of(scheme).surface, for: .widget)
  }

  @ViewBuilder private var content: some View {
    switch entry.state {
    case .notConnected:
      StateMessage(text: "Open CheckCheck to connect", family: family)
    case .failed:
      StateMessage(text: "Couldn't load your checklist", family: family)
    case .loaded(let sections) where sections.isEmpty:
      StateMessage(text: "Nothing to do", family: family)
    case .loaded(let sections):
      ChecklistBody(list: entry.list, sections: sections, metrics: .compact)
    }
  }
}

private struct ChecklistBody: View {
  let list: String?
  let sections: [WidgetSection]
  let metrics: Metrics

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    GeometryReader { proxy in
      let fitted = fit(headed, height: proxy.size.height, metrics: metrics)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(fitted.sections.enumerated()), id: \.element.id) { index, section in
          SectionView(section: section, metrics: metrics)
            .padding(.top, index == 0 ? 0 : metrics.sectionGap)
            .transition(.asymmetric(insertion: .rowIn, removal: .rowOut))
        }
        if fitted.more > 0 {
          Text(verbatim: "+\(fitted.more) more")
            .contentTransition(.numericText(value: Double(fitted.more)))
            .flexLine(Self.moreStyle, height: metrics.moreHeight)
            .foregroundStyle(Palette.of(scheme).onSurfaceVariant)
            .padding(.leading, metrics.headingInset)
            .padding(.top, metrics.moreGap)
            .transition(.asymmetric(insertion: .rowIn, removal: .rowOut))
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    // Like the app, the rest of the list only moves up once a leaving row
    // has played its `item-out`.
    .animation(.layout.delay(rowOutTime), value: sections)
  }

  /// One list is headed by its own name.
  private var headed: [WidgetSection] {
    guard let list else { return sections }
    return sections.map { WidgetSection(id: $0.id, title: list, items: $0.items) }
  }

  /// The app's Done label, scaled down with the rows.
  private static let moreStyle = FlexStyle(
    size: 11, lineHeight: 14, weight: 700, tracking: 0.22, tabular: true)
}

private struct SectionView: View {
  let section: FittedSection
  let metrics: Metrics

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let heading = section.heading {
        Text(heading)
          .flexLine(Self.headingStyle, height: metrics.headingHeight)
          .foregroundStyle(Palette.of(scheme).primary)
          .widgetAccentable()
          .padding(.leading, metrics.headingInset)
          .padding(.trailing, metrics.rowTrailing)
          .padding(.bottom, metrics.headingGap)
      }
      VStack(spacing: metrics.rowGap) {
        ForEach(section.items) { item in
          ItemRow(
            item: item,
            metrics: metrics,
            first: item.id == section.items.first?.id,
            last: item.id == section.items.last?.id
          )
          .transition(.asymmetric(insertion: .rowIn, removal: .rowOut))
        }
      }
    }
  }

  /// The app's section heading, scaled down with the rows.
  private static let headingStyle = FlexStyle(
    size: 12, lineHeight: 16, weight: 750, tracking: 0.24)
}

/// The app's empty state under its logo.
private struct StateMessage: View {
  let text: String
  let family: WidgetFamily

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(spacing: family == .systemSmall ? 10 : 14) {
      LogoMark(size: family == .systemSmall ? 36 : 44)
      Text(text)
        .flex(.bodyLarge)
        .multilineTextAlignment(.center)
        .foregroundStyle(Palette.of(scheme).onSurfaceVariant)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The app's ItemRow, one line high: the checkbox, then the title.
private struct ItemRow: View {
  let item: WidgetItem
  let metrics: Metrics
  let first: Bool
  let last: Bool

  @Environment(\.colorScheme) private var scheme
  @Environment(\.widgetRenderingMode) private var mode

  var body: some View {
    let palette = Palette.of(scheme)
    HStack(spacing: 0) {
      ExpressiveCheckbox(checked: item.checked, size: metrics.boxSize)
        .padding(.leading, metrics.boxInset)
        .padding(.trailing, metrics.titleGap)
        .frame(maxHeight: .infinity)
        // The box stays put outside the button so the tick can morph it;
        // a ticked row takes no second tap.
        .overlay {
          if !item.checked {
            Button(intent: CheckItemIntent(itemID: item.id)) {
              Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.identity)
          }
        }
      Text(item.title)
        .flexLine(.bodyMedium)
        .foregroundStyle(item.checked ? palette.onSurfaceVariant : palette.onSurface)
        .animation(.effects, value: item.checked)
      Spacer(minLength: metrics.rowTrailing)
    }
    .frame(height: metrics.rowHeight)
    .background {
      rowShape(first: first, last: last, outer: metrics.rowRadius)
        // Accented home screens keep only alpha: an opaque tile would turn
        // solid white.
        .fill(mode == .accented ? Color.white.opacity(0.14) : palette.surfaceContainer)
        .animation(.defaultSpatial.delay(rowOutTime), value: first)
        .animation(.defaultSpatial.delay(rowOutTime), value: last)
    }
  }
}

/// The app's checkbox: a rounded square that springs into a filled circle
/// while the tick draws itself in. The app's is 20pt; every part scales with
/// `size`.
private struct ExpressiveCheckbox: View {
  let checked: Bool
  let size: CGFloat

  @Environment(\.colorScheme) private var scheme
  @Environment(\.widgetRenderingMode) private var mode

  var body: some View {
    let palette = Palette.of(scheme)
    let unit = size / 20
    let radius = checked ? size / 2 : 6 * unit
    // Each `.animation` springs only what's inside it, so shape, color and
    // tick each keep the app's own spring.
    ZStack {
      RoundedRectangle(cornerRadius: radius, style: .circular)
        .fill(palette.primary)
        .animation(.fastSpatial, value: checked)
        .opacity(checked ? 1 : 0)
      RoundedRectangle(cornerRadius: radius, style: .circular)
        .strokeBorder(lineWidth: 2 * unit)
        .animation(.fastSpatial, value: checked)
        .foregroundStyle(checked ? palette.primary : palette.onSurfaceVariant)
      CheckTick()
        .trim(from: 0, to: checked ? 1 : 0)
        .stroke(
          palette.onPrimary,
          style: StrokeStyle(lineWidth: 3.2 * 16 / 24 * unit, lineCap: .round, lineJoin: .round)
        )
        .frame(width: 16 * unit, height: 16 * unit)
        .animation(.defaultSpatial, value: checked)
        .blendMode(mode == .accented ? .destinationOut : .normal)
    }
    .animation(.effects, value: checked)
    .compositingGroup()
    .frame(width: size, height: size)
    .scaleEffect(checked ? 1.1 : 1)
    .animation(.fastSpatial, value: checked)
    .widgetAccentable()
  }
}

/// The app's logo: web/src/favicon.svg.
private struct LogoMark: View {
  let size: CGFloat

  @Environment(\.colorScheme) private var scheme
  @Environment(\.widgetRenderingMode) private var mode

  var body: some View {
    let palette = Palette.of(scheme)
    ZStack {
      RoundedRectangle(cornerRadius: size * 10 / 32, style: .circular)
        .fill(palette.primary)
      LogoTick()
        .stroke(
          palette.onPrimary,
          style: StrokeStyle(lineWidth: size * 3.4 / 32, lineCap: .round, lineJoin: .round)
        )
        // Tinted, the tick would vanish into the square: cut it out instead.
        .blendMode(mode == .accented ? .destinationOut : .normal)
    }
    .compositingGroup()
    .frame(width: size, height: size)
    .widgetAccentable()
  }
}

/// How long the app's `item-out` plays before the row is gone.
private let rowOutTime = 0.21

extension AnyTransition {
  /// The app's `item-in`, once a row leaving in the same update is gone.
  fileprivate static var rowIn: AnyTransition {
    AnyTransition.opacity
      .combined(with: .scale(scale: 0.96))
      .combined(with: .offset(y: 12))
      .animation(.fastSpatial.delay(rowOutTime))
  }

  /// The app's `item-out`.
  fileprivate static var rowOut: AnyTransition {
    AnyTransition.opacity.combined(with: .scale(scale: 0.94)).animation(.effects)
  }
}
