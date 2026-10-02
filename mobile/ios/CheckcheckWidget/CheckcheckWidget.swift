import SwiftUI
import WidgetKit

@main
struct CheckcheckWidgetBundle: WidgetBundle {
  var body: some Widget {
    ChecklistWidget()
  }
}

struct ChecklistWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "checklist", intent: SelectListIntent.self, provider: Provider()) {
      ChecklistEntryView(entry: $0)
    }
    .configurationDisplayName("CheckCheck")
    .description("What's still to do. Tick it off right here.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    // ChecklistWidgetView pads itself, more tightly, to fit more rows.
    .contentMarginsDisabled()
  }
}

private struct ChecklistEntryView: View {
  @Environment(\.widgetFamily) private var family
  let entry: ChecklistEntry

  var body: some View {
    ChecklistWidgetView(entry: entry, family: family)
  }
}
