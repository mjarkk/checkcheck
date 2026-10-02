import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;

import '../api/api_client.dart';
import '../api/models.dart';
import 'changes.dart';
import 'checklist_cache.dart';
import 'sections.dart';

const _maxRetrySeconds = 30;

/// Every change shows at once and joins a queue that is saved to [cache]
/// together with the last server state, and sent in order in the background,
/// retrying with backoff while the server can't be reached. A fetch waits for
/// the queue, and changes made while it runs are replayed on top of its
/// result, so nothing the user did is lost to a refresh.
///
/// A change the server rejects is dropped and reported on [failures]. A 401
/// calls [onUnauthorized] and stops syncing, keeping the queue.
class ChecklistModel extends ChangeNotifier {
  ChecklistModel._({
    required this.api,
    required this.cache,
    required this.onUnauthorized,
  });

  /// Starts from what [cache] saved for [api]'s server, if anything. Nothing
  /// is fetched until [refresh].
  static Future<ChecklistModel> open({
    required ApiClient api,
    required ChecklistCache cache,
    required VoidCallback onUnauthorized,
  }) async {
    CachedChecklist? saved;
    try {
      if (await cache.read() case final data?) {
        saved = CachedChecklist.decode(data);
      }
    } on Exception {
      // Unreadable: start empty, and the first save overwrites it.
    }
    final model = ChecklistModel._(
      api: api,
      cache: cache,
      onUnauthorized: onUnauthorized,
    );
    if (saved != null && saved.server == api.baseUrl) {
      model
        .._server = saved.snapshot
        .._pending = [...saved.pending]
        .._nextTempId = saved.nextTempId
        .._previews.addAll(saved.previews)
        .._applyPending();
    }
    return model;
  }

  final ApiClient api;
  final ChecklistCache cache;
  final VoidCallback onUnauthorized;

  /// What the server last sent, plus the changes it has confirmed since.
  Snapshot? _server;

  /// Like [_server], from a fetch that finished while server updates were
  /// held; it replaces [_server] on release.
  Snapshot? _heldServer;

  /// Oldest first; only the first can be in flight.
  List<Change> _pending = [];
  Change? _sending;
  int _nextTempId = -1;

  /// Temporary id → server id, for callers still holding the temporary one.
  final _serverIds = <int, int>{};

  /// Server id → the temporary id it replaced.
  final _keys = <int, int>{};

  // By link rather than on the items: an event can arrive before the
  // response that gives an item its link.
  final _previews = <String, Preview>{};
  final _heldPreviews = <String, Preview>{};
  int _holds = 0;

  List<Category> _categories = const [];
  List<int?> _categoryOrder = const [null];
  List<Item> _items = const [];
  List<DeletedItem> _deleted = const [];

  final _failures = StreamController<ApiException>.broadcast();
  final _fetchWaiters = <Completer<void>>[];
  bool _fetchWanted = false;
  bool _fetching = false;
  bool _syncing = false;
  Timer? _retry;
  int _retrySeconds = 1;
  bool _saveScheduled = false;
  bool _disposed = false;

  /// Completed by [stopEvents]; null while not following.
  Completer<void>? _eventsStop;
  StreamSubscription<PreviewEvent>? _events;
  Timer? _eventsRetry;

  /// What the events loop waits on: the stream ending or the retry delay.
  Completer<void>? _eventsWait;

  /// In the category order.
  List<Category> get categories => _categories;

  /// Every category id once plus one null for Uncategorized, in the user's
  /// order; see [arrange].
  List<int?> get categoryOrder => _categoryOrder;

  /// In the server's list order, with local moves applied; items it hasn't
  /// created yet come last unless moved.
  List<Item> get items => _items;

  /// Recently deleted, most recently deleted first, with local deletes and
  /// restores applied: what was deleted in the last 30 days.
  List<DeletedItem> get deletedItems {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return [
      for (final item in _deleted)
        if (!item.deletedAt.isBefore(cutoff)) item,
    ];
  }

  /// Whether there is anything to show, fetched now or cached earlier.
  bool get loaded => _server != null;

  bool get loading => _fetching || (_syncing && _fetchWanted);

  /// Changes the server rejected, already dropped from the queue.
  Stream<ApiException> get failures => _failures.stream;

  /// A widget key for item or category [id] that stays the same when the
  /// server's id replaces a temporary one.
  int keyOf(int id) => _keys[id] ?? id;

  /// Also finds what [id] became if it was a temporary id.
  Category? categoryById(int? id) {
    final resolved = _serverIds[id] ?? id;
    for (final category in _categories) {
      if (category.id == resolved) return category;
    }
    return null;
  }

