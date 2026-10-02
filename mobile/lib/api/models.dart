import 'link.dart';

class Category {
  const Category({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    id: json['id'] as int,
    name: json['name'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );

  final int id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  Category renamed(String name) =>
      Category(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };
}

/// What the server found at a link; it has at least one of [title],
/// [description] and [image].
class Preview {
  const Preview({
    this.title,
    this.description,
    this.image,
    this.siteName,
    this.icon,
  });

  factory Preview.fromJson(Map<String, dynamic> json) => Preview(
    title: json['title'] as String?,
    description: json['description'] as String?,
    image: json['image'] as String?,
    siteName: json['site_name'] as String?,
    icon: json['icon'] as String?,
  );

  final String? title;
  final String? description;
  final String? image;
  final String? siteName;
  final String? icon;

  Map<String, Object?> toJson() => {
    'title': ?title,
    'description': ?description,
    'image': ?image,
    'site_name': ?siteName,
    'icon': ?icon,
  };

  @override
  bool operator ==(Object other) =>
      other is Preview &&
      other.title == title &&
      other.description == description &&
      other.image == image &&
      other.siteName == siteName &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(title, description, image, siteName, icon);
}

class Item {
  const Item({
    required this.id,
    required this.title,
    required this.checked,
    required this.categoryId,
    required this.createdAt,
    required this.updatedAt,
    this.link,
    this.preview,
  });

  factory Item.fromJson(Map<String, dynamic> json) => Item(
    id: json['id'] as int,
    title: json['title'] as String,
    checked: json['checked'] as bool,
    categoryId: json['category_id'] as int?,
    link: json['link'] as String?,
    preview: switch (json['preview']) {
      final Map<String, dynamic> preview => Preview.fromJson(preview),
      _ => null,
    },
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );

  final int id;
  final String title;
  final bool checked;
  final int? categoryId;

  /// The first http(s) URL in [title]; see [findLink].
  final String? link;

  /// Null until the server has fetched [link], and when it found nothing
  /// there. Clients show previews by link rather than from here: see
  /// `ChecklistModel.previewOf`.
  final Preview? preview;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// `category: (id: null)` removes the category. A new [title] recomputes
  /// [link] the way the server does, dropping [preview] when the link
  /// changes.
  Item copyWith({String? title, bool? checked, ({int? id})? category}) {
    final link = title == null ? this.link : findLink(title);
    return Item(
      id: id,
      title: title ?? this.title,
      checked: checked ?? this.checked,
      categoryId: category == null ? categoryId : category.id,
      link: link,
      preview: link == this.link ? preview : null,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Item withPreview(Preview? preview) => Item(
    id: id,
    title: title,
    checked: checked,
    categoryId: categoryId,
    link: link,
    preview: preview,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'checked': checked,
    'category_id': categoryId,
    'link': link,
    'preview': preview?.toJson(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };
}

/// An item in Recently deleted, as it was when it was deleted.
class DeletedItem {
  const DeletedItem({
    required this.id,
    required this.title,
    required this.checked,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
  });

  factory DeletedItem.fromJson(Map<String, dynamic> json) => DeletedItem(
    id: json['id'] as int,
    title: json['title'] as String,
    checked: json['checked'] as bool,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    deletedAt: DateTime.parse(json['deleted_at'] as String),
  );

  final int id;
  final String title;
  final bool checked;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'checked': checked,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'deleted_at': deletedAt.toIso8601String(),
  };
}
