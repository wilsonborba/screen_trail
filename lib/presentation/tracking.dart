import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../core/model.dart';
import '../domain/tracker.dart';

/// Makes a [ScreenTrail] available to the widgets below it.
///
/// [ScreenTrailRoot] inserts this widget. Most applications do not use it
/// directly.
class ScreenTrailScope extends InheritedWidget {
  /// Creates a scope for [tracker].
  const ScreenTrailScope({
    super.key,
    required this.tracker,
    required super.child,
  });

  /// The tracker for the widgets below this scope.
  final ScreenTrail tracker;

  /// The tracker of the nearest scope, or `null` when there is no scope.
  static ScreenTrail? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScreenTrailScope>()?.tracker;
  @override
  bool updateShouldNotify(ScreenTrailScope oldWidget) =>
      tracker != oldWidget.tracker;
}

/// Names an existing control for click events.
///
/// Wrap an existing control. This does not change its layout, color or
/// behavior.
class TrackedElement extends StatelessWidget {
  /// Wraps [child] with the identity [element].
  const TrackedElement({super.key, required this.element, required this.child});

  /// The identity of the wrapped control.
  final TrailElement element;

  /// The wrapped control.
  final Widget child;
  @override
  Widget build(BuildContext context) => MetaData(
    metaData: element,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}

/// Records clicks and scrolls of the application and sends its context.
///
/// Wrap the child of the application builder. The root keeps the existing
/// layout and input behavior. It rejects drags, samples scrolls once per
/// second and sends pending data when the application becomes inactive.
class ScreenTrailRoot extends StatefulWidget {
  /// Creates a root for [tracker].
  ///
  /// [locale] overrides the locale that the root reads from [Localizations].
  /// [resolveElement] names a click that hits no [TrackedElement].
  const ScreenTrailRoot({
    super.key,
    required this.tracker,
    required this.child,
    this.resolveElement,
    this.locale,
  });

  /// The tracker that receives the events.
  final ScreenTrail tracker;

  /// The locale sent with events, such as `th`. When `null`, the root uses
  /// the locale of the widget tree.
  final String? locale;

  /// Names a click that hits no [TrackedElement], for example with
  /// [elementFromSemantics]. When it returns `null`, the click uses the
  /// screen surface.
  final TrailElement? Function(PointerUpEvent, HitTestResult)? resolveElement;

