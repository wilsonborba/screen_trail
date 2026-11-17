# screen_trail

Error and usability tracking for Flutter applications.

`screen_trail` records screen views, clicks, scrolls, input changes, submits
and errors. It sends them in small JSON batches. The application selects the
destination with a transport. The package has no default URL.

Sensitive values never leave the device. The package sends no user id and no
IP address.

## Install

```sh
flutter pub add screen_trail
```

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:screen_trail/screen_trail.dart';

final transport = HttpTrailTransport(
  eventsUri: Uri.parse('https://example.com/telemetry/events'),
  errorsUri: Uri.parse('https://example.com/telemetry/errors'),
);

final trail = ScreenTrail(
  appId: 'demo_app',
  buildVersion: '1.0.0',
  screens: const [
    TrailScreen(name: 'article', route: '/article/:slug', label: 'Article'),
  ],
  transport: transport,
);

void main() {
  trail.installErrorCapture();
  runApp(
    MaterialApp(
      navigatorObservers: [ScreenTrailObserver(trail)],
      builder: (context, child) =>
          ScreenTrailRoot(tracker: trail, child: child!),
      home: const SizedBox(),
    ),
  );
}
```

When the application stops, call `trail.dispose()` and `transport.close()`.

1. Create one `ScreenTrail` per application.
2. Add `ScreenTrailObserver` to the navigator. GoRouter also accepts it.
3. Wrap the child of the application builder in `ScreenTrailRoot`. The root
   keeps the existing layout and input behavior.
4. Call `installErrorCapture` once.

For routers whose route settings contain names in place of paths, also call
`trail.view(path)` from the existing navigation listener of the router.

### Name the controls

Keep a tracking manifest in each application. It lists the screen names,
route templates, element ids, labels and tree paths. Use stable dot ids, such
as `article.search.input`. Do not use widget hashes or row indexes as ids.

```dart
const search = TrailElement(
  id: 'article.search.input',
  label: 'Search articles',
  path: 'article > content > search',
);

TrackedElement(element: search, child: existingButton);
TrackedInput(element: search, controller: controller, child: existingField);
TrackedSubmit(
  element: search,
  onSubmit: submit,
  builder: (submit) => FilledButton(onPressed: submit, child: const Text('Go')),
);
```

A field without a controller can call `TrackedInput.input` from its existing
`onChanged`. A click that hits no mapped control uses the nearest mapped
ancestor, or the screen surface `<screen>.surface`.

For a shared control that you cannot edit, use `ScreenTrailRoot.resolveElement`
with `elementFromSemantics` and declared, localized label aliases. The helper
accepts interactive hits only. It never sends widget ids or other labels.

A user-requested error report can use `sendError`. Its future completes only
when the transport returns `sent`. For every other result, it throws a
`StateError`.

## API names

The package uses one naming scheme:

| Prefix | Use | Types |
| --- | --- | --- |
| `ScreenTrail` | Main classes | `ScreenTrail`, `ScreenTrailRoot`, `ScreenTrailObserver`, `ScreenTrailScope` |
| `Trail` | Values and configuration | `TrailElement`, `TrailScreen`, `TrailPrivacy`, `TrailTransport`, `TrailSendResult`, `HttpTrailTransport` |
| `Tracked` | Widgets that wrap one control | `TrackedElement`, `TrackedInput`, `TrackedSubmit` |

## Transport

The destination is configuration. A `TrailTransport` has two operations:

1. `sendEvents(batch)` sends one events batch.
2. `sendErrors(batch)` sends one errors batch. The tracker sends one error
   report per batch.

Each operation returns a `TrailSendResult`:

| Result | Events batch | Error report |
| --- | --- | --- |
| `sent` | Removed from the queue | Removed from the queue |
| `retry` | Kept, sent again after the backoff | Kept, sent again after the backoff |
| `discard` | Dropped | Dropped |
| `rotateSession` | New session ID, events kept, sent again after the backoff | Same as `retry` |

If a transport throws, the tracker acts as for `retry`. Transport failures
never report themselves.

`ScreenTrail` has no default transport. If you give no transport, the
constructor throws an `ArgumentError`.

### HttpTrailTransport

`HttpTrailTransport` posts each payload as JSON with
`Content-Type: application/json`.

| Parameter | Required | Description |
| --- | --- | --- |
| `eventsUri` | Yes | The URI that receives events batches. |
| `errorsUri` | Yes | The URI that receives error reports. |
| `headers` | No | Extra headers for every request. |
| `includeCredentials` | No | Browser only. Sends cookies with each request. The default is `false`. |
| `client` | No | Your own `http.Client`. The transport does not close it. |

Status mapping:

| Response | Result |
| --- | --- |
| 2xx | `sent` |
| 409 | `rotateSession` |
| 400, 413, 422 | `discard` |
| Every other status, a network error, a 10 second timeout | `retry` |

### Custom transport

```dart
class LogTransport implements TrailTransport {
  @override
  Future<TrailSendResult> sendEvents(Map<String, dynamic> batch) async {
    debugPrint(jsonEncode(batch));
    return TrailSendResult.sent;
  }

