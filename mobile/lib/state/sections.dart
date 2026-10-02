import '../api/models.dart';

/// One category's part of the page, or Uncategorized's.
class Section {
  const Section({
    required this.key,
    required this.categoryId,
    required this.title,
    required this.open,
    required this.done,
  });

  /// `c<id>` for a category, `none` for Uncategorized: stable while the
  /// category keeps its id.
  final String key;
  final int? categoryId;

  /// Null when there are no categories, so the one section needs no heading.
  final String? title;

  /// Unchecked items, in list order.
  final List<Item> open;

  /// Checked items, in list order.
  final List<Item> done;
}

/// Categories in [order], with null where Uncategorized goes. Categories the
/// order doesn't know yet go after the known ones, and Uncategorized last if
/// the order lacks it.
List<Category?> arrange(List<Category> categories, List<int?> order) {
  final byId = {for (final c in categories) c.id: c};
  final known = <Category?>[
    for (final id in order)
      if (id == null) null else ?byId[id],
  ];
  final listed = order.toSet();
  return [
    ...known,
    for (final c in categories)
      if (!listed.contains(c.id)) c,
    if (!known.contains(null)) null,
  ];
}

/// One section per entry of the category order, whether or not it has
/// items, per the display conventions in /API.md. [items] must be in list
/// order. An item whose category isn't in [categories] shows as
/// uncategorized, so stale local state can't hide it. Items for which
/// [hidden] holds are left out.
List<Section> buildSections(
  List<Item> items,
  List<Category> categories,
  List<int?> order, {
  bool Function(Item item)? hidden,
}) {
  final known = {for (final c in categories) c.id};
  final byCategory = <int?, List<Item>>{};
  for (final item in items) {
    if (hidden?.call(item) ?? false) continue;
    final id = known.contains(item.categoryId) ? item.categoryId : null;
    (byCategory[id] ??= []).add(item);
  }
  return [
    for (final category in arrange(categories, order))
      _section(
        category,
        byCategory[category?.id] ?? const [],
        hasCategories: categories.isNotEmpty,
      ),
  ];
}

Section _section(
  Category? category,
  List<Item> own, {
  required bool hasCategories,
}) => Section(
  key: category == null ? 'none' : 'c${category.id}',
  categoryId: category?.id,
  title: category?.name ?? (hasCategories ? 'Uncategorized' : null),
  open: [
    for (final item in own)
      if (!item.checked) item,
  ],
  done: [
    for (final item in own)
      if (item.checked) item,
  ],
);

class Counts {
  const Counts({
    required this.open,
    required this.done,
    required this.byCategory,
    required this.uncategorized,
  });

  final int open;
  final int done;

  /// Items per category id, checked or not.
  final Map<int, int> byCategory;
  final int uncategorized;
}

Counts countItems(List<Item> items) {
  final byCategory = <int, int>{};
  var done = 0;
  var uncategorized = 0;
  for (final item in items) {
    if (item.categoryId case final id?) {
      byCategory[id] = (byCategory[id] ?? 0) + 1;
    } else {
      uncategorized++;
    }
    if (item.checked) done++;
  }
  return Counts(
    open: items.length - done,
    done: done,
    byCategory: byCategory,
    uncategorized: uncategorized,
  );
}

String summaryText(int open, int done) {
  if (open + done == 0) return 'Nothing to do';
  if (open == 0) return 'All $done done';
  return '$open to do · $done done';
}

/// The confirmation text of a Delete all that includes [open] items not done
/// yet, out of [total].
String notDoneMessage(int open, int total) {
  if (total == 1) return "This item isn't done yet.";
  if (open == total) return 'None of these $total items are done yet.';
  return '$open of these $total items ${open == 1 ? "isn't" : "aren't"} '
      'done yet.';
}

/// One PATCH's worth of fields: what a drop changes about an item. Null
/// fields stay as they are; `(id: null)` means no category, or the end of
/// the list order.
class ItemMove {
  const ItemMove({this.checked, this.category, this.before});

  final bool? checked;
  final ({int? id})? category;

  /// Moves the item directly before this one in the list order.
  final ({int? id})? before;

  bool get isEmpty => checked == null && category == null && before == null;
}

/// What dropping item [id] into the list of [categoryId]'s [checked] items
/// changes, at [index] among that list's rows other than the item itself.
/// Null when it changes nothing. Items for which [hidden] holds aren't rows.
///
/// Dropped into an empty list, the item keeps its place in the list order.
ItemMove? planDrop(
  List<Item> items,
  int id, {
  required List<Category> categories,
  required int? categoryId,
  required bool checked,
  required int index,
  bool Function(Item item)? hidden,
}) {
  final at = items.indexWhere((item) => item.id == id);
  if (at < 0) return null;
  final moving = items[at];
  final known = {for (final c in categories) c.id};
  int? effective(Item item) =>
      known.contains(item.categoryId) ? item.categoryId : null;

  final rest = [...items]..removeAt(at);
  final zone = [
    for (final item in rest)
      if (effective(item) == categoryId &&
          item.checked == checked &&
          !(hidden?.call(item) ?? false))
        item,
  ];

  ({int? id})? before;
  if (zone.isNotEmpty) {
    final int? beforeId;
    if (index < zone.length) {
      beforeId = zone[index].id;
    } else {
      final after = rest.indexOf(zone.last) + 1;
      beforeId = after < rest.length ? rest[after].id : null;
    }
    final currentNext = at + 1 < items.length ? items[at + 1].id : null;
    if (beforeId != currentNext) before = (id: beforeId);
  }
  final move = ItemMove(
    checked: moving.checked != checked ? checked : null,
    category: moving.categoryId != categoryId ? (id: categoryId) : null,
    before: before,
  );
  return move.isEmpty ? null : move;
}
