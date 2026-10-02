import 'package:checkcheck/api/models.dart';
import 'package:checkcheck/state/sections.dart';
import 'package:flutter_test/flutter_test.dart';

final _at = DateTime.utc(2026, 10, 1);

Category _category(int id, String name) =>
    Category(id: id, name: name, createdAt: _at, updatedAt: _at);

Item _item(int id, {int? category, bool checked = false}) => Item(
  id: id,
  title: 'item $id',
  checked: checked,
  categoryId: category,
  createdAt: _at.add(Duration(seconds: id)),
  updatedAt: _at,
);

void main() {
  final groceries = _category(1, 'Groceries');
  final chores = _category(2, 'Chores');
  final work = _category(3, 'Work');
  final categories = [groceries, chores, work];

  List<int?> ids(List<Category?> arranged) => [for (final c in arranged) c?.id];

  List<List<Object?>> describe(List<Section> sections) => [
    for (final s in sections)
      [
        s.key,
        s.title,
        [for (final i in s.open) i.id],
        [for (final i in s.done) i.id],
      ],
  ];

  group('arrange', () {
    test('follows the order, Uncategorized where its null is', () {
      expect(ids(arrange(categories, [3, null, 1, 2])), [3, null, 1, 2]);
    });

    test('puts categories the order lacks after the known ones', () {
      expect(ids(arrange(categories, [2, null])), [2, null, 1, 3]);
    });

    test('puts Uncategorized last when the order lacks it', () {
      expect(ids(arrange(categories, [3, 1])), [3, 1, 2, null]);
      expect(ids(arrange(categories, [])), [1, 2, 3, null]);
    });

    test('skips ids of categories that are gone', () {
      expect(ids(arrange([groceries], [9, null, 1])), [null, 1]);
    });
  });

  group('buildSections', () {
    test('one section per category in the order, empty ones too', () {
      final items = [
        _item(1, category: 1),
        _item(2),
        _item(3, category: 2, checked: true),
        _item(4, category: 1, checked: true),
        _item(5, category: 1),
      ];

      expect(describe(buildSections(items, categories, [2, null, 1, 3])), [
        [
          'c2',
          'Chores',
          [],
          [3],
        ],
        [
          'none',
          'Uncategorized',
          [2],
          [],
        ],
        [
          'c1',
          'Groceries',
          [1, 5],
          [4],
        ],
        ['c3', 'Work', [], []],
      ]);
    });

    test('without categories, one section without a heading', () {
      final items = [_item(1), _item(2, checked: true)];

      expect(describe(buildSections(items, const [], const [])), [
        [
          'none',
          null,
          [1],
          [2],
        ],
      ]);
      expect(describe(buildSections(const [], const [], const [null])), [
        ['none', null, [], []],
      ]);
    });

    test('an item of an unknown category shows as uncategorized', () {
      final items = [_item(1, category: 99), _item(2)];

      expect(describe(buildSections(items, [groceries], [1, null])), [
        ['c1', 'Groceries', [], []],
        [
          'none',
          'Uncategorized',
          [1, 2],
          [],
        ],
      ]);
    });

    test('leaves out hidden items', () {
      final items = [_item(1), _item(2), _item(3, checked: true)];

      expect(
        describe(
          buildSections(items, const [], const [], hidden: (i) => i.id != 2),
        ),
        [
          [
            'none',
            null,
            [2],
            [],
          ],
        ],
      );
    });
  });

  test('countItems counts open, done and per category', () {
    final counts = countItems([
      _item(1, category: 1),
      _item(2, category: 1, checked: true),
      _item(3),
      _item(4, category: 2, checked: true),
    ]);

    expect(counts.open, 2);
    expect(counts.done, 2);
    expect(counts.byCategory, {1: 2, 2: 1});
    expect(counts.uncategorized, 1);
  });

  test('summaryText', () {
    expect(summaryText(0, 0), 'Nothing to do');
    expect(summaryText(0, 3), 'All 3 done');
    expect(summaryText(2, 1), '2 to do · 1 done');
  });

  test('notDoneMessage', () {
    expect(notDoneMessage(1, 1), "This item isn't done yet.");
    expect(notDoneMessage(3, 3), 'None of these 3 items are done yet.');
    expect(notDoneMessage(1, 3), "1 of these 3 items isn't done yet.");
    expect(notDoneMessage(2, 3), "2 of these 3 items aren't done yet.");
  });

  group('planDrop', () {
    ItemMove? drop(
      List<Item> items,
      int id, {
      int? categoryId,
      bool checked = false,
      required int index,
      bool Function(Item item)? hidden,
    }) => planDrop(
      items,
      id,
      categories: categories,
      categoryId: categoryId,
      checked: checked,
      index: index,
      hidden: hidden,
    );

    (bool?, ({int? id})?, ({int? id})?)? fields(ItemMove? move) =>
        move == null ? null : (move.checked, move.category, move.before);

    final three = [_item(1), _item(2), _item(3)];

    test('reorders within a list', () {
      expect(fields(drop(three, 3, index: 0)), (null, null, (id: 1)));
      expect(fields(drop(three, 1, index: 1)), (null, null, (id: 3)));
    });

    test('to the end of the list order', () {
      expect(fields(drop(three, 1, index: 2)), (null, null, (id: null)));
    });

    test('to the end of a list goes before what follows it', () {
      final items = [_item(1), _item(2), _item(3, category: 1)];

      expect(fields(drop(items, 1, index: 1)), (null, null, (id: 3)));
    });

    test('back where it was changes nothing', () {
      expect(drop(three, 2, index: 1), isNull);
      expect(drop(three, 3, index: 2), isNull);
    });

    test('into an empty list keeps its place in the list order', () {
      expect(fields(drop(three, 2, checked: true, index: 0)), (
        true,
        null,
        null,
      ));
      expect(fields(drop(three, 2, categoryId: 3, index: 0)), (
        null,
        (id: 3),
        null,
      ));
    });

    test('checks into the Done list and unchecks out of it', () {
      final items = [
        _item(1),
        _item(2, checked: true),
        _item(3),
        _item(4, checked: true),
      ];

      expect(fields(drop(items, 1, checked: true, index: 1)), (
        true,
        null,
        (id: 4),
      ));
      expect(fields(drop(items, 4, index: 0)), (false, null, (id: 1)));
      // Unchecked into the open list right where it already sits.
      expect(fields(drop(items, 2, index: 1)), (false, null, null));
    });

    test('changes category', () {
      final items = [_item(1), _item(2, category: 1), _item(3, category: 1)];

      expect(fields(drop(items, 1, categoryId: 1, index: 1)), (
        null,
        (id: 1),
        (id: 3),
      ));
      expect(fields(drop(items, 3, index: 0)), (null, (id: null), (id: 1)));
    });

    test('counts only rows: hidden items are skipped', () {
      final items = [_item(1), _item(2), _item(3)];

      expect(fields(drop(items, 3, index: 0, hidden: (i) => i.id == 1)), (
        null,
        null,
        (id: 2),
      ));
    });

    test('an item of an unknown category sits in Uncategorized', () {
      final items = [_item(1, category: 99), _item(2)];

      expect(fields(drop(items, 2, index: 0)), (null, null, (id: 1)));
    });

    test('an unknown id is no drop', () {
      expect(drop(three, 9, index: 0), isNull);
    });
  });
}