  @override
  Future<TrailSendResult> sendErrors(Map<String, dynamic> batch) async {
    debugPrint(jsonEncode(batch));
    return TrailSendResult.sent;
  }
}
```

## Payload format

This is the package format. Both payloads are JSON objects. The keys come in
the order below.

### Events batch

```json
{
  "app_id": "demo_app",
  "session_id": "0b6f4c1e-5d8a-4c55-9b0e-2f1c7d3a9e10",
  "locale": "en",
  "theme": "light",
  "viewport_width": 1280,
  "viewport_height": 800,
  "events": [
    {
      "seq": 0,
      "event_type": "click",
      "screen": "article",
      "route": "/article/:slug",
      "path": "/article/flutter",
      "element_id": "article.search.input",
      "element_label": "Search articles",
      "element_path": "article > content > search",
      "value": null,
      "sensitive": false
    }
  ]
}
```

| Field | Type | Description |
| --- | --- | --- |
| `app_id` | string | The `appId` of the tracker. |
| `session_id` | string | A random UUID v4 for the session. |
| `locale` | string | The locale tag, at most 35 bytes. `ScreenTrailRoot` sets it. The default is `en`. |
| `theme` | string | `light`, `dark` or `system`, at most 32 bytes. The default is `system`. |
| `viewport_width` | integer | The viewport width in logical pixels, from 0 to 50000. |
| `viewport_height` | integer | The viewport height in logical pixels, from 0 to 50000. |
| `events` | array | The events, in sequence order. |

Each event:

| Field | Type | Description |
| --- | --- | --- |
| `seq` | integer | The sequence number in the session. It starts at 0. |
| `event_type` | string | `view`, `click`, `scroll`, `input`, `submit`, or a type that the application gives. |
| `screen` | string | The name of the current screen. |
| `route` | string | The route template of the current screen. |
| `path` | string | The concrete path, without query string and fragment. For a sensitive screen, the route template. |
| `element_id` | string | The dot id of the element. |
| `element_label` | string | The human label of the element. |
| `element_path` | string | The tree path of the element. |
| `value` | string or null | The cleaned value, at most 4000 bytes. For `scroll`, the scroll offset in pixels. For `input`, the typed text only when `recordTypedText` is `true`. Always `null` for a sensitive element. |
| `sensitive` | boolean | `true` when the element is sensitive. |

### Error report

```json
{
  "app_id": "demo_app",
  "session_id": "0b6f4c1e-5d8a-4c55-9b0e-2f1c7d3a9e10",
  "route": "/article/flutter",
  "error_type": "FlutterError",
  "message": "Bad state: example",
  "stack": "#0 main (package:demo_app/main.dart:10:3)",
  "build_version": "1.0.0"
}
```

| Field | Type | Description |
| --- | --- | --- |
| `app_id` | string | The `appId` of the tracker. |
| `session_id` | string | The session UUID. |
| `route` | string | The current path, or the cleaned route that the application gives. |
| `error_type` | string | `FlutterError`, `PlatformDispatcher`, `ClientReport`, or a type that the application gives. At most 100 bytes. |
| `message` | string | The cleaned error text, at most 4000 bytes. |
| `stack` | string | The cleaned stack trace, at most 8000 bytes. Empty when there is no stack. |
| `build_version` | string | The `buildVersion` of the tracker, at most 80 bytes. |

## Privacy rules

1. A value of a sensitive field never enters a queue. A field is sensitive
   when it sets `sensitive: true`, or when its id or label contains
   `password`, `passwd`, `token`, `secret`, `payment`, `credit card`,
   `card number`, `cvv` or `cvc`. Mark translated fields as sensitive
   explicitly.
2. `recordTypedText` is `false` by default. Then an input event records only
   that the field changed. Set it to `true` to record non-sensitive typed text.
3. The tracker remembers sensitive values and removes them from pending error
   text.
4. Paths lose their query string and fragment. A screen with
   `sensitivePath: true` sends its route template in place of the path.
5. Messages, stacks and values lose bearer tokens, JWTs, credential pairs
   (`password=`, `token:`, `api_key=` and similar) and URL query strings.
6. `ScreenTrailRoot` rejects drags. A pointer that moves more than 12 logical
   pixels is not a click.
7. The package sends no user id and no IP address. It does not read cookies.

## Session

The session ID and sequence stay in session storage in the browser, and in
memory on other platforms. A `rotateSession` result creates a new session ID
and renumbers the pending events from 0. A retry keeps the session ID and
sequence, so the receiver can drop duplicates.

## Limits

| Limit | Value |
| --- | --- |
| Send interval | 2 seconds |
| Events per batch | 50 |
| Encoded batch size | 60,000 bytes |
| Event queue | 200 events, the oldest are dropped |
| Error queue | 20 reports, the oldest are dropped |
| Backoff | 2, 4, 8, 16, 32, then 64 seconds |
| HTTP timeout | 10 seconds |
| Scroll sampling | 1 event per second |

The tracker also sends pending data when the application becomes inactive or
paused.

## Error capture

`installErrorCapture` sets `FlutterError.onError` and
`PlatformDispatcher.onError`. The previous handlers are still called.
`dispose` restores them.

## Tests

Use a fake `TrailTransport`, or `HttpTrailTransport` with a `MockClient`. Set
`autoFlush: false` and pass `now` for isolated tests.

```sh
flutter pub get
flutter analyze
flutter test
```

## License

MIT. See [LICENSE](LICENSE).
