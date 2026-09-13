# Unity → Godot exporter (`AxieGltfExporter.cs`)

One Unity editor script produces everything the Godot port consumes and everything that verifies it:

| Stage (`AXIE_GODOT_EXPORT_ONLY`) | Output | Consumed by |
| --- | --- | --- |
| `pack` | `addons/axie_mixer_3d_assets/` — the glTF asset pack (format 2) | the addon at runtime |
| `oracle` | `tests/oracle/` — Unity transforms / bounds / skinned vertices for 30 fixtures | `tests/oracle_compare.gd` (1615 checks) |
| `render` | `tests/render_oracle/` — Unity reference renders, 8 yaws + 3 animated poses per fixture | `tests/render_compare.gd` / `tools/render_compare.sh` |
| *(separate method)* `AxiePlayableOracle.Export` | `tests/playable_oracle/` — the real `AxiePlayable` driven in Play mode, state + poses + `Completed` frames for 10 scenarios × 2 fixtures | `tests/playable_oracle_compare.gd` (552 checks) |

Default is `pack,oracle`. Schema of the pack: [`addons/axie_mixer_3d/import/catalog_format.md`](../../addons/axie_mixer_3d/import/catalog_format.md). Design notes: [`docs/design.md`](../../docs/design.md).

The pack, the oracle and the reference renders are committed, so nobody needs Unity to use the addon or to run the gates. Re-export only when the Unity package changes.

## Prerequisites

- Unity **6000.0.73f1** with the reference project `unity-axie-mixer3d` (a clone of `axieinfinity/unity-axie-mixer3d`; it references `com.skymavis.axiemixer3d` 1.1.0 and `com.skymavis.axiemixer3d.weaponanims`). The project must stay in **Gamma** colour space — the Godot shaders reproduce that.
- Copy `AxieGltfExporter.cs` to that project's `Assets/Editor/` (assembly `SkyMavis.AxieMixer3D.Dev.Editor`). Unity regenerates the `.meta`.
- Set `AXIE_GODOT_REPO` to this repository (default: a `godot-axie-mixer-3d` checkout next to the Unity project), or the individual `AXIE_GODOT_*_DIR` variables.

## Running

Always run **without** `-nographics`: the pack stage decodes imported (BC7) textures through a GPU blit so the PNGs hold the exact texels Unity samples, and the render stage needs a camera. Batchmode keeps the editor window hidden.

```bash
UNITY=/Applications/Unity/Hub/Editor/6000.0.73f1/Unity.app/Contents/MacOS/Unity
PROJECT=/path/to/unity-axie-mixer3d

# Everything (pack + numeric oracle + reference renders), ~15 min
AXIE_GODOT_EXPORT_ONLY=pack,oracle,render \
"$UNITY" -batchmode -quit -projectPath "$PROJECT" \
  -executeMethod SkyMavis.AxieMixer3D.Dev.Editor.AxieGltfExporter.Export \
  -logFile /tmp/axie_export.log

# One stage
AXIE_GODOT_EXPORT_ONLY=render "$UNITY" -batchmode -quit -projectPath "$PROJECT" \
  -executeMethod SkyMavis.AxieMixer3D.Dev.Editor.AxieGltfExporter.Export -logFile /tmp/axie_render.log

# Playable oracle (Play mode; ~1 min). No -quit: the runner enters Play mode after the method
# returns and exits the editor itself (0, or 1 on failure). Copy AxiePlayableOracle.cs next to
# the exporter first.
"$UNITY" -batchmode -projectPath "$PROJECT" \
  -executeMethod SkyMavis.AxieMixer3D.Dev.Editor.AxiePlayableOracle.Export -logFile /tmp/axie_playable.log
```

The log ends with `[AxieGltfExporter] DONE`; a failure logs `[AxieGltfExporter] FAILED: …` and Unity exits non-zero. The same method is available in the editor as **Tools → Axie Mixer 3D → Export glTF pack for Godot**.

Environment variables:

