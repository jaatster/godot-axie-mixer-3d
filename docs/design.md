# Design notes

How the port is built and why it is verified the way it is. The code comments and `README.md` refer to the sections below.

## 1. Pipeline

```
Unity package ──AxieGltfExporter.cs──▶ addons/axie_mixer_3d_assets/   glTF asset pack (format 2), parsed at runtime
                                   ├─▶ tests/oracle/                  numeric oracle: TRS / bounds / skinned vertices, 30 fixtures
                                   └─▶ tests/render_oracle/           pixel oracle: 8 yaws + 3 poses per fixture, fixed rig
              ──AxiePlayableOracle.cs──▶ tests/playable_oracle/        animator oracle: the real AxiePlayable in Play mode
Godot addon ──AxieCatalog → AxieFactory → AxieMeshCombiner → AxiePlayable──▶ AxieCharacter3D
```

- **Unity writes glTF, Godot parses it at runtime.** One `bodies/<Body>.glb` per body (skeleton, skinned mesh, every body clip), one `parts/<Part>_<Rig>.glb` per part rig prefab (its own joint chain, skin and inverse bind matrices), `weapon_anims/<Body>.glb` (animation only), `materials/<id>.json` (every serialized property of every Unity material), `textures/<id>.png` (the *imported* texture as Unity samples it, BC7 decoded through a GPU blit) with `textures.json`, `addons/<name>.json` (mystic glow prefabs and particle systems), `catalog.json`. Schema: [`addons/axie_mixer_3d/import/catalog_format.md`](../addons/axie_mixer_3d/import/catalog_format.md).
- **Runtime loading is the only loading.** `AxieCatalog` parses glbs with `GLTFDocument` and PNGs with `Image.load_from_file`; the pack directory carries a `.gdignore` so the editor importer (track optimisation, mesh compression, texture import settings) never sits between the verified data and the user. Exported games add `addons/axie_mixer_3d_assets/*` to the export preset's non-resource include filter.
- **Coordinates are mirrored across X once, in the exporter** (Unity left-handed → glTF right-handed: negate position X and quaternion Y/Z, mirror matrices, flip winding where the world determinant is negative). Nothing is flipped at runtime. The pack's front is `+Z`; a camera on `+Z` sees the face at yaw 0.

## 2. Rig and mesh combine

- Part joints stay part joints: a part glb carries the `*_Offsets` / `*_Scale` / `*_JNT` chain that Unity's `SkinnedMeshRenderer.bones[]` names, with the authored inverse bind matrices. The factory parents the part under a `BoneAttachment3D` on the body's `Root_<Rig>_JNT`, exactly as Unity parents the part prefab under that joint.
- Pose is absolute local TRS (Godot 4 `bone_pose` starts at `bone_rest`; Unity Generic clips write parent-local `m_Local*`). Skin binds resolve by name with the original inverse bind matrices; `ARRAY_BONES` index the Skin bind list.
- `AxieMeshCombiner` unions the named binds of every skinned renderer into one Skin, remaps `ARRAY_BONES`, keeps vertices in mesh space, flips winding / `tangent.w` where the renderer's world basis has a negative determinant, parents the merged `MeshInstance3D` under the body skeleton and frees the sources — the same outcome as Unity's combiner. The unskinned mystic glow stays on its attach and is never combined. Combining changes the Mystic height-gradient reference bone; at non-unit scale, combined and uncombined Mystic colors can differ in both Unity and Godot.

## 3. Materials and colour space

The reference Unity project is **Gamma**. `s_axie_mixer_v5.gdshader` samples textures as raw sRGB bytes, converts `source_color` uniforms back to sRGB, does the shader graph's math in that space and converts once to linear on output. HDR colour uniforms (`_RimColor`, `_Color0`, `_Top`, `_Mid`, `_Color3`, `_Color_UV2`) are linear `Vector4`s; `source_color` ones are `Color` (a `Color` stored on a plain `vec4` uniform is dropped by `Material.duplicate()`). The main light is the scene's `DirectionalLight3D`, read inside `light()` with Unity's shadow band. Every shader-used uniform is authored from the exported material JSON; textures keep Unity's imported size, mipmaps, filter and wrap.

Mystic parts (`mystic_final.gdshader`): opaque + clip (`clip(lerp(_Alpha_UV1, 1, uv2.r) - 0.5)`), gold mask from UV2 (`has_uv2` stamped after colorize and combine, combine pads the channel), vertex-stage `positionOS.y` in the renderer's root-bone frame tracked per frame, shader-computed UVs keep Unity's V-up convention (matcap `vec2(n.x, -n.y)`, panners negate the V scroll speed), `ExtraPrePass` outline as `cull_front` on `next_pass`.

