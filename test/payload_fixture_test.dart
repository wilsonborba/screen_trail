import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_trail/screen_trail.dart';

// This file runs in its own isolate, so the session sequence starts at 0.
// The fixture bodies were recorded from the previous internal package for
// the same events. Only the random session UUID is replaced.
const fixtureEvents =
    '{"app_id":"demo_app","session_id":"SESSION","locale":"en","theme":"system","viewport_width":0,"viewport_height":0,"events":[{"seq":0,"event_type":"view","screen":"article","route":"/article/:slug","path":"/article/flutter","element_id":"article.surface","element_label":"Article","element_path":"article > surface","value":null,"sensitive":false},{"seq":1,"event_type":"input","screen":"article","route":"/article/:slug","path":"/article/flutter","element_id":"article.search.input","element_label":"Search articles","element_path":"article > content > search","value":"Flutter tips ไทย","sensitive":false},{"seq":2,"event_type":"input","screen":"article","route":"/article/:slug","path":"/article/flutter","element_id":"login.password.input","element_label":"Password","element_path":"login > form > password","value":null,"sensitive":true},{"seq":3,"event_type":"click","screen":"article","route":"/article/:slug","path":"/article/flutter","element_id":"article.search.input","element_label":"Search articles","element_path":"article > content > search","value":null,"sensitive":false}]}';
const fixtureError =
    '{"app_id":"demo_app","session_id":"SESSION","route":"/article/flutter","error_type":"StateError","message":"Failure [redacted] Bearer [redacted]","stack":"#0 main (file.dart:1:1)","build_version":"1.2.0"}';

const search = TrailElement(
  id: 'article.search.input',
  label: 'Search articles',
  path: 'article > content > search',
);
const password = TrailElement(
  id: 'login.password.input',
  label: 'Password',
  path: 'login > form > password',
);
final eventsUri = Uri.parse('https://example.com/telemetry/events');
final errorsUri = Uri.parse('https://example.com/telemetry/errors');

void main() {
  test('HttpTrailTransport sends the recorded fixture byte for byte', () async {
    final requests = <http.Request>[];
    final t = ScreenTrail(
      appId: 'demo_app',
      buildVersion: '1.2.0',
      screens: const [
        TrailScreen(name: 'article', route: '/article/:slug', label: 'Article'),
      ],
      transport: HttpTrailTransport(
        eventsUri: eventsUri,
        errorsUri: errorsUri,
        client: MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      ),
      recordTypedText: true,
      autoFlush: false,
    );
    t.view('/article/flutter?page=2#top');
    t.event('input', search, value: 'Flutter tips ไทย');
    t.event('input', password, value: 'hunter-secret');
    t.event('click', search);
    t.error(
      'Failure hunter-secret Bearer abc.def',
      StackTrace.fromString('#0 main (file.dart:1:1)'),
      type: 'StateError',
    );
    await t.flush();
    expect(requests.length, 2);
    final session =
        (jsonDecode(requests.first.body) as Map)['session_id'] as String;
    String body(http.Request r) => r.body.replaceAll(session, 'SESSION');
    expect(requests[0].url, eventsUri);
    expect(requests[1].url, errorsUri);
    expect(body(requests[0]), fixtureEvents);
    expect(body(requests[1]), fixtureError);
    for (final r in requests) {
      expect(r.headers['content-type'], startsWith('application/json'));
    }
    t.dispose();
  });
}
