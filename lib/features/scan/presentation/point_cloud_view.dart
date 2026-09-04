import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui show PointMode;

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../domain/point_cloud.dart';

/// Interactive 3D viewer for a [PointCloud].
///
/// ## Why this is hand-rolled maths and a [CustomPainter]
///
/// No plugin, no `flutter_gl`, no WebGL, no `dart:io`. The whole reason the
/// scan feature exists is to be looked at in a phone browser as well as in the
/// iOS app, and every 3D plugin on pub either has no web implementation or
/// pulls in a JS interop shim that breaks the wasm build. A projection matrix
/// is thirty lines of arithmetic; a broken web build is the feature not
/// shipping. So: `Canvas.drawRawPoints`, which exists on every backend Flutter
/// has, and identical output on iOS and web.
///
/// ## Depth: painter's algorithm, via an O(n) bucket sort
///
/// `drawRawPoints` has no depth buffer, so draw order IS occlusion order. The
/// two options on the table were a full back-to-front sort and depth-scaled
/// point size with no ordering at all. We do the ordering, but NOT with a
/// comparison sort: `List.sort` over 150k indices is O(n log n) with a
/// comparator callback per step, runs every frame while the user is dragging,
/// and on the web (where this has to be good) costs more than the entire rest
/// of the frame. Instead points are counted into [_kDepthBands] depth bands in
/// one linear pass and scattered in a second, then drawn far band first — the
/// ordering a comparison sort would have produced, quantised, at linear cost.
///
/// Depth-scaled point size was NOT rejected; it falls out of the same binning
/// for free (each band draws at its own stroke width, so far points are
/// smaller). What was rejected is using it INSTEAD of ordering: on a rock face
/// the near and far surfaces of the same feature project on top of each other,
/// and with no ordering the back wall shows through the front one no matter
/// what size the dots are.
///
/// Per-point colour is the other constraint `drawRawPoints` imposes: one
/// [Paint], so one colour per call. Colours are therefore quantised ONCE per
/// cloud into a palette (see [_CloudPalette]) and the per-frame bins are
/// `band x paletteEntry`, which keeps the draw-call count bounded by the
/// number of distinct quantised colours actually present rather than by the
/// number of points.
///
/// ## Scale
///
/// [metresPerUnit] is nullable and defaults to null, and when it is null this
/// widget shows NO measurement of any kind. Structure-from-motion recovers
/// geometry only up to a similarity transform, so a bare reconstruction has no
/// idea how big the rock is; printing "12 m" beside an arbitrary-scale cloud
/// would be a fabricated number on a screen a climber might use to decide
/// whether they have enough rope.
class PointCloudView extends StatefulWidget {
  const PointCloudView({
    super.key,
    required this.cloud,
    this.metresPerUnit,
    this.pointSize = 2.0,
  });

  /// The cloud to draw. Changing it re-frames the camera.
  final PointCloud cloud;

  /// How many metres one cloud unit represents, or `null` (the default, and
  /// the common case) when the reconstruction is at arbitrary scale.
  ///
  /// Used ONLY to render the scale note. Nothing else in this widget depends
  /// on it, and when it is null nothing is displayed. See the class doc.
  final double? metresPerUnit;

  /// Base dot diameter in logical pixels, at the framing distance. Bands
  /// scale up and down from here.
  final double pointSize;

  @override
  State<PointCloudView> createState() => PointCloudViewState();
}

/// Where the camera is. Value type so [CustomPainter.shouldRepaint] can
/// compare two of them instead of guessing.
@immutable
class PointCloudCamera {
  const PointCloudCamera({
    required this.yaw,
    required this.pitch,
    required this.distance,
    this.pan = Offset.zero,
  });

  /// Rotation about the model's +Y axis, radians.
  final double yaw;

  /// Elevation, radians. Clamped by the widget to [maxPitch] so the camera can
  /// never tip past vertical and flip the image.
  final double pitch;

  /// Eye distance from the model centre, in cloud units.
  final double distance;

  /// Screen-space translation applied after projection, logical pixels.
  final Offset pan;

