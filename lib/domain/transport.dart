/// The result of one send operation of a [TrailTransport].
enum TrailSendResult {
  /// The receiver accepted the payload. The tracker removes it from the queue.
  sent,

  /// The send failed for a temporary reason. The tracker keeps the payload
  /// and tries again after the backoff delay.
  retry,

  /// The receiver refused the payload as invalid. The tracker drops it.
  discard,

  /// The receiver refused the session identity. For an events batch, the
  /// tracker creates a new session ID, keeps the pending events and tries
  /// again after the backoff delay. For an error report, it acts as [retry].
  rotateSession,
}

/// Sends tracker payloads to the destination that the application selects.
///
/// Each payload is a JSON object in the package payload format. See the
/// README for every field. `HttpTrailTransport` sends the payloads as JSON
/// over HTTP. Implement this interface to send them to another destination.
/// If a send throws, the tracker acts as for [TrailSendResult.retry].
abstract interface class TrailTransport {
  /// Sends one events batch.
  Future<TrailSendResult> sendEvents(Map<String, dynamic> batch);

  /// Sends one errors batch. The tracker sends one error report per batch.
  Future<TrailSendResult> sendErrors(Map<String, dynamic> batch);
}
