/// Pure Dart fixed-point (2 decimal places) precision helpers for weights (`kg`)
/// and currency amounts.
///
/// Prevents IEEE-754 floating-point drift across domain calculations and provides
/// consistent equality/hashing independent of backend storage (`NUMERIC(12,2)`
/// in PostgreSQL vs `num`/minor-unit fields in Cloud Firestore).
abstract final class DecimalPrecision {
  static const int _scaleFactor = 100;

  /// Converts a [double] value to rounded integer minor units (e.g. centavos or
  /// decagrams / `0.01 kg`).
  static int toMinorUnits(double value) => (value * _scaleFactor).round();

  /// Converts integer minor units back into a 2-decimal [double].
  static double fromMinorUnits(int units) => units / _scaleFactor;

  /// Rounds [value] to 2 decimal places.
  static double round2(double value) => fromMinorUnits(toMinorUnits(value));

  /// Multiplies [a] by [b] and rounds the product to 2 decimal places.
  static double multiply2(double a, double b) => round2(a * b);

  /// Adds [a] and [b] in integer minor units and converts back once.
  static double add2(double a, double b) =>
      fromMinorUnits(toMinorUnits(a) + toMinorUnits(b));

  /// Subtracts [b] from [a] in integer minor units and converts back once.
  static double subtract2(double a, double b) =>
      fromMinorUnits(toMinorUnits(a) - toMinorUnits(b));

  /// Sums [values] in integer minor units and converts back once.
  static double sum2(Iterable<double> values) {
    var totalUnits = 0;
    for (final value in values) {
      totalUnits += toMinorUnits(value);
    }
    return fromMinorUnits(totalUnits);
  }

  /// Compares [a] and [b] at 2-decimal precision.
  static int compare2(double a, double b) =>
      toMinorUnits(a).compareTo(toMinorUnits(b));

  /// Returns `true` when [a] and [b] match at 2-decimal precision.
  static bool equals2(double a, double b) =>
      toMinorUnits(a) == toMinorUnits(b);
}
