import 'package:checkcheck/api/api_client.dart';
import 'package:checkcheck/screens/checklist_screen.dart';
import 'package:checkcheck/screens/item_row.dart';
import 'package:checkcheck/state/checklist_model.dart';
import 'package:checkcheck/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A model on [server] that has fetched once.
Future<ChecklistModel> openModel(FakeServer server) async {
  final model = await ChecklistModel.open(
    api: ApiClient(
      baseUrl: 'http://localhost',
      token: server.token,
      httpClient: server.client,
    ),
    cache: MemoryChecklistCache(),
    onUnauthorized: () {},
  );
  addTearDown(model.dispose);
  await model.refresh();
  return model;
}

Widget app(Widget home) =>
    MaterialApp(theme: buildTheme(Brightness.light), home: home);

/// The checklist screen on [server], settled.
Future<ChecklistModel> pumpScreen(
  WidgetTester tester,
  FakeServer server, {
  Size size = const Size(402, 874),
}) async {
  tester.view
    ..physicalSize = size * 3
    ..devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final model = await openModel(server);
  await tester.pumpWidget(
    app(ChecklistScreen(model: model, onDisconnect: () {})),
  );
  await tester.pumpAndSettle();
  return model;
}

/// The editable field showing [title].
Finder titleFieldOf(String title) => find.byWidgetPredicate(
  (widget) => widget is EditableText && widget.controller.text == title,
);

/// The row showing the item titled [title].
Finder rowOf(String title) =>
    find.ancestor(of: titleFieldOf(title), matching: find.byType(ItemRow));

Finder inRow(String title, Finder finder) =>
    find.descendant(of: rowOf(title), matching: finder);

/// The Add item line labelled [label].
Finder addLine(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

Finder addField(String label) =>
    find.descendant(of: addLine(label), matching: find.byType(EditableText));

/// The PATCH bodies the server got, oldest first.
List<String> patches(FakeServer server) => [
  for (final request in server.requests)
    if (request.method == 'PATCH') request.body,
];
