import 'package:meta/meta.dart';

/// Inclusive date-range filter shared across repository queries and reports.
///
/// When [endDate] has a zero time-of-day (`00:00:00.000`), [contains] treats
/// the entire calendar day of [endDate] as inclusive (matching SQL `DATE`
/// semantics as well as `TIMESTAMP` comparisons).
@immutable
final class DateRangeFilter {
  const DateRangeFilter({
    this.startDate,
    this.endDate,
  });

  final DateTime? startDate;
  final DateTime? endDate;

  /// Returns `true` when [startDate] is null or not after [endDate].
  bool get isValid {
    if (startDate == null || endDate == null) return true;
    return !startDate!.isAfter(endDate!);
  }

  /// Returns `true` when [date] falls within `[startDate, endDate]`.
  bool contains(DateTime date) {
    final target = date.toLocal();
    if (startDate != null) {
      final startLocal = startDate!.toLocal();
      final lowerBound = _isMidnight(startLocal)
          ? DateTime(startLocal.year, startLocal.month, startLocal.day)
          : startLocal;
      if (target.isBefore(lowerBound)) return false;
    }

    if (endDate != null) {
      final endLocal = endDate!.toLocal();
      final upperBound = _isMidnight(endLocal)
          ? DateTime(
              endLocal.year,
              endLocal.month,
              endLocal.day,
              23,
              59,
              59,
              999,
              999,
            )
          : endLocal;
      if (target.isAfter(upperBound)) return false;
    }

    return true;
  }

  static bool _isMidnight(DateTime dt) =>
      dt.hour == 0 &&
      dt.minute == 0 &&
      dt.second == 0 &&
      dt.millisecond == 0 &&
      dt.microsecond == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DateRangeFilter &&
          runtimeType == other.runtimeType &&
          startDate == other.startDate &&
          endDate == other.endDate;

  @override
  int get hashCode => Object.hash(runtimeType, startDate, endDate);

  @override
  String toString() =>
      'DateRangeFilter(startDate: $startDate, endDate: $endDate)';
}