  /// Just short of straight up/down. At exactly pi/2 the up vector is
  /// degenerate and the view spins about the pole on the next pixel of drag.
  static const double maxPitch = math.pi / 2 - 0.02;

  PointCloudCamera copyWith({
    double? yaw,
    double? pitch,
    double? distance,
    Offset? pan,
  }) => PointCloudCamera(
    yaw: yaw ?? this.yaw,
    pitch: pitch ?? this.pitch,
    distance: distance ?? this.distance,
    pan: pan ?? this.pan,
  );

  @override
  bool operator ==(Object other) =>
      other is PointCloudCamera &&
      other.yaw == yaw &&
      other.pitch == pitch &&
      other.distance == distance &&
      other.pan == pan;

  @override
  int get hashCode => Object.hash(yaw, pitch, distance, pan);
}

/// Public so widget tests can reach the camera through
/// `tester.state<PointCloudViewState>(...)`. Nothing outside tests should
/// touch it — drive the camera with gestures.
class PointCloudViewState extends State<PointCloudView> {
  /// Vertical field of view. Wide enough to feel like standing at the crag,
  /// narrow enough that the perspective does not bow a flat wall.
  static const double _fovY = 50 * math.pi / 180;

  late PointCloudCamera _camera;
  late double _fitDistance;
  late _CloudPalette _palette;
  late _Scratch _scratch;

  double _gestureStartDistance = 1;

  /// The current camera. Test seam — see the class doc.
  @visibleForTesting
  PointCloudCamera get camera => _camera;

  /// The distance the camera was framed at on first build. Test seam.
  @visibleForTesting
  double get fitDistance => _fitDistance;

  @override
  void initState() {
    super.initState();
    _adoptCloud();
  }

