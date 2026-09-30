// Executed by verify_glass_shader.py in a disposable asset-bundling project.
// Compare actual compiled shaders, not a Dart reimplementation of the change.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

const _size = 64;

Future<ui.Image> _image(bool geometry, int pattern) {
  final bytes = Uint8List(_size * _size * 4);
  final random = math.Random(3181 + pattern);
  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      final i = (y * _size + x) * 4;
      if (geometry) {
        final dx = x + 0.5 - _size / 2;
        final dy = y + 0.5 - _size / 2;
        final radius = math.sqrt(dx * dx + dy * dy);
        final slope = ((radius - 12) / 18).clamp(0.0, 1.0);
        bytes[i] = (255 * (0.5 + 0.5 * slope * dx / radius)).round();
        bytes[i + 1] = (255 * (0.5 + 0.5 * slope * dy / radius)).round();
        bytes[i + 2] = (255 * math.sqrt(1 - slope * slope)).round();
        bytes[i + 3] = (255 * (31 - radius).clamp(0.0, 1.0)).round();
      } else {
        // Smooth fields, text-like edges, noise and weighted/premultiplied
        // translucent rows. Odd rows model the frost's blurred cloud;
        // even rows hold the sharp backdrop. Include empty platform pixels.
        final alpha = pattern == 3 ? (x < 12 ? 0 : 80 + y * 2) : 255;
        final value = switch (pattern) {
          0 => x / (_size - 1),
          1 => ((x ~/ 3 + y ~/ 4) % 2).toDouble(),
          _ => random.nextDouble(),
        };
        bytes[i] = (alpha * (y.isOdd ? 0.65 : value)).round();
        bytes[i + 1] = (alpha * (y.isOdd ? 0.45 : 1 - value)).round();
        bytes[i + 2] = (alpha * (y.isOdd ? 0.55 : (x % 7) / 6)).round();
        bytes[i + 3] = alpha;
      }
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      bytes, _size, _size, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

Future<Uint8List> _render(ui.FragmentProgram program, List<double> uniforms,
    ui.Image backdrop, ui.Image geometry) async {
  final shader = program.fragmentShader();
  for (var i = 0; i < uniforms.length; i++) {
    shader.setFloat(i, uniforms[i]);
  }
  shader.setImageSampler(0, backdrop);
  shader.setImageSampler(1, geometry);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 64, 64),
    ui.Paint()..shader = shader,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(_size, _size);
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  picture.dispose();
  shader.dispose();
  return data.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('optimized premium shader preserves reference pixels', () async {
    final reference = await ui.FragmentProgram.fromAsset(
        'shaders/reference/liquid_glass_render.frag');
    final current = await ui.FragmentProgram.fromAsset(
        'shaders/current/liquid_glass_render.frag');
    final geometry = await _image(true, 0);
    var cases = 0;
    var worst = 0;
    var differences = 0;
    try {
      for (var pattern = 0; pattern < 4; pattern++) {
        final backdrop = await _image(false, pattern);
        try {
          for (final sigma in [0.3, 0.6, 1.2, 1.8, 1.80001, 2.4, 4.8]) {
            for (var variant = 0; variant < 8; variant++) {
              final dark = variant.isOdd;
              final uniforms = <double>[
                _size.toDouble(), _size.toDouble(), // backdrop size
                0, 0, _size.toDouble(), _size.toDouble(), // geometry
                0.97, 0.97, 0.97, dark ? 0.12 : 0.53, // glass tint
                1.24, variant == 3 ? 0.2 : 0, 32, 1, // optics
                variant == 4 ? 0.6 : 0, 0, dark ? 1.4 : 2.1,
                0, dark ? -1 : 1, // light direction
                0, 1, variant == 5 ? 0.4 : 0, // whitening and pinch
                0.4, 0.5, 0.6, variant == 6 ? 0.6 : 0, // fallback
                0.23 * variant, 0.17 * variant, // fractional capture offset
                0, 0, 1, 0.035, // edge
                variant == 7 ? 1 : 0, 0, // passthrough, body mode
                14, 20, variant == 4 ? 0.7 : 0, // touch
                variant == 2 ? 0 : (dark ? 0.45 : 1), // rim shade
                1, 0.32, 0, variant == 6 ? 0 : 1, // rim light, lens
                variant == 0 ? 0 : (variant == 1 ? 1 : (dark ? 0.85 : 0.73)),
                dark ? -0.45 : 0.4, sigma,
                variant == 2 ? 0 : (dark ? 2.5 : 0.8), // blur weight
              ];
              expect(uniforms, hasLength(46));
              final before =
                  await _render(reference, uniforms, backdrop, geometry);
              final after =
                  await _render(current, uniforms, backdrop, geometry);
              var maximum = 0;
              for (var i = 0; i < before.length; i++) {
                final delta = (before[i] - after[i]).abs();
                maximum = math.max(maximum, delta);
                if (delta > 0) differences++;
              }
              worst = math.max(worst, maximum);
              expect(maximum, lessThanOrEqualTo(1),
                  reason: 'pattern=$pattern sigma=$sigma variant=$variant');
              cases++;
            }
          }
        } finally {
          backdrop.dispose();
        }
      }
    } finally {
      geometry.dispose();
    }
    // ignore: avoid_print
    print('$cases shader comparisons; max channel delta $worst/255; '
        '$differences differing channels out of ${cases * _size * _size * 4}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
