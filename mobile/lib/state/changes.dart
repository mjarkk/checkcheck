import '../api/link.dart';
import '../api/models.dart';
import 'sections.dart';

class Snapshot {
  const Snapshot({
    required this.categories,
    required this.categoryOrder,
    required this.items,
    required this.deleted,
  });

  /// Reads a snapshot saved before the category order or the deleted items
  /// were, too: its order is empty, which [arrange] treats as unknown, and
  /// so is [deleted] until the next fetch.
  factory Snapshot.fromJson(Map<String, dynamic> json) => Snapshot(
    categories: [
      for (final category in json['categories'] as List)
        Category.fromJson(category as Map<String, dynamic>),
    ],
    categoryOrder: [
      for (final id in json['category_order'] as List? ?? const []) id as int?,
    ],
    items: [
      for (final item in json['items'] as List)
        Item.fromJson(item as Map<String, dynamic>),
    ],
    deleted: [
      for (final item in json['deleted'] as List? ?? const [])
        DeletedItem.fromJson(item as Map<String, dynamic>),
    ],
  );

  static const empty = Snapshot(
    categories: [],
    categoryOrder: [],
    items: [],
    deleted: [],
  );

  final List<Category> categories;

  /// As the server last sent it, or as changes left it; may lag behind
  /// [categories], see [arrange].
  final List<int?> categoryOrder;

  /// In the server's list order.
  final List<Item> items;

  /// Recently deleted, most recently deleted first; it may hold items past
  /// the server's 30 days until the next fetch.
  final List<DeletedItem> deleted;

  Snapshot withCategories(List<Category> categories) => Snapshot(
    categories: categories,
    categoryOrder: categoryOrder,
    items: items,
    deleted: deleted,
  );

  Snapshot withCategoryOrder(List<int?> categoryOrder) => Snapshot(
    categories: categories,
    categoryOrder: categoryOrder,
    items: items,
    deleted: deleted,
  );

  Snapshot withItems(List<Item> items) => Snapshot(
    categories: categories,
    categoryOrder: categoryOrder,
    items: items,
    deleted: deleted,
  );

  Snapshot withDeleted(List<DeletedItem> deleted) => Snapshot(
    categories: categories,
    categoryOrder: categoryOrder,
    items: items,
    deleted: deleted,
  );

  /// Places [category] in the order the way the server does: directly before
  /// Uncategorized when that is last, otherwise at the end.
  Snapshot withCategoryAdded(Category category) {
    final order = [for (final c in arrange(categories, categoryOrder)) c?.id];
    order.insert(
      order.last == null ? order.length - 1 : order.length,
      category.id,
    );
    return Snapshot(
      categories: [...categories, category],
      categoryOrder: order,
      items: items,
      deleted: deleted,
    );
  }

  Map<String, Object?> toJson() => {
    'categories': [for (final category in categories) category.toJson()],
    'category_order': categoryOrder,
    'items': [for (final item in items) item.toJson()],
    'deleted': [for (final item in deleted) item.toJson()],
  };
}

/// [items] with item [id] moved directly before item [beforeId], or to the
/// end when that is null or not in [items]; like the server's `before_id`.
List<Item> moveBefore(List<Item> items, int id, int? beforeId) {
  final from = items.indexWhere((item) => item.id == id);
  if (from < 0) return items;
  final rest = [...items];
  final moving = rest.removeAt(from);
  final to = beforeId == null
      ? -1
      : rest.indexWhere((item) => item.id == beforeId);
  return rest..insert(to < 0 ? rest.length : to, moving);
}

/// Something the user did that the server hasn't confirmed yet.
///
/// A negative id is temporary: it names what a [CreateItem] or
/// [CreateCategory] earlier in the queue makes, until [remap] swaps in the id
/// the server gave it.
sealed class Change {
  const Change();

  /// Throws a [FormatException] or [TypeError] for anything [toJson] didn't
  /// write.
  factory Change.fromJson(Map<String, dynamic> json) => switch (json['type']) {
    'create_item' => CreateItem(
      json['id'] as int,
      title: json['title'] as String,
      categoryId: json['category_id'] as int?,
      createdAt: DateTime.parse(json['created_at'] as String),
    ),
    'update_item' => UpdateItem(
      json['id'] as int,
      title: json['title'] as String?,
      checked: json['checked'] as bool?,
      category: json.containsKey('category_id')
          ? (id: json['category_id'] as int?)
          : null,
      before: json.containsKey('before_id')
          ? (id: json['before_id'] as int?)
          : null,
    ),
    'delete_item' => DeleteItem(
      json['id'] as int,
      // Queued before deleted items were kept.
      deletedAt: switch (json['deleted_at'] as String?) {
        final at? => DateTime.parse(at),
        null => DateTime.now().toUtc(),
      },
    ),
    'restore_item' => RestoreItem(json['id'] as int),
    'create_category' => CreateCategory(
      json['id'] as int,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    ),
    'rename_category' => RenameCategory(
      json['id'] as int,
      name: json['name'] as String,
    ),
    'delete_category' => DeleteCategory(json['id'] as int),
    'set_category_order' => SetCategoryOrder([
      for (final id in json['order'] as List) id as int?,
    ]),
    final type => throw FormatException('Unknown change type $type'),
  };

