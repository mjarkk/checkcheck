import 'dart:async';
import 'dart:convert';

import 'package:checkcheck/api/api_client.dart';
import 'package:checkcheck/api/models.dart';
import 'package:checkcheck/state/changes.dart';
import 'package:checkcheck/state/checklist_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

final _created = DateTime.utc(2026, 9, 1, 8);
final _t0 = DateTime.utc(2026, 10, 1, 9);
final _t1 = DateTime.utc(2026, 10, 2, 9);
final _t2 = DateTime.utc(2026, 10, 2, 10);

Item _item(int id, String title, {bool checked = false, int? categoryId}) =>
    Item(
      id: id,
      title: title,
      checked: checked,
      categoryId: categoryId,
      createdAt: _created,
      updatedAt: _created,
    );

DeletedItem _gone(int id, String title, DateTime at, {bool checked = false}) =>
    DeletedItem(
      id: id,
      title: title,
      checked: checked,
      createdAt: _created,
      updatedAt: _created,
      deletedAt: at,
    );

Snapshot _snapshot({
  List<Item> items = const [],
  List<DeletedItem> deleted = const [],
}) => Snapshot(
  categories: [
    Category(
      id: 5,
      name: 'Groceries',
      createdAt: _created,
      updatedAt: _created,
    ),
  ],
  categoryOrder: const [5, null],
  items: items,
  deleted: deleted,
);

List<(int, DateTime)> _entries(Snapshot snapshot) => [
  for (final entry in snapshot.deleted) (entry.id, entry.deletedAt),
];

