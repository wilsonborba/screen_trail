import 'dart:convert';

/// A stable identity for one control in the application.
///
/// List these identities in the tracking manifest of each application.
class TrailElement {
  /// Creates an element identity.
  ///
  /// [id] is a lowercase dot id, such as `article.search.input`.
  /// [label] is a human label. [path] is a readable tree path.
  const TrailElement({
    required this.id,
    required this.label,
    required this.path,
  });

  /// The stable dot id of the element, such as `article.search.input`.
  final String id;

  /// The human label of the element.
  final String label;

  /// The readable tree path of the element, such as `article > search`.
  final String path;

  /// True when [id] is a valid dot id and [label] and [path] are not empty.
  ///
  /// The tracker ignores events for elements that are not valid.
  bool get valid =>
      RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$').hasMatch(id) &&
      label.trim().isNotEmpty &&
      path.trim().isNotEmpty;

  /// The element fields of an event in the package payload format.
  Map<String, dynamic> toJson() => {
    'element_id': id,
    'element_label': label,
    'element_path': path,
  };
}

/// One screen of the application and its route template.
class TrailScreen {
  /// Creates a screen.
  ///
  /// [route] is a template such as `/article/:slug`. A part that starts with
  /// `:` matches one path segment. Set [sensitivePath] when the concrete path
  /// contains a secret, such as an invite code. Then the tracker sends the
  /// template in place of the concrete path.
  const TrailScreen({
    required this.name,
    required this.route,
    required this.label,
    this.sensitivePath = false,
  });

  /// True when the concrete path must never leave the device.
  final bool sensitivePath;

  /// The stable screen name, such as `article`.
  final String name;

  /// The route template, such as `/article/:slug`.
  final String route;

  /// The human label of the screen.
  final String label;

  /// True when [path] matches the [route] template.
  bool matches(String path) {
    final pattern = route
        .split('/')
        .map((part) => part.startsWith(':') ? '[^/]+' : RegExp.escape(part))
        .join('/');
    return RegExp('^$pattern\$').hasMatch(path);
  }

  /// The element that stands for the screen surface, `<name>.surface`.
  ///
  /// The tracker uses it for views, scrolls and clicks on unmapped areas.
  TrailElement get surface =>
      TrailElement(id: '$name.surface', label: label, path: '$name > surface');
}

/// Returns [text] cut to at most [maxBytes] UTF-8 bytes.
///
/// The cut never splits a multi-byte character.
String bounded(String text, int maxBytes) {
  final bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) return text;
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end));
}

/// Returns [path] without its query string and fragment.
String routePath(String path) => path.split(RegExp(r'[?#]')).first;

/// True when [text] names a password, token, secret or payment field.
bool sensitiveName(String text) => RegExp(
  r'password|passwd|token|secret|payment|credit.?card|card.?number|cvv|cvc',
  caseSensitive: false,
).hasMatch(text);

/// Removes sensitive values and credentials from text before it is sent.
class TrailPrivacy {
  final List<String> _secrets = [];

  /// Remembers a sensitive [value], so that [clean] removes it later.
  ///
  /// Values shorter than 3 characters are ignored. At most 100 values are kept.
  void remember(String value) {
    if (value.length < 3 || _secrets.contains(value)) return;
    _secrets.add(value);
    if (_secrets.length > 100) _secrets.removeAt(0);
  }

  /// Returns [text] with remembered values, bearer tokens, JWTs, credential
  /// pairs and URL queries redacted, cut to at most [maxBytes] UTF-8 bytes.
  String clean(String text, {int maxBytes = 4000}) {
    var value = text;
    for (final secret in _secrets) {
      value = value.replaceAll(secret, '[redacted]');
    }
    value = value.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [redacted]',
    );
    value = value.replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
      '[redacted]',
    );
    value = value.replaceAll(
      RegExp(
        r'''(?:password|passwd|secret|token|authorization|cookie|(?:api|service|app)[_-]?key)["']?\s*[=:]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
        caseSensitive: false,
      ),
      'credential=[redacted]',
    );
    value = value.replaceAll(
      RegExp(r'https?://[^\s?#]+[?#][^\s]+'),
      '[url query omitted]',
    );
    return bounded(value, maxBytes);
  }
}