Mystic glow VFX (`AxieMysticGlow`, `vfx_dissolve.gdshader`, `vfx_star.gdshader`, `vfx_particle_common.gdshaderinc`): every Unity particle system in the addon prefab becomes a `GPUParticles3D`. Unity's emission cadence (rate × duration + bursts, separate per-particle lifetime) is emulated in the vertex shader from the Godot particle phase; texture-sheet Sprites mode becomes `sprite_rect` with a texture override; ZTest-Equal systems draw nothing but keep their node so children keep their transforms. These stay outside the pixel gate (`tools/render_compare.sh <fixture> --particles` compares them by eye).

## 4. Animation

Mystic surface, glow and star shaders preserve HDR through the final color conversion, bounded only by the half-float target maximum (65504). The viewport applies display clipping after glow. Consumers should enable `Environment.glow_enabled`; Mobile consumers also need `Viewport.use_hdr_2d` to avoid the default buffer's low HDR range. The examples configure both. The additional [HDR proof](mystic_hdr_parity.md) uses original Unity float renders and nonzero shader time; the LDR gate alone cannot detect premature HDR clipping.

**Clips are baked with Mecanim, at 120 samples/s.** `AnimationClip.SampleAnimation` is *not* what the Animator shows: every clip in the package has Loop Pose on, and Mecanim spreads the start/end pose difference over the clip (position `p(t) + (p₀ − p_end)·t/L`, rotation `q(t)·nlerp(I, q_end⁻¹·q₀, t/L)`) and holds the last pose at `clip.length` instead of wrapping. The exporter therefore poses rigs with `MecanimSampler` — a controller-less, avatar-less `Animator` (the runtime's exact setup) driven by an `AnimationClipPlayable` through `PlayableGraph.Evaluate()` — in the pack bake and in every oracle. Authored Hermite tangents between the 30 fps keys bend fast joints a few degrees away from the chord, so clips are sampled at `AXIE_GODOT_BAKE_MULT` (4) × the clip frame rate with an exact end key at `clip.length`; `catalog.json/animation_fps` is passed to `GLTFDocument.generate_scene(state, bake_fps)` because Godot's importer re-bakes every TRS track at 30 fps otherwise. Tracks stay linear: 2× was measurably short (0.017 basis error), 4× linear is 0.0034 worst case.

**`AxiePlayable` mirrors Unity's PlayableGraph frame by frame.** `_tick(delta)` decides loop wrap and completion on the clip times left by the previous advance, then advances every clip playable (`set_time` skips that playable's next advance, as `Playable.SetTime` does), then poses. A clip fully specifies its pose (constant channels are kept as two keys), so blending matches the mixer exactly; channels no input animates return to rest, and stopping everything writes the bind pose. A 1D blend is its own mixer: its clips are mixed and normalised before the outer crossfade. Blend weights and phase-lock follow `AxiePlayable.cs` line for line: Idle(0) / Walk(1) / Run(3.5) thresholds, the shared normalised phase across the active pair.

## 5. Outline

`set_outline_layer(outline, base)` sets `VisualInstance3D.layers` and keeps the excluded parts (eyes, mouth) on the base layer. Two modes match Unity's two: sibling `AxieOutlineHull` meshes (`outline_inflate.gdshader`, `cull_front`, same mesh/skin/skeleton as the source) when the layers differ, and `AxieOutlinePostProcess` (a `CompositorEffect` with Unity's Sobel uniforms) for the post-process variant.

## 6. Verification

Parity is measured against Unity's own output, never against a screenshot taken by hand. All oracles are committed, so nobody needs Unity to run the gates.

| Gate | What it checks |
| --- | --- |
| `tests/oracle_compare.gd` | World TRS of every transform, renderer bounds and skinned vertex positions of 30 fixtures (8 bodies × combine on/off, 6 classes, mystic, skin/level fallbacks, 10 live IDs) at rest and at fixed Idle/Walk/Run/AttackCombo times — 1615 checks |
| `tests/playable_oracle_compare.gd` | The real Unity `AxiePlayable` driven at `Time.captureDeltaTime = 1/60` through 10 scenarios (one-shots, crossfades, queues, 1D blends with phase-lock, default blends, pause/time scale, interrupt, seek, `complete()`, user clips, a weapon clip): animator state, every posed transform, the frame of every `completed` event — 552 checks |
| `tests/render_compare.gd` | The same fixtures rendered in a hidden Forward+ viewport at 8 yaws + 3 poses against Unity renders with the same camera and light (HDR/MSAA off, shader time frozen on both sides); mean absolute error ≤ 0.02 and bad-pixel fraction ≤ 0.03 per image — every fixture sits at ≤ 0.007, mystic ≤ 0.003 |
| `tests/run_tests.gd` | Gene decode/encode, part fallback chain, descriptor merge, blend weights, every `AnimNames` / `WeaponAnimNames` clip on every body, outline, avatar, weapon attach, mystic VFX, catalog integrity |
| `tools/check_examples.sh` | Every example scene runs headless without script errors |

Gates fail closed: a missing oracle file is a failure, not a skip. A fixture that builds but differs from Unity is a failure however plausible it looks.

Non-goals: matching URP post-processing or tonemapping outside the fixed oracle rig; Unity editor tooling as Godot editor plugins; a C# / GDExtension rewrite.
