// The basemap placeholder has to be the right SIZE, not just invisible.
//
// This is the one non-obvious thing about `BasemapLayer`, and it cost a whole
// test suite before it was understood: `FlutterMap` sizes itself from its
// children whenever its own constraints are loose, and both call sites give
// it loose constraints (each is a non-positioned child of a `Stack` filling
// the screen). The vector style is asynchronous, so for the first frames —
// and forever, offline with nothing cached — the layer renders a placeholder
// instead of a `VectorTileLayer`. A `SizedBox.shrink()` there collapses the
// ENTIRE MAP to 0x0: no camera, no gestures, no markers, a crosshair pointing
// at nothing. The bug looks like "the map is gone", not "the ground is
// missing", and it is invisible in any test that only asserts on widgets.
//
// So: pin the size, in every AsyncValue state, at the geometry that actually
// reproduces it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:masi/core/map/basemap_layer.dart';
import 'package:masi/core/map/basemap_style.dart';

/// The exact shape both real map screens build: a `Stack` filling the body,
/// with `FlutterMap` as a NON-POSITIONED child — which is what makes the
/// map's constraints loose and its size dependent on this layer.
Widget _harness(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(47.0, 11.0),
              initialZoom: 12,
            ),
            children: const [BasemapLayer()],
          ),
        ],
      ),
    ),
  ),
);

ProviderContainer _container(Override styleOverride) {
  final container = ProviderContainer(overrides: [styleOverride]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets('while the style is LOADING the map still fills its parent — a '
      'zero-sized placeholder would collapse the whole map, and on a cold '
      'offline start it would never come back', (tester) async {
    final container = _container(
      basemapStyleProvider.overrideWith((ref) => Completer<Style>().future),
    );

    await tester.pumpWidget(_harness(container));
    await tester.pump();

    expect(tester.getSize(find.byType(FlutterMap)), const Size(800, 600));
    expect(
      find.byType(VectorTileLayer),
      findsNothing,
      reason: 'nothing is drawn yet — this is the placeholder path',
    );
  });

  testWidgets('a style that FAILED to load behaves the same way: blank '
      'ground, full-size map, no error surface where the rock is',
      (tester) async {
    final container = _container(
      basemapStyleProvider.overrideWith(
        (ref) => Future<Style>.error(StateError('offline, nothing cached')),
      ),
    );

    await tester.pumpWidget(_harness(container));
    await tester.pump();
    await tester.pump();

    expect(tester.getSize(find.byType(FlutterMap)), const Size(800, 600));
    expect(find.byType(VectorTileLayer), findsNothing);
    // No thrown error reaches the tree: a failed basemap is a blank map, and
    // the markers and chrome above it stay usable.
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Exception'), findsNothing);
  });
}
