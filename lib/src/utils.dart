bool isEmpty<T>(T value) {
  if (value == null) return true;
  if (value is String) return value.isEmpty;
  if (value is List) return value.isEmpty;
  if (value is Map) return value.isEmpty;
  if (value is Set) return value.isEmpty;
  return false;
}
