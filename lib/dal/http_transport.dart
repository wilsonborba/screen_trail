import 'dart:convert';
import 'package:http/http.dart' as http;
import '../domain/transport.dart';
import 'platform.dart';

/// A [TrailTransport] that posts each payload as JSON over HTTP.
///
/// Status mapping:
/// * 2xx is [TrailSendResult.sent].
/// * 409 is [TrailSendResult.rotateSession].
/// * 400, 413 and 422 are [TrailSendResult.discard].
/// * Every other status, a network error and a 10 second timeout are
///   [TrailSendResult.retry].
class HttpTrailTransport implements TrailTransport {
  /// Creates an HTTP transport.
  ///
  /// [eventsUri] receives events batches. [errorsUri] receives error reports.
  /// [headers] are added to every request, after `Content-Type`.
  /// [includeCredentials] makes browser requests send cookies. It has no
  /// effect outside the browser. Pass [client] to use your own `http.Client`.
  /// The transport does not close a client that you pass.
  HttpTrailTransport({
    required this.eventsUri,
    required this.errorsUri,
    this.headers = const {},
    this.includeCredentials = false,
    http.Client? client,
  }) : _client =
           client ?? createTrailClient(includeCredentials: includeCredentials),
       _ownsClient = client == null;

  /// The URI that receives events batches.
  final Uri eventsUri;

  /// The URI that receives error reports.
  final Uri errorsUri;

  /// Extra headers for every request.
  final Map<String, String> headers;

  /// True when browser requests send cookies. The default is `false`.
  final bool includeCredentials;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<TrailSendResult> sendEvents(Map<String, dynamic> batch) =>
      _post(eventsUri, batch);

  @override
  Future<TrailSendResult> sendErrors(Map<String, dynamic> batch) =>
      _post(errorsUri, batch);

  Future<TrailSendResult> _post(Uri uri, Map<String, dynamic> value) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json', ...headers},
            body: jsonEncode(value),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      return TrailSendResult.retry;
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) return TrailSendResult.sent;
    if (status == 409) return TrailSendResult.rotateSession;
    if (const [400, 413, 422].contains(status)) return TrailSendResult.discard;
    return TrailSendResult.retry;
  }

  /// Closes the HTTP client if this transport created it.
  void close() {
    if (_ownsClient) _client.close();
  }
}
