import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../core/model.dart';
import '../dal/platform.dart';
import 'transport.dart';

/// Collects errors and usability events and sends them through a
/// [TrailTransport].
///
/// Create one instance per application. Call [dispose] when the application
/// stops.
class ScreenTrail {
  /// Creates a tracker.
  ///
  /// [transport] is required. Construction throws an [ArgumentError] when it
  /// is missing. [appId] names the application in every payload.
  /// [buildVersion] names the build in every error report. [screens] lists
  /// the known screens. When [recordTypedText] is `false` (the default), an
  /// input event records only that the field changed. When it is `true`, a
  /// non-sensitive input event also records the typed value. Sensitive fields
  /// never record a value. Set [autoFlush] to `false` and pass [now] for
  /// isolated tests.
  ScreenTrail({
    required this.appId,
    required this.buildVersion,
    required this.screens,
    TrailTransport? transport,
    this.recordTypedText = false,
    bool autoFlush = true,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _transport = transport ?? _missingTransport() {
    _session = readSession('tracking.$appId.session') ?? _uuid();
    _seq = int.tryParse(readSession('tracking.$appId.seq') ?? '') ?? 0;
    _saveSession();
    if (autoFlush) {
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(flush()),
      );
    }
  }
  static TrailTransport _missingTransport() => throw ArgumentError.value(
    null,
    'transport',
    'ScreenTrail needs a TrailTransport, for example '
        'HttpTrailTransport(eventsUri: ..., errorsUri: ...)',
  );

  /// The application id sent in every payload.
  final String appId;

  /// The build version sent in every error report.
  final String buildVersion;

  /// The known screens. The first match of a path selects the screen.
  final List<TrailScreen> screens;

  /// True when non-sensitive input events record the typed value.
  final bool recordTypedText;

  final TrailTransport _transport;
  final DateTime Function() _now;

  /// The privacy filter that cleans every value, message and stack.
  final TrailPrivacy privacy = TrailPrivacy();
  final List<Map<String, dynamic>> _events = [], _errors = [];
  Timer? _timer;
  late String _session;
  int _seq = 0, _failures = 0;
  bool _sending = false, _disposed = false;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
  String _path = '/';

  /// The locale sent in every events batch. `ScreenTrailRoot` sets it.
  String locale = 'en';

  /// The theme brightness sent in every events batch. `ScreenTrailRoot` sets it.
  String theme = 'system';

  /// The viewport width sent in every events batch. `ScreenTrailRoot` sets it.
  int viewportWidth = 0;

  /// The viewport height sent in every events batch. `ScreenTrailRoot` sets it.
  int viewportHeight = 0;
  TrailScreen? _screen;
  FlutterExceptionHandler? _previousFlutter, _ownFlutter;
  bool Function(Object, StackTrace)? _previousPlatform, _ownPlatform;
  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final s = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  void _saveSession() {
    writeSession('tracking.$appId.session', _session);
    writeSession('tracking.$appId.seq', '$_seq');
  }

  /// The current screen. Before the first view, the first known screen.
  TrailScreen get currentScreen =>
      _screen ??
      (screens.isEmpty
          ? const TrailScreen(name: 'app', route: '/', label: 'Application')
          : screens.first);

  /// Records a view of [path]. The query string and fragment are removed.
  ///
  /// A repeated view of the same screen and path records nothing.
  void view(String path) {
    final safe = routePath(path);
    final matches = screens.where((s) => s.matches(safe));
    final selected = matches.isEmpty ? currentScreen : matches.first;
    if (_screen == selected && _path == safe) return;
    _screen = selected;
    _path = selected.sensitivePath ? selected.route : safe;
    event('view', selected.surface);
  }

  /// Records one event of [type] on [element], such as `click` or `input`.
  ///
  /// When [sensitive] is `true`, or the element id or label names a sensitive
  /// field, the [value] never enters the queue. For an `input` event, the
  /// value is kept only when [recordTypedText] is `true`.
  void event(
    String type,
    TrailElement element, {
    String? value,
    bool sensitive = false,
  }) {
    if (_disposed || !element.valid) return;
    final secret = sensitive || sensitiveName('${element.id} ${element.label}');
    if (secret && value != null) privacy.remember(value);
    final kept = type == 'input' && !recordTypedText ? null : value;
    final event = <String, dynamic>{
      'seq': _seq++,
      'event_type': type,
      'screen': currentScreen.name,
      'route': currentScreen.route,
      'path': _path,
      ...element.toJson(),
      'value': secret || kept == null ? null : privacy.clean(kept),
      'sensitive': secret,
    };
    // A sensitive value never enters the queue or a serialized request.
    _events.add(event);
    if (_events.length > 200) _events.removeAt(0);
    _saveSession();
  }

  /// Sends a user-requested error report now.
  ///
  /// The future completes only after the transport returns
  /// [TrailSendResult.sent]. For every other result it throws a [StateError].
  Future<void> sendError(
    Object error, {
    StackTrace? stack,
    String type = 'ClientReport',
  }) async {
    final value = <String, dynamic>{
      'app_id': appId,
      'session_id': _session,
      'route': _path,
      'error_type': bounded(type, 100),
      'message': privacy.clean(error.toString()),
      'stack': privacy.clean(stack?.toString() ?? '', maxBytes: 8000),
      'build_version': bounded(buildVersion, 80),
    };
    final result = await _transport.sendErrors(value);
    if (result != TrailSendResult.sent) {
      throw StateError('Error report service unavailable');
    }
  }

  String _safeErrorRoute(String route) {
    final path = routePath(route);
    final sensitive = screens.where(
      (screen) => screen.sensitivePath && screen.matches(path),
    );
    return sensitive.isEmpty ? path : sensitive.first.route;
  }

  /// Queues an error report. [route] replaces the current path for this
  /// report only. It is cleaned and does not change navigation.
  void error(
    Object error,
    StackTrace? stack, {
    String type = 'FlutterError',
    String? route,
  }) {
    if (_disposed) return;
    _errors.add({
      'app_id': appId,
      'session_id': _session,
      'route': route == null ? _path : _safeErrorRoute(route),
      'error_type': bounded(type, 100),
      'message': privacy.clean(error.toString()),
      'stack': privacy.clean(stack?.toString() ?? '', maxBytes: 8000),
      'build_version': bounded(buildVersion, 80),
    });
    if (_errors.length > 20) _errors.removeAt(0);
  }

  /// Captures errors from `FlutterError.onError` and
  /// `PlatformDispatcher.onError`. Previous handlers are still called.
  /// [dispose] restores them.
  void installErrorCapture() {
    if (_ownFlutter != null) return;
    _previousFlutter = FlutterError.onError;
    _ownFlutter = (details) {
      error(details.exception, details.stack);
      _previousFlutter?.call(details);
    };
    FlutterError.onError = _ownFlutter;
    _previousPlatform = PlatformDispatcher.instance.onError;
    _ownPlatform = (error, stack) {
      this.error(error, stack, type: 'PlatformDispatcher');
      return _previousPlatform?.call(error, stack) ?? false;
    };
    PlatformDispatcher.instance.onError = _ownPlatform;
  }

  Map<String, dynamic> _batch(List<Map<String, dynamic>> events) => {
    'app_id': appId,
    'session_id': _session,
    'locale': bounded(locale, 35),
    'theme': bounded(theme, 32),
    'viewport_width': viewportWidth.clamp(0, 50000),
    'viewport_height': viewportHeight.clamp(0, 50000),
    'events': events,
  };

  /// Creates a new session ID and renumbers the pending events.
  void rotateSession() {
    _session = _uuid();
    _seq = 0;
    for (final e in _events) {
      e['seq'] = _seq++;
    }
    for (final e in _errors) {
      e['session_id'] = _session;
    }
    _saveSession();
  }

  /// Sends one events batch and one error report from the queues.
  ///
  /// A batch holds at most 50 events and 60,000 encoded bytes. After a
  /// failure, the next send waits 2, 4, 8, 16, 32 and then 64 seconds.
  Future<void> flush() async {
    if (_sending || _disposed || _now().isBefore(_retryAfter)) return;
    _sending = true;
    try {
      if (_events.isNotEmpty) {
        final selected = <Map<String, dynamic>>[];
        for (final event in _events.take(50)) {
          final trial = [...selected, event];
          if (utf8.encode(jsonEncode(_batch(trial))).length > 60000) break;
          selected.add(event);
        }
        if (selected.isNotEmpty) {
          final result = await _transport.sendEvents(_batch(selected));
          if (result == TrailSendResult.rotateSession) {
            rotateSession();
            _backoff();
            return;
          }
          if (!_complete(result)) {
            _backoff();
            return;
          }
          _events.removeWhere(selected.contains);
        } else {
          _events.removeAt(0);
        }
      }
      if (_errors.isNotEmpty) {
        final error = _errors.first;
        // Re-scrub pending errors if a sensitive value was learned after capture.
        error['message'] = privacy.clean(error['message'] as String);
        error['stack'] = privacy.clean(
          error['stack'] as String,
          maxBytes: 8000,
        );
        final result = await _transport.sendErrors(error);
        if (!_complete(result)) {
          _backoff();
          return;
        }
        _errors.remove(error);
      }
      _failures = 0;
      _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
    } catch (_) {
      _backoff(); /* Never report transport errors recursively. */
    } finally {
      _sending = false;
    }
  }

  bool _complete(TrailSendResult result) =>
      result == TrailSendResult.sent || result == TrailSendResult.discard;
  void _backoff() {
    _failures = (_failures + 1).clamp(1, 6);
    _retryAfter = _now().add(Duration(seconds: 1 << _failures));
  }

  /// Stops automatic sending and restores the previous error handlers.
  ///
  /// The tracker does not close the transport.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (FlutterError.onError == _ownFlutter) {
      FlutterError.onError = _previousFlutter;
    }
    if (PlatformDispatcher.instance.onError == _ownPlatform) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
  }
}
