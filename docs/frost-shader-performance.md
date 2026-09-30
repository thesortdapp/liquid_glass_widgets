# Premium frost shader performance — ALBO-3181

This patch preserves every glass surface and the existing light/dark materials.
It changes the calculation in `shaders/liquid_glass_render.frag`, not quality
tiers, blur strength, frost weighting, refraction, or the number of samples in
the frost kernel.

## Changes

- At physical sigma <= 1.8 (the app's 0.6 logical-pixel ghost blur through 3x
  DPR), generate the nine horizontal Gaussian weights by centre-out recurrence.
  The kernel remains mathematically equivalent: its horizontal exponentials
  fall from nine to three, and its total from fourteen to eight. Starting at
  the centre avoids underflow for small sigma. Wider kernels keep the original
  direct calculation because their rounded sample spacing can be non-uniform.
- Where frost replaces the entire sharp colour and platform-view passthrough
  does not need its alpha, skip that discarded refraction sample: four texture
  reads, or twelve with chromatic dispersion. Partial hairlines and passthrough
  retain the original samples.
- Where the hairline is fully sharp, skip the frost calculation whose colour
  would otherwise be discarded.

The 45 ghost samples, two cloud samples, wide frost blur, colour-weighting
pass, shadows, and resolution are retained. This is a bounded improvement to
the final fragment pass, not a solution to all compositing costs.

## Reproduce the checks

```sh
python3 tool/verify_glass_shader.py
# macOS, headless — no app window or simulator:
python3 tool/verify_glass_shader.py --metal-benchmark
flutter analyze
flutter test
```

The tool builds a disposable Flutter test project using the original source
from commit `5f424525582e6d6bdea13d7d14afd2910d20a79d` and the current shader.
That commit must be available locally; use `--reference` to override it.
Reference shaders and test assets never ship in the library's asset bundle.

Compilation passes for SkSL, Metal, Vulkan, GLES and GLES3 runtime targets.
The pixel test draws both compiled shaders against four backdrop patterns,
seven sigmas, and eight material/interaction variants: 224 cases. It exercises
fractional positions, the fast-path boundary, light/dark colours, the fully
sharp hairline, no frost, partial/full frost opacity, zero blur weight,
passthrough alpha, fallback colour, pinch, touch and chromatic dispersion.

The current result is a maximum channel difference of **1/255**, affecting
178 of 3,670,016 channels. This is a shader-output comparison, not an on-device
visual inspection of entire pages.

## Metal microbenchmark

The benchmark compiles those same shaders into Metal and draws offscreen
capsules on the **Apple M4 Pro**. It retains all original frost texture reads,
alternates reference/current ordering, warms up both pipelines, and reports
the median of 20 GPU timing samples, each averaging 16 render passes. The
following are two consecutive runs of the final patch:

| Capsule texture | Appearance | Run 1 reduction | Run 2 reduction |
| --- | --- | ---: | ---: |
| 256 × 128 | Light | 6.3% | 12.4% |
| 256 × 128 | Dark | 9.3% | 12.6% |
| 1024 × 512 | Light | 11.1% | 10.0% |
| 1024 × 512 | Dark | 11.1% | 9.8% |

For the large light surface, reference/current times were 0.1834/0.1631 ms
in run 1 and 0.1824/0.1641 ms in run 2. Small-surface timings are more
sensitive to fixed overhead and GPU clock variation. Metal output also
differed by at most 1/255 per channel.

These numbers cover **only the final shader**, excluding Flutter's backdrop
copies, frost blur, weight pass, geometry, and shadows. They are neither a
whole-frame improvement nor an iPhone energy/temperature measurement. A prior
version with more temporary arrays was rejected after inconsistent/regressed
small-surface timings despite equivalent pixels; fewer arithmetic operations
alone are insufficient evidence of a faster shader.

## App integration and device validation

The public fork is https://github.com/thesortdapp/liquid_glass_widgets, with
this change on `albo-3181-preserve-glass-reduce-shader-work`. The app consumes
an exact Git commit from that fork through its `pubspec.yaml` override and
lockfile; no sibling checkout is required. The temporary local
`pubspec_overrides.yaml` used during development is removed when switching to
the GitHub pin. Run `flutter pub get` and perform a full rebuild to fetch the
package and rebundle its shaders.

The app's 34 glass facade, bar-backdrop and sheet-animation tests pass against
the local package. The package's 3,159 tests pass; package analysis is clean.
App facade analysis has 21 existing diagnostics (one unused-field warning and
20 infos); this patch changes no app Dart source. `dart doc --dry-run` currently
fails inside `DartdocOptionContext.sdkDir` with a null/String type error using
both installed Dart and Flutter's bundled Dart, before producing diagnostics.

On the iPhone, compare the same screen/content and gestures from equivalent
starting temperature and charging conditions in a profile build with
`ALBO_HEAT_MONITOR=true`. Record idle frames, raster times, thermal transitions
and footprint. First establish that idle screens stop producing frames; an
unrelated perpetual animator can still run the optimized shader continuously.
No phone/simulator UI verification or iPhone thermal measurement was performed
for this patch.

## Further work

For a larger gain, prototype a reusable weighted ghost prefilter, then compare
its additional texture allocation and pass overhead against the 45 taps it
would replace. Fractional refraction coordinates, luminance weighting,
transparency and the alternating frost/sharp rows all have to survive; an
ordinary separable Gaussian is not a drop-in replacement. Sharing the wide
frost blur across compatible non-overlapping surfaces is another candidate,
but the current layers deliberately sample previously drawn content, so a
shared backdrop must preserve that ordering. Neither is enabled by this patch.