  /// Also finds what [id] became if it was a temporary id.
  Item? itemById(int id) {
    final resolved = _resolve(id);
    for (final item in _items) {
      if (item.id == resolved) return item;
    }
    return null;
  }

  /// The preview of [item]'s link, from whichever arrived first: a response
  /// or a server event. Previews belong to the link, not the item, so an
  /// item renamed to a link seen before shows its preview at once.
  Preview? previewOf(Item item) => switch (item.link) {
    final link? => _previews[link] ?? item.preview,
    null => null,
  };

  /// Completes once the queue is sent and a fetch after that succeeds;
  /// otherwise throws the [ApiException] that got in the way.
  Future<void> refresh() {
    if (_disposed) return Future.value();
    final fetched = Completer<void>();
    _fetchWaiters.add(fetched);
    _fetchWanted = true;
    _sync();
    return fetched.future;
  }

  /// Follows the server's event stream (link previews) until [stopEvents],
  /// reconnecting with backoff; every reconnect refreshes, since events
  /// aren't replayed. A 401 calls [onUnauthorized] and stops. Calling it
  /// again while following does nothing.
  void followEvents() {
    if (_eventsStop != null || _disposed) return;
    _followEvents(_eventsStop = Completer());
  }

  /// Closes the event stream.
  void stopEvents() {
    final stop = _eventsStop;
    if (stop == null) return;
    _eventsStop = null;
    stop.complete();
    _eventsRetry?.cancel();
    _events?.cancel();
    if (_eventsWait case final wait? when !wait.isCompleted) wait.complete();
  }