  /// The application content.
  final Widget child;
  @override
  State<ScreenTrailRoot> createState() => _ScreenTrailRootState();
}

class _ScreenTrailRootState extends State<ScreenTrailRoot>
    with WidgetsBindingObserver {
  final Map<int, Offset> _down = {};
  DateTime _lastScroll = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(widget.tracker.flush());
    }
  }

  void _up(PointerUpEvent event) {
    final from = _down.remove(event.pointer);
    if (from == null || (from - event.position).distance > 12) return;
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    TrailElement? element;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is TrailElement) {
        element = target.metaData as TrailElement;
        break;
      }
    }
    widget.tracker.event(
      'click',
      element ??
          widget.resolveElement?.call(event, result) ??
          widget.tracker.currentScreen.surface,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media != null) {
      widget.tracker.viewportWidth = media.size.width.round();
      widget.tracker.viewportHeight = media.size.height.round();
      widget.tracker.theme = Theme.of(context).brightness.name;
    }
    final locale = Localizations.maybeLocaleOf(context);
    if (widget.locale != null) {
      widget.tracker.locale = widget.locale!;
    } else if (locale != null) {
      widget.tracker.locale = locale.toLanguageTag();
    }
    return ScreenTrailScope(
      tracker: widget.tracker,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          final now = DateTime.now();
          if (n is ScrollUpdateNotification &&
              now.difference(_lastScroll).inMilliseconds >= 1000) {
            _lastScroll = now;
            widget.tracker.event(
              'scroll',
              widget.tracker.currentScreen.surface,
              value: n.metrics.pixels.round().toString(),
            );
          }
          return false;
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _down[e.pointer] = e.position,
          onPointerUp: _up,
          onPointerCancel: (e) => _down.remove(e.pointer),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Records a view when the navigator pushes, pops or replaces a named route.
///
/// GoRouter accepts a [NavigatorObserver], so applications do not need the
/// same GoRouter version.
class ScreenTrailObserver extends NavigatorObserver {
  /// Creates an observer for [tracker].
  ScreenTrailObserver(this.tracker);

  /// The tracker that receives the views.
  final ScreenTrail tracker;
  void _visit(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null) tracker.view(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _visit(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _visit(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _visit(newRoute);
}

/// Records input events for a text field.
///
/// Use it with an existing controller, or forward `onChanged` through
/// [input]. Password and payment fields must also set [sensitive], even when
/// labels are translated.
class TrackedInput extends StatefulWidget {
  /// Wraps the field [child] with the identity [element].
  const TrackedInput({
    super.key,
    required this.element,
    required this.child,
    this.controller,
    this.sensitive = false,
  });

  /// The identity of the field.
  final TrailElement element;

  /// The field.
  final Widget child;

  /// The controller of the field. Each text change records an input event.
  final TextEditingController? controller;

  /// True when the field holds a secret. Its value never leaves the device.
  final bool sensitive;

  /// Records an input event for [element] with the scope tracker of
  /// [context]. Call it from the existing `onChanged` of a field.
  static void input(
    BuildContext context,
    TrailElement element,
    String value, {
    bool sensitive = false,
  }) => ScreenTrailScope.maybeOf(
    context,
  )?.event('input', element, value: value, sensitive: sensitive);
  @override
  State<TrackedInput> createState() => _TrackedInputState();
}

class _TrackedInputState extends State<TrackedInput> {
  String? _last;
  @override
  void initState() {
    super.initState();
    _last = widget.controller?.text;
    widget.controller?.addListener(_changed);
  }

  @override
  void didUpdateWidget(TrackedInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_changed);
      _last = widget.controller?.text;
      widget.controller?.addListener(_changed);
    }
  }

  void _changed() {
    final text = widget.controller?.text;
    if (text != null && text != _last) {
      _last = text;
      TrackedInput.input(
        context,
        widget.element,
        text,
        sensitive: widget.sensitive,
      );
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TrackedElement(element: widget.element, child: widget.child);
}

/// Records a submit event before it calls the existing submit callback.
class TrackedSubmit extends StatelessWidget {
  /// Creates a submit wrapper for [element].
  const TrackedSubmit({
    super.key,
    required this.element,
    required this.onSubmit,
    required this.builder,
  });

  /// The identity of the submit control.
  final TrailElement element;

  /// The existing submit callback. When `null`, the control is disabled.
  final VoidCallback? onSubmit;

  /// Builds the control with a callback that records the event and submits.
  final Widget Function(VoidCallback? submit) builder;
  @override
  Widget build(BuildContext context) => TrackedElement(
    element: element,
    child: builder(
      onSubmit == null
          ? null
          : () {
              ScreenTrailScope.maybeOf(context)?.event('submit', element);
              onSubmit!();
            },
    ),
  );
}

/// Names an existing control through declared, localized label [aliases].
///
/// Use it in [ScreenTrailRoot.resolveElement]. It never exposes widget ids.
/// Non-interactive text is not treated as a control. It is useful for shared
/// controls that you cannot edit.
TrailElement? elementFromSemantics(
  HitTestResult result,
  Map<String, TrailElement> aliases,
) {
  var interactive = false;
  final labels = <String>[];
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderParagraph) labels.add(target.text.toPlainText());
    if (target is RenderSemanticsAnnotations) {
      final properties = target.properties;
      interactive =
          interactive ||
          properties.button == true ||
          properties.link == true ||
          properties.onTap != null;
      if (properties.label != null) labels.add(properties.label!);
      if (properties.tooltip != null) labels.add(properties.tooltip!);
    }
    if (target is RenderSemanticsGestureHandler && target.onTap != null) {
      interactive = true;
    }
  }
  if (!interactive) return null;
  final normalized = {
    for (final e in aliases.entries) e.key.trim().toLowerCase(): e.value,
  };
  for (final label in labels) {
    final found = normalized[label.trim().toLowerCase()];
    if (found != null) return found;
  }
  return null;
}
