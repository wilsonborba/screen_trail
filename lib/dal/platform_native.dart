import 'package:http/http.dart' as http;

final Map<String, String> _storage = {};

/// Reads a session value, or `null` when it is missing.
String? readSession(String key) => _storage[key];

/// Writes a session value.
void writeSession(String key, String value) {
  _storage[key] = value;
}

/// Creates the native HTTP client. [includeCredentials] has no effect here.
http.Client createTrailClient({required bool includeCredentials}) =>
    http.Client();
