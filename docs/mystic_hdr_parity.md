# Mystic HDR and animated effects

Mystic surfaces and particles previously clipped their RGB to 0–1 before writing the render target. This removed the bright animated energy that glow needs. The reference LDR gate could not detect the problem because it disabled HDR and froze every shader panner at time zero.

The correction preserves the authored HDR values in `mystic_final`, `vfx_dissolve` and `vfx_star`, converts from the Unity project's gamma space, and bounds the linear result only at the half-float maximum of 65504. Shader time, textures, material values, root tracking, alpha and blending modes are unchanged. The example environments enable glow; Mobile also enables the higher-precision HDR 2D viewport buffer.

## Original Unity evidence

The reference is [axieinfinity/unity-axie-mixer3d at 63ec82a](https://github.com/axieinfinity/unity-axie-mixer3d/tree/63ec82afc7deeec242734e70fea4bb9fffa904cc), rendered in Unity 6000.0.73f1 on Metal. The source package assets were unchanged. The same Mystic_Final shader and #883 eye material are used by Town Hunt, whose presentation enables HDR and bloom.

`tests/render_hdr_oracle` contains 48 original Unity reference PNGs: #883 and #2875, combined and separate meshes, eight directions plus idle/walk/attack poses, at shader time 1 second. The exporter reads floating-point HDR, converts gamma to linear, applies exposure 0.01, then converts to display sRGB. Low exposure reveals radiance that an ordinary screenshot clips. Transient shader copies replace only time inputs; material values and source assets are preserved. Provenance is recorded beside the images. Raw EXRs can be regenerated and are intentionally omitted from Git.

The original #883 front view has a peak gamma RGB value of 744.67, and #2875 reaches 36.75. The old Godot shaders reduce both to display white before exposure.

## Validation

| Gate | Result on Godot 4.7.2 / Apple M5 Max |
| --- | --- |
| HDR regression before surface fix | #883 and #2875 fail; peak display RGB 0.098 at exposure 0.01 |
| HDR particle regression before particle fix | Both glow and star materials fail at 0.098 |
| HDR regression after correction | All five fixtures pass in Forward+ and Mobile with HDR 2D |
| Original Unity nonzero-time HDR comparison | 48 images pass; worst MAE 0.0007 |
| Existing LDR comparison | 346 images pass |
| Behavior/material/particle suite | All tests pass, including 135 particle systems |

Run `tools/mystic_hdr.sh forward_plus` and `tools/mystic_hdr.sh mobile` for the GPU regression. It uses real #883 and #2875 materials, four shader times, two imported particle materials, and ordinary #123 as a non-HDR control. It requires a graphics device. Run `tools/render_compare.sh --ref res://tests/render_hdr_oracle` for the original Unity comparison. Both are included in `tools/run_gates.sh`.

Recreate the reference using the existing Unity exporter with `AXIE_GODOT_SAMPLE_JSON` pointing to `tests/goldens/mystic_axies.json`, `AXIE_GODOT_FIXTURES=axie_883,axie_2875`, `AXIE_GODOT_EXPORT_ONLY=render`, `AXIE_GODOT_RENDER_HDR=1`, `AXIE_GODOT_RENDER_SHADER_TIME=1`, `AXIE_GODOT_RENDER_EXPOSURE=0.01`, and a separate `AXIE_GODOT_RENDER_DIR`. See the [exporter instructions](../tools/unity_export/README.md).

## Limits

Bloom kernels and stochastic particle trajectories differ between engines; the test establishes shader radiance and phase behavior, not identical bloom pixels. Compatibility remains an LDR fallback. A scaled combined Axie's height gradient can change its eye colors in the original Unity mixer as well; root tracking is therefore preserved. Fresh original Unity comparisons at scales 1 and 2.15 passed 72 images each.
