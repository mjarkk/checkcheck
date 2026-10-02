import 'package:checkcheck/api/models.dart';
import 'package:checkcheck/state/days.dart';
import 'package:flutter_test/flutter_test.dart';

DeletedItem _deleted(String title, DateTime at) => DeletedItem(
  id: title.hashCode,
  title: title,
  checked: false,
  createdAt: at,
  updatedAt: at,
  deletedAt: at.toUtc(),
);

void main() {
  final now = DateTime(2026, 10, 2, 14);

  group('dayLabel', () {
    test('says Today for any time today', () {
      expect(dayLabel(DateTime(2026, 10, 2), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 10, 2, 23, 59, 59), now: now), 'Today');
    });

    test('says Yesterday for any time the day before', () {
      expect(dayLabel(DateTime(2026, 10, 1), now: now), 'Yesterday');
      expect(
        dayLabel(DateTime(2026, 10, 1, 23, 59, 59), now: now),
        'Yesterday',
      );
      expect(
        dayLabel(DateTime(2026, 2, 28, 12), now: DateTime(2026, 3, 1, 1)),
        'Yesterday',
      );
      expect(
        dayLabel(DateTime(2025, 12, 31, 23), now: DateTime(2026, 1, 1, 9)),
        'Yesterday',
      );
    });

    test('gives the weekday, day and month before that', () {
      expect(
        dayLabel(DateTime(2026, 9, 30), now: now),
        'Wednesday 30 September',
      );
      expect(
        dayLabel(DateTime(2026, 9, 28, 8), now: now),
        'Monday 28 September',
      );
      expect(
        [
          for (var day = 21; day <= 27; day++) DateTime(2026, 9, day),
        ].map((day) => dayLabel(day, now: now).split(' ').first),
        [
          'Monday',
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
          'Sunday',
        ],
      );
      expect(
        [
          for (var month = 1; month <= 12; month++) DateTime(2026, month, 1),
        ].map(
          (day) => dayLabel(day, now: DateTime(2026, 12, 31)).split(' ')[2],
        ),
        [
          'January',
          'February',
          'March',
          'April',
          'May',
          'June',
          'July',
          'August',
          'September',
          'October',
          'November',
          'December',
        ],
      );
    });

    test('adds the year when it is not this one', () {
      expect(
        dayLabel(DateTime(2025, 12, 31), now: DateTime(2026, 1, 2)),
        'Wednesday 31 December 2025',
      );
      expect(
        dayLabel(DateTime(2025, 9, 28), now: now),
        'Sunday 28 September 2025',
      );
    });

    test('goes by the local day of a UTC time', () {
      expect(dayLabel(DateTime(2026, 10, 2, 0, 30).toUtc(), now: now), 'Today');
      expect(
        dayLabel(DateTime(2026, 10, 1, 23, 30).toUtc(), now: now.toUtc()),
        'Yesterday',
      );
    });
  });

  group('groupByDay', () {
    test('groups by local day, newest first, keeping the order within', () {
      final groups = groupByDay([
        _deleted('a', DateTime(2026, 10, 2, 9)),
        _deleted('b', DateTime(2026, 10, 2, 0, 10)),
        _deleted('c', DateTime(2026, 10, 1, 23, 50)),
        _deleted('d', DateTime(2026, 10, 2, 0, 10)),
        _deleted('e', DateTime(2026, 9, 28, 12)),
      ]);

      expect(groups.map((g) => g.day), [
        DateTime(2026, 10, 2),
        DateTime(2026, 10, 1),
        DateTime(2026, 9, 28),
      ]);
      expect(groups.map((g) => g.items.map((i) => i.title).join()), [
        'abd',
        'c',
        'e',
      ]);
    });

    test('is empty without items', () {
      expect(groupByDay(const []), isEmpty);
    });
  });
}