  /// The item or category this acts on; null when it acts on no single one.
  int? get target;

  Snapshot applyTo(Snapshot snapshot);

  /// Swaps the id [from] for [to]. A null [to] means [from] was never
  /// created: a change acting on it returns null, an item moving into it
  /// stays uncategorized, and one moving before it stays where it is.
  Change? remap(int from, int? to);

  Map<String, Object?> toJson();
}

final class CreateItem extends Change {
  const CreateItem(
    this.target, {
    required this.title,
    required this.categoryId,
    required this.createdAt,
  });

  @override
  final int target;
  final String title;
  final int? categoryId;
  final DateTime createdAt;

  @override
  Snapshot applyTo(Snapshot snapshot) => snapshot.withItems([
    ...snapshot.items,
    Item(
      id: target,
      title: title,
      checked: false,
      categoryId: categoryId,
      link: findLink(title),
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
  ]);

  @override
  Change? remap(int from, int? to) {
    if (target == from && to == null) return null;
    if (target != from && categoryId != from) return this;
    return CreateItem(
      target == from ? to! : target,
      title: title,
      categoryId: categoryId == from ? to : categoryId,
      createdAt: createdAt,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'create_item',
    'id': target,
    'title': title,
    'category_id': categoryId,
    'created_at': createdAt.toIso8601String(),
  };
}

/// Sets only the fields that aren't null, so it can't undo what someone else
/// changed in the others.
final class UpdateItem extends Change {
  const UpdateItem(
    this.target, {
    this.title,
    this.checked,
    this.category,
    this.before,
  });

  @override
  final int target;
  final String? title;
  final bool? checked;

  /// `(id: null)` removes the category.
  final ({int? id})? category;

  /// Moves the item directly before item `id` in the list order, or to the
  /// end when `id` is null.
  final ({int? id})? before;

  bool get isEmpty =>
      title == null && checked == null && category == null && before == null;

  UpdateItem mergedWith(UpdateItem later) => UpdateItem(
    target,
    title: later.title ?? title,
    checked: later.checked ?? checked,
    category: later.category ?? category,
    before: later.before ?? before,
  );

  /// Null when nothing would be left.
  UpdateItem? without({bool category = false, bool before = false}) {
    final rest = UpdateItem(
      target,
      title: title,
      checked: checked,
      category: category ? null : this.category,
      before: before ? null : this.before,
    );
    return rest.isEmpty ? null : rest;
  }

  @override
  Snapshot applyTo(Snapshot snapshot) {
    final items = [
      for (final item in snapshot.items)
        item.id == target
            ? item.copyWith(title: title, checked: checked, category: category)
            : item,
    ];
    return snapshot.withItems(switch (before) {
      (:final id) => moveBefore(items, target, id),
      null => items,
    });
  }

  @override
  Change? remap(int from, int? to) {
    if (target == from && to == null) return null;
    if (target != from && category?.id != from && before?.id != from) {
      return this;
    }
    final remapped = UpdateItem(
      target == from ? to! : target,
      title: title,
      checked: checked,
      category: category?.id == from ? (id: to) : category,
      before: before?.id != from
          ? before
          : to == null
          ? null
          : (id: to),
    );
    return remapped.isEmpty ? null : remapped;
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'update_item',
    'id': target,
    'title': ?title,
    'checked': ?checked,
    if (category case (:final id)) 'category_id': id,
    if (before case (:final id)) 'before_id': id,
  };
}

/// Moves the item into Recently deleted, without its category, like the
/// server.
final class DeleteItem extends Change {
  const DeleteItem(this.target, {required this.deletedAt});

  @override
  final int target;

  /// Where it goes in Recently deleted: before older deletions and after
  /// those at the same time, so deleting several at once keeps their order.
  final DateTime deletedAt;

  @override
  Snapshot applyTo(Snapshot snapshot) {
    final item = snapshot.items.where((item) => item.id == target).firstOrNull;
    if (item == null) return snapshot;
    final deleted = [
      for (final entry in snapshot.deleted)
        if (entry.id != target) entry,
    ];
    final at = deleted.indexWhere(
      (entry) => entry.deletedAt.isBefore(deletedAt),
    );
    deleted.insert(
      at < 0 ? deleted.length : at,
      DeletedItem(
        id: item.id,
        title: item.title,
        checked: item.checked,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt,
        deletedAt: deletedAt,
      ),
    );
    return snapshot
        .withItems([
          for (final item in snapshot.items)
            if (item.id != target) item,
        ])
        .withDeleted(deleted);
  }

  @override
  Change? remap(int from, int? to) => target != from
      ? this
      : to == null
      ? null
      : DeleteItem(to, deletedAt: deletedAt);

  @override
  Map<String, Object?> toJson() => {
    'type': 'delete_item',
    'id': target,
    'deleted_at': deletedAt.toIso8601String(),
  };
}

/// Like the server: the item comes back uncategorized at the end of the
/// list order, with its title and checked state.
final class RestoreItem extends Change {
  const RestoreItem(this.target);

  @override
  final int target;

  @override
  Snapshot applyTo(Snapshot snapshot) {
    final entry = snapshot.deleted
        .where((entry) => entry.id == target)
        .firstOrNull;
    if (entry == null) return snapshot;
    return snapshot
        .withItems([
          ...snapshot.items,
          Item(
            id: entry.id,
            title: entry.title,
            checked: entry.checked,
            categoryId: null,
            link: findLink(entry.title),
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
          ),
        ])
        .withDeleted([
          for (final other in snapshot.deleted)
            if (other.id != target) other,
        ]);
  }

  @override
  Change? remap(int from, int? to) => target != from
      ? this
      : to == null
      ? null
      : RestoreItem(to);

  @override
  Map<String, Object?> toJson() => {'type': 'restore_item', 'id': target};
}

final class CreateCategory extends Change {
  const CreateCategory(
    this.target, {
    required this.name,
    required this.createdAt,
  });

  @override
  final int target;
  final String name;
  final DateTime createdAt;

  @override
  Snapshot applyTo(Snapshot snapshot) => snapshot.withCategoryAdded(
    Category(
      id: target,
      name: name,
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
  );

  @override
  Change? remap(int from, int? to) => target != from
      ? this
      : to == null
      ? null
      : CreateCategory(to, name: name, createdAt: createdAt);

  @override
  Map<String, Object?> toJson() => {
    'type': 'create_category',
    'id': target,
    'name': name,
    'created_at': createdAt.toIso8601String(),
  };
}

final class RenameCategory extends Change {
  const RenameCategory(this.target, {required this.name});

  @override
  final int target;
  final String name;

  @override
  Snapshot applyTo(Snapshot snapshot) => snapshot.withCategories([
    for (final category in snapshot.categories)
      category.id == target ? category.renamed(name) : category,
  ]);

  @override
  Change? remap(int from, int? to) => target != from
      ? this
      : to == null
      ? null
      : RenameCategory(to, name: name);

  @override
  Map<String, Object?> toJson() => {
    'type': 'rename_category',
    'id': target,
    'name': name,
  };
}

/// Like the server, leaves the category's items uncategorized and the rest
/// of the order as it was.
final class DeleteCategory extends Change {
  const DeleteCategory(this.target);

  @override
  final int target;

  @override
  Snapshot applyTo(Snapshot snapshot) => Snapshot(
    categories: [
      for (final category in snapshot.categories)
        if (category.id != target) category,
    ],
    categoryOrder: [
      for (final id in snapshot.categoryOrder)
        if (id != target) id,
    ],
    items: [
      for (final item in snapshot.items)
        item.categoryId == target ? item.copyWith(category: (id: null)) : item,
    ],
    deleted: snapshot.deleted,
  );

  @override
  Change? remap(int from, int? to) => target != from
      ? this
      : to == null
      ? null
      : DeleteCategory(to);

  @override
  Map<String, Object?> toJson() => {'type': 'delete_category', 'id': target};
}

/// [order] is what the user saw; it is fitted to the server's categories
/// when sent, since others may have added or deleted some meanwhile.
final class SetCategoryOrder extends Change {
  const SetCategoryOrder(this.order);

  final List<int?> order;

  @override
  int? get target => null;

  @override
  Snapshot applyTo(Snapshot snapshot) => snapshot.withCategoryOrder(order);

  @override
  Change? remap(int from, int? to) => !order.contains(from)
      ? this
      : SetCategoryOrder([
          for (final id in order)
            if (id != from) id else ?to,
        ]);

  @override
  Map<String, Object?> toJson() => {
    'type': 'set_category_order',
    'order': order,
  };
}
