import 'package:web/web.dart' as web;
import 'package:http/browser_client.dart';

/// Reads a session value, or `null` when it is missing.
String? readSession(String key) {
  try {
    return web.window.sessionStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

/// Writes a session value.
void writeSession(String key, String value) {
  try {
    web.window.sessionStorage.setItem(key, value);
  } catch (_) {
    /* Storage can be disabled. */
  }
}

/// Creates the browser HTTP client. [includeCredentials] sends cookies.
BrowserClient createTrailClient({required bool includeCredentials}) =>
    BrowserClient()..withCredentials = includeCredentials;