void main() {
  group('DeleteItem', () {
    test('moves the item into deleted, without its category', () {
      final after = DeleteItem(1, deletedAt: _t1).applyTo(
        _snapshot(
          items: [
            _item(1, 'Milk', checked: true, categoryId: 5),
            _item(2, 'Eggs'),
          ],
        ),
      );

      expect(after.items.map((i) => i.id), [2]);
      final entry = after.deleted.single;
      expect(entry.id, 1);
      expect(entry.title, 'Milk');
      expect(entry.checked, isTrue);
      expect(entry.createdAt, _created);
      expect(entry.deletedAt, _t1);
      expect(after.categories.single.id, 5);
    });

    test('goes before older deletions and after those at the same '
        'time', () {
      var snapshot = _snapshot(
        items: [_item(1, 'a'), _item(2, 'b'), _item(3, 'c')],
        deleted: [_gone(8, 'newer', _t2), _gone(9, 'older', _t0)],
      );
      for (final id in [1, 2, 3]) {
        snapshot = DeleteItem(id, deletedAt: _t1).applyTo(snapshot);
      }

      expect(_entries(snapshot), [
        (8, _t2),
        (1, _t1),
        (2, _t1),
        (3, _t1),
        (9, _t0),
      ]);
    });

    test('changes nothing for an item that is not there', () {
      final before = _snapshot(
        items: [_item(2, 'Eggs')],
        deleted: [_gone(1, 'Milk', _t0)],
      );

      final after = DeleteItem(1, deletedAt: _t1).applyTo(before);

      expect(after.items.map((i) => i.id), [2]);
      expect(_entries(after), [(1, _t0)]);
    });

    test('keeps its time through JSON and a remap', () {
      final change = Change.fromJson(
        DeleteItem(-1, deletedAt: _t1).remap(-1, 7)!.toJson(),
      );

      expect(change, isA<DeleteItem>());
      expect(change.target, 7);
      expect((change as DeleteItem).deletedAt, _t1);
      expect(DeleteItem(-1, deletedAt: _t1).remap(-1, null), isNull);
    });

    test('queued before deleted items were kept, it is deleted at the time '
        'it is read', () {
      final before = DateTime.now().subtract(const Duration(seconds: 1));

      final change = Change.fromJson({'type': 'delete_item', 'id': 3});

      expect(change.target, 3);
      final deletedAt = (change as DeleteItem).deletedAt;
      expect(deletedAt.isAfter(before), isTrue);
      expect(deletedAt.isAfter(DateTime.now()), isFalse);
    });
  });

  group('RestoreItem', () {
    test('brings the item back uncategorized at the end of the list', () {
      const title = 'Read https://example.com/post';
      final before = _snapshot(
        items: [_item(3, 'Eggs', categoryId: 5)],
        deleted: [_gone(1, title, _t1, checked: true), _gone(2, 'Bread', _t0)],
      );

      final after = const RestoreItem(1).applyTo(before);

      expect(after.items.map((i) => i.id), [3, 1]);
      final item = after.items.last;
      expect(item.title, title);
      expect(item.checked, isTrue);
      expect(item.categoryId, isNull);
      expect(item.link, 'https://example.com/post');
      expect(item.createdAt, _created);
      expect(_entries(after), [(2, _t0)]);
    });

    test('changes nothing when the item is not in deleted', () {
      final before = _snapshot(
        items: [_item(1, 'Milk')],
        deleted: [_gone(2, 'Bread', _t0)],
      );

      expect(const RestoreItem(1).applyTo(before), same(before));
    });

    test('is remapped like a delete', () {
      expect(const RestoreItem(-1).remap(-1, 7)?.target, 7);
      expect(const RestoreItem(-1).remap(-1, null), isNull);
      const other = RestoreItem(4);
      expect(other.remap(-1, 7), same(other));
    });

    test('survives JSON', () {
      final json = const RestoreItem(4).toJson();

      expect(json, {'type': 'restore_item', 'id': 4});
      final change = Change.fromJson(jsonDecode(jsonEncode(json)));
      expect(change, isA<RestoreItem>());
      expect(change.target, 4);
    });
  });

  group('Snapshot', () {
    test('keeps deleted through JSON', () {
      final snapshot = _snapshot(
        items: [_item(3, 'Eggs')],
        deleted: [_gone(1, 'Milk', _t1, checked: true), _gone(2, 'Bread', _t0)],
      );

      final read = Snapshot.fromJson(jsonDecode(jsonEncode(snapshot.toJson())));

      expect(_entries(read), [(1, _t1), (2, _t0)]);
      expect(read.deleted.first.title, 'Milk');
      expect(read.deleted.first.checked, isTrue);
    });

    test('reads one saved before deleted items were kept', () {
      final json = _snapshot(items: [_item(3, 'Eggs')]).toJson()
        ..remove('deleted');

      final read = Snapshot.fromJson(jsonDecode(jsonEncode(json)));

      expect(read.items.single.id, 3);
      expect(read.deleted, isEmpty);
    });
  });

  group('ApiClient', () {
    late List<http.Request> requests;

    ApiClient client(int status, Object body) {
      requests = [];
      return ApiClient(
        baseUrl: 'https://check.example.com',
        token: 's3cret',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
    }

    test('lists deleted items', () async {
      final api = client(200, [
        {
          'id': 9,
          'title': 'Bread',
          'checked': true,
          'created_at': '2026-10-01T15:04:05Z',
          'updated_at': '2026-10-01T15:04:06Z',
          'deleted_at': '2026-10-02T09:15:00Z',
        },
      ]);

      final deleted = await api.listDeletedItems();

      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/api/items/deleted');
      expect(deleted.single.id, 9);
      expect(deleted.single.title, 'Bread');
      expect(deleted.single.checked, isTrue);
      expect(deleted.single.deletedAt, DateTime.utc(2026, 10, 2, 9, 15));
    });

    test('restores an item with an empty POST', () async {
      final api = client(200, {
        'id': 9,
        'title': 'Bread',
        'checked': true,
        'category_id': null,
        'created_at': '2026-10-01T15:04:05Z',
        'updated_at': '2026-10-02T10:00:00Z',
      });

      final item = await api.restoreItem(9);

      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/api/items/9/restore');
      expect(requests.single.body, isEmpty);
      expect(item.id, 9);
      expect(item.categoryId, isNull);
    });

    test('a restore that is not possible is a 404', () async {
      final api = client(404, {'error': 'not found'});

      await expectLater(
        api.restoreItem(9),
        throwsA(
          isA<ServerException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  group('ChecklistModel', () {
    late FakeServer server;
    late MemoryChecklistCache cache;
    final models = <ChecklistModel>[];

    Future<ChecklistModel> open() async {
      final opened = await ChecklistModel.open(
        api: ApiClient(
          baseUrl: 'http://localhost:8081',
          token: 'dev',
          httpClient: server.client,
        ),
        cache: cache,
        onUnauthorized: () {},
      );
      models.add(opened);
      return opened;
    }

    void close(ChecklistModel model) {
      models.remove(model);
      model.dispose();
    }

    Iterable<String> sent() => server.requests
        .where((r) => r.method != 'GET')
        .map((r) => '${r.method} ${r.url.path} ${r.body}'.trim());

    List<String> deletedTitles(ChecklistModel model) => [
      for (final item in model.deletedItems) item.title,
    ];

    setUp(() {
      server = FakeServer();
      cache = MemoryChecklistCache();
    });

    tearDown(() {
      for (final model in models) {
        model.dispose();
      }
      models.clear();
    });

    test(
      'a fetch fills Recently deleted, most recently deleted first',
      () async {
        final now = DateTime.now().toUtc();
        server
          ..addDeleted(
            'older',
            deletedAt: now.subtract(const Duration(days: 2)),
          )
          ..addDeleted('newer', checked: true);
        final model = await open();

        await model.refresh();

        expect(deletedTitles(model), ['newer', 'older']);
        expect(model.deletedItems.first.checked, isTrue);
        expect(model.items, isEmpty);
      },
    );

    test('deleting moves items into Recently deleted at once, at one '
        'time', () async {
      server
        ..addItem('Milk')
        ..addItem('Eggs')
        ..addItem('Bread');
      final model = await open();
      await model.refresh();

      model.deleteItems([for (final item in model.items.take(2)) item.id]);

      expect(model.items.map((i) => i.title), ['Bread']);
      expect(deletedTitles(model), ['Milk', 'Eggs']);
      expect(model.deletedItems.map((i) => i.deletedAt).toSet(), hasLength(1));
      await pumpEventQueue();
      expect(
        server.deleted.map((i) => i['title']),
        unorderedEquals(['Milk', 'Eggs']),
      );
      expect(deletedTitles(model), ['Milk', 'Eggs']);
    });

    test('an item deleted before the server created it is not kept', () async {
      final model = await open();
      await model.refresh();
      server.offline = true;

      final milk = model.addItem('Milk');
      await pumpEventQueue();
      model.deleteItems([milk]);

      expect(model.deletedItems, isEmpty);
      server.offline = false;
      await model.refresh();
      expect(sent(), isEmpty);
      expect(model.deletedItems, isEmpty);
    });

    test('restoring shows at once, is kept while offline and is sent '
        'later', () async {
      server.addCategory('Groceries');
      server.addItem('Eggs', categoryId: 1);
      final bread = server.addDeleted('Bread', checked: true);
      final model = await open();
      await model.refresh();
      server.offline = true;

      model.restoreItem(bread['id'] as int);

      expect(model.deletedItems, isEmpty);
      expect(model.items.map((i) => (i.title, i.categoryId, i.checked)), [
        ('Eggs', 1, false),
        ('Bread', null, true),
      ]);
      await pumpEventQueue();
      close(model);

      final reopened = await open();
      expect(reopened.deletedItems, isEmpty);
      expect(reopened.items.map((i) => i.title), ['Eggs', 'Bread']);

      server.offline = false;
      await reopened.refresh();
      expect(sent(), ['POST /api/items/${bread['id']}/restore']);
      expect(server.deleted, isEmpty);
      expect(server.items.map((i) => (i['title'], i['category_id'])), [
        ('Eggs', 1),
        ('Bread', null),
      ]);
      expect(reopened.items.map((i) => i.title), ['Eggs', 'Bread']);
    });

    test('a restore made during a fetch survives its result', () async {
      final bread = server.addDeleted('Bread');
      final model = await open();
      await model.refresh();
      server.gate = Completer();

      final refreshed = model.refresh();
      await pumpEventQueue();
      model.restoreItem(bread['id'] as int);
      server.gate!.complete();
      server.gate = null;
      await refreshed;

      expect(model.deletedItems, isEmpty);
      expect(model.items.single.title, 'Bread');
      await pumpEventQueue();
      expect(server.items.single['title'], 'Bread');
      expect(model.items.single.title, 'Bread');
    });

    test('an item can be restored before its delete is sent', () async {
      server.addCategory('Groceries');
      final milk = server.addItem('Milk', categoryId: 1);
      final model = await open();
      await model.refresh();
      server.offline = true;

      model.deleteItems([milk['id'] as int]);
      model.restoreItem(milk['id'] as int);

      expect(model.items.single.categoryId, isNull);
      server.offline = false;
      await model.refresh();
      expect(sent(), [
        'DELETE /api/items/${milk['id']}',
        'POST /api/items/${milk['id']}/restore',
      ]);
      expect(model.items.single.categoryId, isNull);
      expect(model.deletedItems, isEmpty);
    });

    test('restoring what is gone from the server is dropped '
        'quietly', () async {
      final bread = server.addDeleted('Bread');
      final model = await open();
      await model.refresh();
      final failures = <ApiException>[];
      model.failures.listen(failures.add);
      server.deleted.clear();

      model.restoreItem(bread['id'] as int);
      expect(model.items.single.title, 'Bread');
      await pumpEventQueue();

      expect(failures, isEmpty);
      expect(model.items, isEmpty);
      expect(model.deletedItems, isEmpty);
    });

    test('the offline copy keeps Recently deleted', () async {
      server
        ..addItem('Milk')
        ..addDeleted(
          'Bread',
          deletedAt: DateTime.now().subtract(const Duration(hours: 1)),
        );
      final model = await open();
      await model.refresh();
      model.deleteItems([model.items.single.id]);
      await pumpEventQueue();
      close(model);
      server.offline = true;

      final reopened = await open();

      expect(deletedTitles(reopened), ['Milk', 'Bread']);
    });

    test('leaves out what was deleted more than 30 days ago', () async {
      final now = DateTime.now().toUtc();
      DeletedItem deleted(int id, Duration ago) => DeletedItem(
        id: id,
        title: 'deleted $id',
        checked: false,
        createdAt: now,
        updatedAt: now,
        deletedAt: now.subtract(ago),
      );
      cache.data = jsonEncode({
        'version': 2,
        'server': 'http://localhost:8081',
        'snapshot': Snapshot(
          categories: const [],
          categoryOrder: const [null],
          items: const [],
          deleted: [
            deleted(1, const Duration(days: 29, hours: 23)),
            deleted(2, const Duration(days: 30, minutes: 1)),
          ],
        ).toJson(),
        'pending': const [],
        'next_temp_id': -1,
      });

      final model = await open();

      expect(deletedTitles(model), ['deleted 1']);
    });
  });
}
