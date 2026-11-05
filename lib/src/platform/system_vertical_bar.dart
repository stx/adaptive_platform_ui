import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the system places its vertical bar for this window, as a physical
/// side (`UITraitCollection.verticalBarEdge`, iOS 27.1).
enum SystemVerticalBarEdge {
  /// No reading: not iOS, iOS < 27.1, or the first reading has not arrived.
  unknown,

  /// The system keeps horizontal bars here.
  none,

  /// The system puts its vertical bar on the left edge.
  left,

  /// The system puts its vertical bar on the right edge.
  right;

  /// The edge for a value sent over the channel; anything unrecognised
  /// (including the native "unsupported") is [unknown]. A reading is a map
  /// with the edge under `edge`; a bare string is accepted too.
  static SystemVerticalBarEdge fromWire(Object? value) {
    final edge = value is Map ? value['edge'] : value;
    return switch (edge) {
      'none' => none,
      'left' => left,
      'right' => right,
      _ => unknown,
    };
  }
}

/// UIKit's layout region for a vertical bar on the system's edge
/// (`UIViewLayoutRegion.layoutRegionForBar(onEdge:extent:)`, iOS 27.1), as
/// distances from the window's top and bottom edges.
///
/// This is where the system lays out its own vertical bar. It keeps clear of
/// the status cluster, which grows with every Live Activity stacked in it.
@immutable
class SystemVerticalBarRegion {
  const SystemVerticalBarRegion({required this.top, required this.bottom});

  /// Distance from the top of the window to the top of the region.
  final double top;

  /// Distance from the bottom of the region to the bottom of the window.
  final double bottom;

  /// The region in a reading sent over the channel, or null when the reading
  /// has none (no vertical bar, or iOS < 27.1).
  static SystemVerticalBarRegion? fromWire(Object? value) {
    if (value is! Map) return null;
    final top = value['top'];
    final bottom = value['bottom'];
    if (top is! num || bottom is! num) return null;
    return SystemVerticalBarRegion(
      top: top.toDouble(),
      bottom: bottom.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SystemVerticalBarRegion &&
      other.top == top &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(top, bottom);

  @override
  String toString() =>
      'top ${top.toStringAsFixed(0)}pt, bottom ${bottom.toStringAsFixed(0)}pt';
}

/// The system's vertical bar edge and layout region, streamed from the
/// native side.
///
/// One shared subscription: an [EventChannel] supports a single native
/// listener, and both the toolbar host and every scaffold without a host need
/// the values.
abstract final class SystemVerticalBar {
  static const EventChannel _channel = EventChannel(
    'adaptive_platform_ui/vertical_bar_edge',
  );
  static final ValueNotifier<SystemVerticalBarEdge> _edge = ValueNotifier(
    SystemVerticalBarEdge.unknown,
  );
  static final ValueNotifier<SystemVerticalBarRegion?> _region = ValueNotifier(
    null,
  );
  static StreamSubscription<Object?>? _sub;

  static void _listen() {
    _sub ??= _channel.receiveBroadcastStream().listen((value) {
      _edge.value = SystemVerticalBarEdge.fromWire(value);
      _region.value = SystemVerticalBarRegion.fromWire(value);
    }, onError: (Object _) {});
  }

  /// The current edge. Starts listening on first use, so only read it where
  /// the channel exists (iOS 26+); it stays [SystemVerticalBarEdge.unknown]
  /// until the first reading arrives.
  static ValueListenable<SystemVerticalBarEdge> get edge {
    _listen();
    return _edge;
  }

  /// The current layout region for a bar on [edge], or null without one.
  /// Starts listening on first use, like [edge].
  static ValueListenable<SystemVerticalBarRegion?> get region {
    _listen();
    return _region;
  }
}
