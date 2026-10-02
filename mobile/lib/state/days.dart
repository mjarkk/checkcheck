import '../api/models.dart';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _months = [
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
];

/// `Today`, `Yesterday` or `Monday 28 September`, with the year when it
/// isn't [now]'s. Both are taken in local time; only their dates count.
String dayLabel(DateTime day, {required DateTime now}) {
  final local = day.toLocal();
  final today = now.toLocal();
  if (_sameDay(local, today)) return 'Today';
  if (_sameDay(local, DateTime(today.year, today.month, today.day - 1))) {
    return 'Yesterday';
  }
  final date =
      '${_weekdays[local.weekday - 1]} ${local.day} ${_months[local.month - 1]}';
  return local.year == today.year ? date : '$date ${local.year}';
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The deleted items of one local calendar day.
class DayGroup {
  const DayGroup({required this.day, required this.items});

  /// Local midnight.
  final DateTime day;

  /// In the order they were given.
  final List<DeletedItem> items;
}

/// [items] by the local day they were deleted on, newest day first.
List<DayGroup> groupByDay(List<DeletedItem> items) {
  final byDay = <DateTime, List<DeletedItem>>{};
  for (final item in items) {
    final at = item.deletedAt.toLocal();
    (byDay[DateTime(at.year, at.month, at.day)] ??= []).add(item);
  }
  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final day in days) DayGroup(day: day, items: byDay[day]!)];
}
