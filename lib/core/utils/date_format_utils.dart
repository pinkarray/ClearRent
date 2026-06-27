/// Returns the ordinal form of [n] — e.g. 1 → '1st', 2 → '2nd', 11 → '11th'.
/// Used for rent-due day display ("due 5th of each month").
String ordinal(int n) {
  if (n >= 11 && n <= 13) return '${n}th';
  switch (n % 10) {
    case 1:
      return '${n}st';
    case 2:
      return '${n}nd';
    case 3:
      return '${n}rd';
    default:
      return '${n}th';
  }
}