| Variable | Default |
| --- | --- |
| `AXIE_GODOT_REPO` | `<UnityProject>/../godot-axie-mixer-3d` |
| `AXIE_GODOT_ASSETS_DIR` | `<GodotRepo>/addons/axie_mixer_3d_assets` |
| `AXIE_GODOT_ORACLE_DIR` | `<GodotRepo>/tests/oracle` |
| `AXIE_GODOT_RENDER_DIR` | `<GodotRepo>/tests/render_oracle` |
| `AXIE_GODOT_PLAYABLE_DIR` | `<GodotRepo>/tests/playable_oracle` |
| `AXIE_GODOT_BAKE_MULT` | `4` — clip samples per authored frame (120 samples/s at 30 fps); written to `catalog.json/animation_fps` so `AxieCatalog` re-bakes the glTF tracks at the same rate (docs/design.md §4) |
| `AXIE_GODOT_SAMPLE_JSON` | `<GodotRepo>/tests/goldens/sample_axies.json` (genes of the live-ID fixtures) |
| `AXIE_GODOT_EXPORT_ONLY` | `pack,oracle` |
| `AXIE_GODOT_RENDER_HDR` | unset — `1` enables HDR on both the URP asset and camera, writes raw float EXRs, and writes display PNGs at the requested linear exposure |
| `AXIE_GODOT_RENDER_SHADER_TIME` | `0` — nonzero values compile transient copies of original Mystic shaders with only `_TimeParameters.x` / `_Time.y` replaced by this time; no source assets are edited |
| `AXIE_GODOT_RENDER_EXPOSURE` | `1` — linear exposure for HDR display PNGs; `0.01` exposes bright Mystic variation otherwise clipped by an LDR screenshot |
| `AXIE_GODOT_RENDER_SCALE` | `1` — scale the character and camera equally to test material behavior at the same projected size |
| `AXIE_GODOT_FIXTURES` | unset — comma-separated exact fixture names to export, e.g. `axie_883,axie_2875` |
| `AXIE_GODOT_RENDER_PARTICLES` | unset — **preview only**: `1` keeps the mystic particle renderers and `Simulate`s every system to `AXIE_GODOT_RENDER_PARTICLES_TIME` (0.75 s) with a fixed seed. Use with `AXIE_GODOT_RENDER_DIR=/tmp/…`; never for the committed oracle. `AXIE_GODOT_RENDER_PARTICLES_ONLY=<material-name substring>`, `…_DEBUG=notsa`, `…_CUSTOM1=x,y,z,w`, `…_TSAFRAME=f` isolate one material / module for debugging (docs/design.md §4) |

## What each stage does

**pack** — For every body: skeleton, skinned mesh, all body clips baked with Mecanim (`MecanimSampler`: controller-less Animator + `AnimationClipPlayable`, the runtime's own evaluator, so Loop Pose blending and the held last frame are in the data — never `SampleAnimation`, see docs/design.md §4) at `AXIE_GODOT_BAKE_MULT` × the clip frame rate → `bodies/<Body>.glb`; the weapon-package clips → `weapon_anims/<Body>.glb`. For every part rig prefab: its joint chain, skin and inverse bind matrices → `parts/<Part>_<Rig>.glb`. Every material's serialized properties → `materials/<id>.json`; every referenced texture → `textures/<id>.png` + `textures.json` (imported size, mipmap/filter/wrap/sRGB flags); mystic addon prefabs (materials + particle systems: main/emission/shape/size-colour-rotation-velocity over lifetime, texture-sheet animation incl. Sprites-mode sprite textures, Custom Data, renderer vertex streams) → `addons/<name>.json`; and `catalog.json`. Geometry is mirrored across X once (Unity left-handed → glTF right-handed); Godot flips nothing.

**oracle** — Builds each fixture with the real `AxieFactory` (combine on and off), poses rest and Idle/Walk/Run/AttackCombo at fixed times with the same `MecanimSampler`, and writes world TRS of every transform, renderer bounds and skinned vertex positions (mirrored the same way). Fixtures: eight bodies, six classes, mystic S01, skin/level fallbacks, ten live IDs.

**render** — Renders the same fixtures with a fixed rig (camera `(0, 1.05, 4.6)` looking at `(0, 0.8, 0)`, vertical FOV 30, directional light Euler `(35, 140, 0)`, flat ambient, background `(0.18, 0.20, 0.24)`) at yaws 0…315 and three animated poses, particles disabled, `forceMatrixRecalculationPerRender` on so edit-mode renders use the sampled pose. Mystic materials get their panner speeds and `_Color_Time` zeroed for the duration of the stage (`FreezeShaderTime`; edit-mode `_Time` is wall-clock) so the reference is the t = 0 frame that `render_compare.gd` reproduces with `mystic_time = 0`. Writes `index.json` with the rig (already converted to Godot space) so `tests/render_compare.gd` can rebuild it.

## After re-exporting

```bash
godot --headless --path . -s tests/oracle_compare.gd            # expect: 1615 checks, 0 failures
godot --headless --path . -s tests/playable_oracle_compare.gd   # expect: 552 checks, 0 failures
tools/render_compare.sh                                         # expect: 0 failures
godot --headless --path . -s tests/run_tests.gd                 # expect: ALL TESTS PASSED
```
or `tools/run_gates.sh` for all of them.