  @override
  void didUpdateWidget(PointCloudView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cloud, widget.cloud)) _adoptCloud();
  }

  void _adoptCloud() {
    final cloud = widget.cloud;
    _palette = _CloudPalette.build(cloud);
    _scratch = _Scratch(cloud.pointCount, _kDepthBands * _palette.length);

    // FRAME THE MODEL ON FIRST BUILD. A viewer that opens on an empty void
    // reads as a failed reconstruction, and the user's response to that is to
    // reshoot a scan that was fine — so the opening frame is not cosmetic.
    // Distance that puts the bounding sphere inside the field of view, with a
    // margin so it does not touch the edges.
    final radius = math.max(cloud.boundingRadius, 1e-6);
    _fitDistance = math.max(radius / math.tan(_fovY / 2) * 1.25, 1e-4);
    _camera = PointCloudCamera(
      // A three-quarter view, not a face-on one: an oblique opening angle is
      // what makes it read as 3D at a glance instead of as a flat photo.
      yaw: -0.6,
      pitch: 0.25,
      distance: _fitDistance,
    );
  }

  double get _minDistance => _fitDistance * 0.05;
  double get _maxDistance => _fitDistance * 20;

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartDistance = _camera.distance;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      // Two fingers: pinch zooms, and the focal point drags the model.
      final scale = details.scale <= 0 ? 1.0 : details.scale;
      setState(() {
        _camera = _camera.copyWith(
          distance: (_gestureStartDistance / scale).clamp(
            _minDistance,
            _maxDistance,
          ),
          pan: _camera.pan + details.focalPointDelta,
        );
      });
      return;
    }
    // One finger: orbit.
    setState(() {
      _camera = _camera.copyWith(
        yaw: _camera.yaw - details.focalPointDelta.dx * _kOrbitRadiansPerPixel,
        pitch:
            (_camera.pitch +
                    details.focalPointDelta.dy * _kOrbitRadiansPerPixel)
                .clamp(-PointCloudCamera.maxPitch, PointCloudCamera.maxPitch),
      );
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Exponential, so a wheel notch moves the same proportion of the way in
    // whether you are across the valley or against the rock.
    final factor = math.exp(event.scrollDelta.dy * _kWheelZoomPerPixel);
    setState(() {
      _camera = _camera.copyWith(
        distance: (_camera.distance * factor).clamp(
          _minDistance,
          _maxDistance,
        ),
      );
    });
  }

  /// The measurement to show, or `null` when there is nothing honest to say.
  String? get _scaleNote {
    final metresPerUnit = widget.metresPerUnit;
    if (metresPerUnit == null || !metresPerUnit.isFinite) return null;
    if (metresPerUnit <= 0) return null;
    final extent = widget.cloud.extent * metresPerUnit;
    if (!extent.isFinite || extent <= 0) return null;
    final rendered = extent >= 10
        ? extent.toStringAsFixed(0)
        : extent.toStringAsFixed(1);
    return '$rendered m across';
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final note = _scaleNote;

    // NO ANIMATION ANYWHERE IN THIS WIDGET — no entry transition, no camera
    // easing, no auto-orbit. That is a deliberate choice rather than an
    // omission: an auto-spinning model is the obvious thing to add here and it
    // is exactly what a reduced-motion user cannot escape. Every camera change
    // is driven directly by a finger or a wheel, so there is nothing for
    // `MediaQuery.disableAnimations` to gate.
    return Listener(
      key: const Key('point-cloud-view'),
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: _PointCloudPainter(
                  cloud: widget.cloud,
                  palette: _palette,
                  scratch: _scratch,
                  camera: _camera,
                  fitDistance: _fitDistance,
                  pointSize: widget.pointSize,
                  fovY: _fovY,
                  background: colors.ground,
                  axisX: colors.accent,
                  axisY: colors.ink2,
                  axisZ: colors.ink3,
                ),
              ),
            ),
            if (note != null)
              Positioned(
                left: 12,
                bottom: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.chrome,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      note,
                      key: const Key('point-cloud-scale-note'),
                      style: TextStyle(fontSize: 12, color: colors.ink2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Radians of orbit per logical pixel of drag. A full turn in roughly a
/// screen-and-a-half of travel.
const double _kOrbitRadiansPerPixel = 0.008;

/// Zoom exponent per logical pixel of wheel scroll.
const double _kWheelZoomPerPixel = 0.0015;

/// Depth bands used for back-to-front ordering and size scaling. Four is
/// enough to stop the far surface of a feature painting over the near one
/// without multiplying the draw-call count by more than four.
const int _kDepthBands = 4;

/// Bits kept per colour channel when building the palette. Four (16 levels per
/// channel, 4096 possible entries) keeps rock texture readable while bounding
/// the per-frame draw calls at `bands x distinct colours present`, which on a
/// natural photo-textured cloud is a few hundred, not a few thousand.
const int _kColourBits = 4;

/// Colour quantisation for one cloud, computed ONCE when the cloud is adopted
/// rather than per frame — it does not depend on the camera.
///
/// [binOfPoint] maps each point to an index into [colours]; [colours] holds the
/// MEAN colour of the points in that bin, not the bin's nominal centre, so a
/// cloud that is all one shade of grey draws in that exact shade rather than
/// in the nearest quantisation step.
class _CloudPalette {
  _CloudPalette._(this.binOfPoint, this.colours);

  final Uint16List binOfPoint;
  final List<Color> colours;

  int get length => colours.length;

  factory _CloudPalette.build(PointCloud cloud) {
    const shift = 8 - _kColourBits;
    const levels = 1 << _kColourBits;
    final lookup = Int32List(levels * levels * levels)..fillRange(0, levels * levels * levels, -1);
    final binOf = Uint16List(cloud.pointCount);
    final sumR = <int>[];
    final sumG = <int>[];
    final sumB = <int>[];
    final counts = <int>[];
    final source = cloud.colors;

    for (var i = 0; i < cloud.pointCount; i++) {
      final p = i * 3;
      final r = source[p];
      final g = source[p + 1];
      final b = source[p + 2];
      final key =
          ((r >> shift) << (2 * _kColourBits)) |
          ((g >> shift) << _kColourBits) |
          (b >> shift);
      var bin = lookup[key];
      if (bin < 0) {
        bin = counts.length;
        lookup[key] = bin;
        sumR.add(0);
        sumG.add(0);
        sumB.add(0);
        counts.add(0);
      }
      binOf[i] = bin;
      sumR[bin] += r;
      sumG[bin] += g;
      sumB[bin] += b;
      counts[bin]++;
    }

    final colours = <Color>[];
    for (var bin = 0; bin < counts.length; bin++) {
      final n = counts[bin];
      colours.add(
        Color.fromARGB(255, sumR[bin] ~/ n, sumG[bin] ~/ n, sumB[bin] ~/ n),
      );
    }
    return _CloudPalette._(binOf, colours);
  }
}

/// Per-frame working buffers, allocated once per cloud and reused. Allocating
/// these inside `paint` would put ~2 MB of garbage on the heap every frame of
/// every drag, which is the kind of thing that shows up as jank rather than as
/// a bug.
class _Scratch {
  _Scratch(int pointCount, int binCount)
    : projected = Float32List(pointCount * 2),
      binOf = Int32List(pointCount),
      offsets = Int32List(binCount + 1),
      cursor = Int32List(binCount),
      ordered = Float32List(pointCount * 2);

  /// Screen-space x,y per point, in cloud order.
  final Float32List projected;

  /// `band * paletteLength + colourBin` per point, or -1 when culled.
  final Int32List binOf;

  /// Start index (in points) of each bin, plus a terminating total.
  final Int32List offsets;
  final Int32List cursor;

  /// Screen-space x,y per point, grouped by bin — what gets drawn.
  final Float32List ordered;
}

class _PointCloudPainter extends CustomPainter {
  _PointCloudPainter({
    required this.cloud,
    required this.palette,
    required this.scratch,
    required this.camera,
    required this.fitDistance,
    required this.pointSize,
    required this.fovY,
    required this.background,
    required this.axisX,
    required this.axisY,
    required this.axisZ,
  });

  final PointCloud cloud;
  final _CloudPalette palette;
  final _Scratch scratch;
  final PointCloudCamera camera;
  final double fitDistance;
  final double pointSize;
  final double fovY;
  final Color background;
  final Color axisX;
  final Color axisY;
  final Color axisZ;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    if (size.isEmpty || cloud.pointCount == 0 || palette.length == 0) return;

    final shortSide = math.min(size.width, size.height);
    if (shortSide <= 0) return;
    // Focal length from the SHORT side, so the framing that fits the model
    // vertically also fits it horizontally on a portrait phone.
    final focal = 0.5 * shortSide / math.tan(fovY / 2);
    final originX = size.width / 2 + camera.pan.dx;
    final originY = size.height / 2 + camera.pan.dy;

    final cosYaw = math.cos(camera.yaw);
    final sinYaw = math.sin(camera.yaw);
    final cosPitch = math.cos(camera.pitch);
    final sinPitch = math.sin(camera.pitch);

    final cx = cloud.centerX;
    final cy = cloud.centerY;
    final cz = cloud.centerZ;
    final radius = math.max(cloud.boundingRadius, 1e-6);
    final distance = camera.distance;
    // Near plane close enough to let the user push inside the cloud, far
    // enough that a point on the eye does not project to infinity.
    final near = math.max(distance * 0.005, 1e-6);
    final depthNear = distance - radius;
    final depthSpan = math.max(2 * radius, 1e-6);

    const bandCount = _kDepthBands;
    final paletteLength = palette.length;
    final binCount = bandCount * paletteLength;

    final projected = scratch.projected;
    final binOf = scratch.binOf;
    final offsets = scratch.offsets;
    final cursor = scratch.cursor;
    final ordered = scratch.ordered;
    offsets.fillRange(0, binCount + 1, 0);

    final positions = cloud.positions;
    final binOfPoint = palette.binOfPoint;

    // Pass 1 — project, cull, and count into bins.
    for (var i = 0; i < cloud.pointCount; i++) {
      final p = i * 3;
      final dx = positions[p] - cx;
      final dy = positions[p + 1] - cy;
      final dz = positions[p + 2] - cz;

      // Yaw about +Y, then pitch about the rotated +X. Written out rather than
      // built as a matrix: at 150k points per frame the matrix object and its
      // indexing cost more than the six multiplies it would save.
      final x1 = cosYaw * dx - sinYaw * dz;
      final z1 = sinYaw * dx + cosYaw * dz;
      final y2 = cosPitch * dy - sinPitch * z1;
      final z2 = sinPitch * dy + cosPitch * z1;

      final depth = distance - z2;
      if (depth <= near) {
        binOf[i] = -1;
        continue;
      }
      final inv = focal / depth;
      projected[i * 2] = originX + x1 * inv;
      // Screen y grows downward; model +Y is up.
      projected[i * 2 + 1] = originY - y2 * inv;

      var band = (((depth - depthNear) / depthSpan) * bandCount).floor();
      if (band < 0) band = 0;
      if (band >= bandCount) band = bandCount - 1;
      final bin = band * paletteLength + binOfPoint[i];
      binOf[i] = bin;
      offsets[bin + 1]++;
    }

    // Prefix sum -> bin start offsets.
    for (var b = 0; b < binCount; b++) {
      offsets[b + 1] += offsets[b];
      cursor[b] = offsets[b];
    }
    final total = offsets[binCount];
    if (total == 0) return;

    // Pass 2 — scatter into bin-grouped order.
    for (var i = 0; i < cloud.pointCount; i++) {
      final bin = binOf[i];
      if (bin < 0) continue;
      final slot = cursor[bin]++;
      ordered[slot * 2] = projected[i * 2];
      ordered[slot * 2 + 1] = projected[i * 2 + 1];
    }

    // Pass 3 — draw FAR BAND FIRST (painter's algorithm), each band at its own
    // stroke width so distance also reads as size.
    final zoom = (fitDistance / distance).clamp(0.5, 4.0);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false;
    for (var band = bandCount - 1; band >= 0; band--) {
      final t = bandCount == 1 ? 0.0 : band / (bandCount - 1);
      paint.strokeWidth = math.max(pointSize * (1.3 - 0.6 * t) * zoom, 0.5);
      for (var entry = 0; entry < paletteLength; entry++) {
        final bin = band * paletteLength + entry;
        final start = offsets[bin];
        final end = offsets[bin + 1];
        if (end <= start) continue;
        paint.color = palette.colours[entry];
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.sublistView(ordered, start * 2, end * 2),
          paint,
        );
      }
    }

    _paintAxisHint(canvas, size, cosYaw, sinYaw, cosPitch, sinPitch);
  }

  /// A small orientation gizmo in the corner. Chrome, so it takes theme
  /// colours; the cloud itself is the only thing drawn in its own colours.
  void _paintAxisHint(
    Canvas canvas,
    Size size,
    double cosYaw,
    double sinYaw,
    double cosPitch,
    double sinPitch,
  ) {
    const length = 18.0;
    final origin = Offset(size.width - 34, size.height - 34);
    Offset project(double x, double y, double z) {
      final x1 = cosYaw * x - sinYaw * z;
      final z1 = sinYaw * x + cosYaw * z;
      final y2 = cosPitch * y - sinPitch * z1;
      // Orthographic on purpose: a perspective gizmo changes length as the
      // user zooms, which reads as the model moving.
      return origin + Offset(x1 * length, -y2 * length);
    }

    final paint = Paint()
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(origin, project(1, 0, 0), paint..color = axisX);
    canvas.drawLine(origin, project(0, 1, 0), paint..color = axisY);
    canvas.drawLine(origin, project(0, 0, 1), paint..color = axisZ);
  }

  @override
  bool shouldRepaint(_PointCloudPainter oldDelegate) =>
      oldDelegate.camera != camera ||
      !identical(oldDelegate.cloud, cloud) ||
      oldDelegate.pointSize != pointSize ||
      oldDelegate.background != background ||
      oldDelegate.fitDistance != fitDistance;
}
