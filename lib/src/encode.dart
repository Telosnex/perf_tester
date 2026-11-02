import 'dart:convert';

/// Encodes a value for comparison, falling back to `toString()` if JSON
/// encoding is not possible.
String safeEncode(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return value?.toString() ?? 'null';
  }
}