  Future<void> _followEvents(Completer<void> stop) async {
    var retrySeconds = 1;
    var connected = false;
    while (!stop.isCompleted) {
      try {
        final events = await api.events(abort: stop.future);
        if (stop.isCompleted) {
          events.listen(null).cancel();
          return;
        }
        if (connected) refresh().ignore();
        connected = true;
        retrySeconds = 1;
        await _waitForEvents(
          (done) => _events = events.listen(
            _receivePreview,
            onError: (Object error) {
              if (!done.isCompleted) done.completeError(error);
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          ),
        );
      } on UnauthorizedException {
        if (stop.isCompleted) return;
        stopEvents();
        onUnauthorized();
        return;
      } on ApiException {
        // Reconnected below.
      }
      if (stop.isCompleted) return;
      await _waitForEvents(
        (done) => _eventsRetry = Timer(
          Duration(seconds: retrySeconds),
          done.complete,
        ),
      );
      retrySeconds = min(retrySeconds * 2, _maxRetrySeconds);
    }
  }

  Future<void> _waitForEvents(void Function(Completer<void> done) start) {
    final done = _eventsWait = Completer<void>();
    start(done);
    return done.future;
  }

  void _receivePreview(PreviewEvent event) {
    if (_holds > 0) {
      _heldPreviews[event.link] = event.preview;
      return;
    }
    if (!_addPreview(_previews, event.link, event.preview)) return;
    notifyListeners();
    _scheduleSave();
  }

  /// Only adds: a response's null preview can be older than the event that
  /// already brought one.
  static bool _addPreview(
    Map<String, Preview> into,
    String? link,
    Preview? preview,
  ) {
    if (link == null || preview == null || into[link] == preview) return false;
    into[link] = preview;
    return true;
  }

  static void _addPreviewsOf(Map<String, Preview> into, List<Item> items) {
    for (final item in items) {
      _addPreview(into, item.link, item.preview);
    }
  }

  /// While held, what the server sends (fetches, events) waits until the
  /// last of as many [releaseServerUpdates], so a drag's rows don't move
  /// under it. Local changes still show at once.
  void holdServerUpdates() => _holds++;

  void releaseServerUpdates() {
    if (_holds == 0 || --_holds > 0) return;
    final held = _heldServer;
    _heldServer = null;
    if (held != null) _server = held;
    var changed = held != null;
    for (final MapEntry(:key, :value) in _heldPreviews.entries) {
      changed = _addPreview(_previews, key, value) || changed;
    }
    _heldPreviews.clear();
    if (changed) _rebuild();
  }

  /// Returns the new item's temporary id, which [keyOf] and the other
  /// methods keep accepting after the server has given it a real one.
  int addItem(String title, {int? categoryId}) {
    final id = _nextTempId--;
    _enqueue(
      CreateItem(
        id,
        title: title,
        categoryId: _serverIds[categoryId] ?? categoryId,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    return id;
  }

  /// Adds an item per title, in order, as one update of the list; returns
  /// their temporary ids, see [addItem]. They are created [checked] when
  /// asked, and directly before item [before] instead of at the end.
  List<int> addItems(
    List<String> titles, {
    int? categoryId,
    bool checked = false,
    int? before,
  }) {
    final category = _serverIds[categoryId] ?? categoryId;
    final next = before == null ? null : _resolve(before);
    final createdAt = DateTime.now().toUtc();
    final ids = <int>[];
    for (final title in titles) {
      final id = _nextTempId--;
      ids.add(id);
      _add(
        CreateItem(
          id,
          title: title,
          categoryId: category,
          createdAt: createdAt,
        ),
      );
      final placed = UpdateItem(
        id,
        checked: checked ? true : null,
        before: next == null ? null : (id: next),
      );
      if (!placed.isEmpty) _add(placed);
    }
    _changed();
    return ids;
  }

  void renameItem(int id, String title) =>
      _enqueue(UpdateItem(_resolve(id), title: title));

  void setChecked(Iterable<int> ids, bool checked) {
    for (final id in ids) {
      _add(UpdateItem(_resolve(id), checked: checked));
    }
    _changed();
  }

  /// Applies a drop as one change; see [planDrop].
  void moveItem(int id, ItemMove move) {
    final change = UpdateItem(
      _resolve(id),
      checked: move.checked,
      category: switch (move.category) {
        (:final id) => (id: _serverIds[id] ?? id),
        null => null,
      },
      before: switch (move.before) {
        (:final id) => (id: _serverIds[id] ?? id),
        null => null,
      },
    );
    if (!change.isEmpty) _enqueue(change);
  }

  /// Moves the items into [categoryId], null for Uncategorized, to the end of
  /// the list order in the order given.
  void moveItems(Iterable<int> ids, int? categoryId) {
    final category = (id: _serverIds[categoryId] ?? categoryId);
    for (final id in ids) {
      _add(UpdateItem(_resolve(id), category: category, before: (id: null)));
    }
    _changed();
  }

  /// Moves the items into Recently deleted; ones the server hasn't created
  /// yet are dropped instead, as they never existed there.
  void deleteItems(Iterable<int> ids) {
    // In whole seconds like the server's, so deletions made one by one in
    // the same second keep their order there too.
    final now = DateTime.now().toUtc();
    final deletedAt = now.subtract(
      Duration(milliseconds: now.millisecond, microseconds: now.microsecond),
    );
    for (final id in ids) {
      final resolved = _resolve(id);
      final unsent = _pending.any(
        (change) =>
            change is CreateItem &&
            change.target == resolved &&
            !identical(change, _sending),
      );
      if (unsent) {
        _pending = [
          for (final change in _pending)
            if (identical(change, _sending))
              change
            else
              ?change.remap(resolved, null),
        ];
      } else {
        _add(DeleteItem(resolved, deletedAt: deletedAt));
      }
    }
    _changed();
  }

  /// Brings item [id] back from Recently deleted, uncategorized, at the end
  /// of the list order.
  void restoreItem(int id) => _enqueue(RestoreItem(_resolve(id)));

  /// Returns the new category's temporary id. Throws [ConflictException]
  /// when a category already has [name], ignoring case.
  int addCategory(String name) {
    _checkUnique(name);
    final id = _nextTempId--;
    _enqueue(CreateCategory(id, name: name, createdAt: DateTime.now().toUtc()));
    return id;
  }

  /// The id of the category called [name], ignoring case, which is created
  /// when there is none.
  int categoryNamed(String name) {
    final lower = name.toLowerCase();
    for (final category in _categories) {
      if (category.name.toLowerCase() == lower) return category.id;
    }
    return addCategory(name);
  }

  /// Throws [ConflictException] when another category already has [name],
  /// ignoring case.
  void renameCategory(int id, String name) {
    final resolved = _resolve(id);
    _checkUnique(name, except: resolved);
    _enqueue(RenameCategory(resolved, name: name));
  }

  void deleteCategory(int id) => _enqueue(DeleteCategory(_resolve(id)));

  /// [order] lists every category id once plus one null for Uncategorized.
  void setCategoryOrder(List<int?> order) => _enqueue(
    SetCategoryOrder([for (final id in order) _serverIds[id] ?? id]),
  );

  int _resolve(int id) => _serverIds[id] ?? id;

  void _checkUnique(String name, {int? except}) {
    final lower = name.toLowerCase();
    if (_categories.any(
      (c) => c.id != except && c.name.toLowerCase() == lower,
    )) {
      throw const ConflictException('category already exists');
    }
  }

  void _enqueue(Change change) {
    _add(change);
    _changed();
  }

  void _add(Change change) {
    final last = _pending.lastOrNull;
    final merged = last == null || identical(last, _sending)
        ? null
        : switch ((last, change)) {
            (final UpdateItem earlier, final UpdateItem later)
                when earlier.target == later.target =>
              earlier.mergedWith(later),
            (SetCategoryOrder(), SetCategoryOrder()) => change,
            _ => null,
          };
    if (merged != null) {
      _pending.last = merged;
    } else {
      _pending.add(change);
    }
  }

  void _changed() {
    _rebuild();
    _sync();
  }

  Future<void> _sync() async {
    if (_syncing || _disposed) return;
    _syncing = true;
    _retry?.cancel();
    try {
      while (!_disposed) {
        if (_pending.isNotEmpty) {
          await _sendFirst();
        } else if (_fetchWanted) {
          await _fetch();
        } else {
          break;
        }
        _retrySeconds = 1;
      }
    } on UnauthorizedException catch (error) {
      _failWaiters(error);
      if (!_disposed) onUnauthorized();
    } on ApiException catch (error) {
      _failWaiters(error);
      if (!_disposed) _retry = Timer(Duration(seconds: _retrySeconds), _sync);
      _retrySeconds = min(_retrySeconds * 2, _maxRetrySeconds);
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _sendFirst() async {
    final change = _sending = _pending.first;
    try {
      await _send(change);
    } on ApiException catch (error) {
      if (!_isRejection(error)) rethrow;
      _reject(change, error);
    } finally {
      _sending = null;
    }
    _rebuild();
  }

  Future<void> _send(Change change) async {
    switch (change) {
      case CreateItem(:final target, :final title, :final categoryId):
        final item = await api.createItem(title, categoryId: categoryId);
        _settle(change);
        _remap(target, item.id);
        _addPreviewsOf(_previews, [item]);
        _updateServer((s) => s.withItems([...s.items, item]));
      case UpdateItem(:final target, :final title, :final checked):
        final item = await api.updateItem(
          target,
          title: title,
          checked: checked,
          category: change.category,
          before: change.before,
        );
        _settle(change);
        _addPreviewsOf(_previews, [item]);
        _updateServer((s) {
          final items = [for (final i in s.items) i.id == item.id ? item : i];
          return s.withItems(switch (change.before) {
            (:final id) => moveBefore(items, item.id, id),
            null => items,
          });
        });
      case DeleteItem(:final target):
        await api.deleteItem(target);
        _settle(change);
        _updateServer(change.applyTo);
      case RestoreItem(:final target):
        final item = await api.restoreItem(target);
        _settle(change);
        _addPreviewsOf(_previews, [item]);
        _updateServer(
          (s) => s.withItems([...s.items, item]).withDeleted([
            for (final entry in s.deleted)
              if (entry.id != target) entry,
          ]),
        );
      case CreateCategory(:final target, :final name):
        final category = await _createCategory(name);
        _settle(change);
        _remap(target, category.id);
        _updateServer(
          (s) => s.categories.any((c) => c.id == category.id)
              ? s
              : s.withCategoryAdded(category),
        );
      case RenameCategory(:final target, :final name):
        final category = await api.renameCategory(target, name);
        _settle(change);
        _updateServer(
          (s) => s.withCategories([
            for (final c in s.categories) c.id == category.id ? category : c,
          ]),
        );
      case DeleteCategory(:final target):
        await api.deleteCategory(target);
        _settle(change);
        _updateServer(change.applyTo);
      case SetCategoryOrder(:final order):
        final saved = await _putCategoryOrder(order);
        _settle(change);
        _updateServer((s) => s.withCategoryOrder(saved));
    }
  }

  Future<Category> _createCategory(String name) async {
    try {
      return await api.createCategory(name);
    } on ConflictException {
      // Made elsewhere while this one waited in the queue: use that one.
      final lower = name.toLowerCase();
      for (final category in await api.listCategories()) {
        if (category.name.toLowerCase() == lower) return category;
      }
      rethrow;
    }
  }

  /// The server takes only an order of exactly its categories, which others
  /// may have added to or deleted from since [order] was made.
  Future<List<int?>> _putCategoryOrder(List<int?> order) async {
    if (_server case final server?) {
      try {
        return await api.setCategoryOrder(_fitted(order, server.categories));
      } on ServerException catch (error) {
        if (error.statusCode != 400) rethrow;
      }
    }
    final [categories as List<Category>, current as List<int?>] =
        await Future.wait<Object>([api.listCategories(), api.categoryOrder()]);
    _updateServer(
      (s) => s.withCategories(categories).withCategoryOrder(current),
    );
    _fetchWanted = true;
    return api.setCategoryOrder(_fitted(order, categories));
  }

  static List<int?> _fitted(List<int?> order, List<Category> categories) => [
    for (final category in arrange(categories, order)) category?.id,
  ];

  /// 5xx and anything a proxy answered may be over by the next try.
  bool _isRejection(ApiException error) => switch (error) {
    ConflictException() => true,
    ServerException(fromApi: true, :final statusCode) => statusCode < 500,
    _ => false,
  };

  void _reject(Change change, ApiException error) {
    final status = error is ServerException ? error.statusCode : null;
    _fetchWanted = true;
    // The API's 400 for an item or category that doesn't exist (any more):
    // keep the rest of the change.
    final retry = status == 400 ? _withoutReferences(change) : null;
    if (retry != null) {
      _pending[_pending.indexOf(change)] = retry;
      return;
    }
    _pending.remove(change);
    if (change
        case CreateItem(:final target) || CreateCategory(:final target)) {
      _remap(target, null);
    }
    // A 404 means it was deleted elsewhere, which the fetch shows.
    if (status != 404 && !_disposed) _failures.add(error);
  }

  /// [change] without the next reference that may be what the server
  /// rejected: the item it moves before, then the category.
  Change? _withoutReferences(Change change) => switch (change) {
    CreateItem(categoryId: _?) => CreateItem(
      change.target,
      title: change.title,
      categoryId: null,
      createdAt: change.createdAt,
    ),
    UpdateItem(before: _?) => change.without(before: true),
    UpdateItem(category: _?) => change.without(category: true),
    _ => null,
  };

  void _settle(Change change) => _pending.remove(change);

  void _remap(int from, int? to) {
    _pending = [for (final change in _pending) ?change.remap(from, to)];
    if (to != null) {
      _serverIds[from] = to;
      _keys[to] = from;
    }
  }

  void _updateServer(Snapshot Function(Snapshot) update) {
    if (_server case final server?) _server = update(server);
    if (_heldServer case final held?) _heldServer = update(held);
  }

  Future<void> _fetch() async {
    _fetchWanted = false;
    _fetching = true;
    final waiters = [..._fetchWaiters];
    _fetchWaiters.clear();
    notifyListeners();
    try {
      final [
        categories as List<Category>,
        order as List<int?>,
        items as List<Item>,
        deleted as List<DeletedItem>,
      ] = await Future.wait<Object>([
        api.listCategories(),
        api.categoryOrder(),
        api.listItems(),
        api.listDeletedItems(),
      ]);
      final snapshot = Snapshot(
        categories: categories,
        categoryOrder: order,
        items: items,
        deleted: deleted,
      );
      if (_holds > 0 && _server != null) {
        _heldServer = snapshot;
        _addPreviewsOf(_heldPreviews, items);
      } else {
        _server = snapshot;
        _addPreviewsOf(_previews, items);
      }
    } on ApiException {
      _fetchWanted = true;
      _fetchWaiters.insertAll(0, waiters);
      rethrow;
    } finally {
      _fetching = false;
    }
    for (final waiter in waiters) {
      waiter.complete();
    }
    _rebuild();
  }

  void _failWaiters(ApiException error) {
    final waiters = [..._fetchWaiters];
    _fetchWaiters.clear();
    for (final waiter in waiters) {
      waiter.completeError(error);
    }
  }

  void _rebuild() {
    _applyPending();
    notifyListeners();
    _scheduleSave();
  }

  void _applyPending() {
    var view = _server ?? Snapshot.empty;
    for (final change in _pending) {
      view = change.applyTo(view);
    }
    final arranged = arrange(view.categories, view.categoryOrder);
    _categories = arranged.nonNulls.toList();
    _categoryOrder = [for (final c in arranged) c?.id];
    _items = view.items;
    _deleted = view.deleted;
  }

  void _scheduleSave() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    scheduleMicrotask(() {
      _saveScheduled = false;
      if (_disposed) return;
      final links = {
        for (final item in [..._items, ...?_server?.items]) ?item.link,
      };
      final saved = CachedChecklist(
        server: api.baseUrl,
        snapshot: _server,
        pending: _pending,
        nextTempId: _nextTempId,
        previews: {
          for (final MapEntry(:key, :value) in _previews.entries)
            if (links.contains(key)) key: value,
        },
      );
      // A lost write only leaves the offline copy older.
      cache.write(saved.encode()).ignore();
    });
  }

  @override
  void notifyListeners() {
    // Requests can finish after a sign-out has disposed this model.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stopEvents();
    _retry?.cancel();
    _failures.close();
    super.dispose();
  }
}
