import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Sent up by something being dragged inside an [HScroll] (a board card)
/// with the pointer position: near the left or right edge the area scrolls
/// that way. [global] null = the drag is over.
class DragEdgeNotification extends Notification {
  const DragEdgeNotification(this.global);
  final Offset? global;
}

/// Horizontal scroll area that is usable with a mouse: a scrollbar, click-
/// and-drag on empty space, Shift + wheel and sideways trackpad swipes.
/// A bare horizontal SingleChildScrollView can't be scrolled with a mouse
/// at all, so wide tables just looked cut off (ISSUES.md #018).
///
/// The scrollbar sticks to the bottom of the visible screen while the
/// table's own bottom is further down (like Notion), so a long table can be
/// moved sideways without scrolling to its end.
class HScroll extends StatefulWidget {
  const HScroll({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  State<HScroll> createState() => _HScrollState();
}

class _HScrollState extends State<HScroll> {
  static const _barHeight = 12.0;

  final _controller = ScrollController();
  // Every scroll under the Scaffold (the page, whichever scroll view the
  // editor uses) is reported here, so the bar can follow the screen.
  ScrollNotificationObserverState? _observer;
  double? _barTop; // bar position inside this widget

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (observer != _observer) {
      _observer?.removeListener(_onScroll);
      _observer = observer?..addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _observer?.removeListener(_onScroll);
    _edgeTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  // ---- scrolling by itself while something is dragged to an edge ----

  static const _edge = 64.0; // how close to a side counts as "at the edge"
  static const _maxStep = 18.0; // pixels per frame right at the side
  Timer? _edgeTimer;
  double _edgeStep = 0;

  bool _onDragEdge(DragEdgeNotification n) {
    final box = context.findRenderObject();
    var step = 0.0;
    if (n.global != null && box is RenderBox && box.hasSize) {
      final x = box.globalToLocal(n.global!).dx;
      final w = box.size.width;
      if (x < _edge) {
        step = -_maxStep * ((_edge - x) / _edge).clamp(0.2, 1.0);
      } else if (x > w - _edge) {
        step = _maxStep * ((x - (w - _edge)) / _edge).clamp(0.2, 1.0);
      }
    }
    _edgeStep = step;
    if (step == 0) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
    } else {
      _edgeTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _edgeTick(),
      );
    }
    return true;
  }

  void _edgeTick() {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    final to = (p.pixels + _edgeStep).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    if (to != p.pixels) _controller.jumpTo(to);
  }

  void _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical) _place();
  }

  /// Puts the bar at the bottom of the part of this widget that is on
  /// screen (measured against the window, not a scroll view).
  void _place() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final screenBottom = MediaQuery.sizeOf(context).height;
    final top = box.localToGlobal(Offset.zero).dy;
    final atEnd = box.size.height - _barHeight;
    final onScreen = screenBottom - top - _barHeight - 4;
    // Never above the first rows, never below the table.
    final y = math.max(math.min(atEnd, onScreen), math.min(48.0, atEnd));
    if (y != _barTop) setState(() => _barTop = y);
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    // Shift + wheel, or a sideways trackpad swipe.
    final sideways = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs();
    if (!HardwareKeyboard.instance.isShiftPressed && !sideways) return;
    final delta = event.scrollDelta.dy != 0 && !sideways
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    final p = _controller.position;
    _controller.jumpTo(
      (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Size or page position may have changed: place the bar after layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
    return Listener(
      onPointerSignal: _onSignal,
      // Finger or button up always ends edge scrolling, even if the dragged
      // card went away before it could say so.
      onPointerUp: (_) => _onDragEdge(const DragEdgeNotification(null)),
      onPointerCancel: (_) => _onDragEdge(const DragEdgeNotification(null)),
      child: NotificationListener<DragEdgeNotification>(
        onNotification: _onDragEdge,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: false,
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
            },
          ),
          child: Stack(
            children: [
              NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  _place();
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  // Room for the scrollbar under the content.
                  padding: (widget.padding ?? EdgeInsets.zero).add(
                    const EdgeInsets.only(bottom: _barHeight + 2),
                  ),
                  child: widget.child,
                ),
              ),
              if (_barTop != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: _barTop,
                  height: _barHeight,
                  child: _Bar(controller: _controller),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A plain horizontal scrollbar for [controller]: drag the thumb, or click
/// the track to jump a page.
class _Bar extends StatelessWidget {
  const _Bar({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.hasClients ||
            !controller.position.hasContentDimensions ||
            controller.position.maxScrollExtent <= 0) {
          return const SizedBox.shrink();
        }
        final p = controller.position;
        return LayoutBuilder(
          builder: (context, c) {
            final track = c.maxWidth;
            final content = p.viewportDimension + p.maxScrollExtent;
            final thumb = math.max(40.0, track * p.viewportDimension / content);
            final room = track - thumb;
            final x = room * (p.pixels / p.maxScrollExtent).clamp(0.0, 1.0);
            void jumpBy(double dx) => controller.jumpTo(
              (p.pixels + dx * p.maxScrollExtent / room).clamp(
                0.0,
                p.maxScrollExtent,
              ),
            );
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final page = p.viewportDimension * 0.9;
                controller.animateTo(
                  (p.pixels + (d.localPosition.dx < x ? -page : page)).clamp(
                    0.0,
                    p.maxScrollExtent,
                  ),
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                );
              },
              onHorizontalDragUpdate: (d) => jumpBy(d.delta.dx),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  Positioned(
                    left: x,
                    width: thumb,
                    top: 2,
                    bottom: 2,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
