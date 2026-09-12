# Godot Axie Mixer 3D

Godot **4.7** (Forward+) port of Sky Mavis **Axie Mixer 3D** (`com.skymavis.axiemixer3d` **1.1.0** and the optional `com.skymavis.axiemixer3d.weaponanims`). Assembles fully rigged, coloured, animated 3D Axies at runtime from a 512-bit gene string by mixing modular parts onto a shared body skeleton.

Not an official Sky Mavis release. This is a port of [`axieinfinity/unity-axie-mixer3d`](https://github.com/axieinfinity/unity-axie-mixer3d); the code, the asset pack and the oracles are derived from that package and are distributed under the **same license** — `LICENSE.md` is the upstream package's license, verbatim. Use requires an agreement with Sky Mavis, exactly as for the Unity package.

## Parity with Unity

The port is held to the Unity package's own output, produced by the same exporter that generates the asset pack and committed under `tests/`:

| Gate | Command | Result |
| --- | --- | --- |
| Numeric — every transform, renderer bound and skinned vertex of 30 fixtures (8 bodies × combine on/off, 6 classes, mystic, fallbacks, 10 live IDs) at rest and at fixed Idle/Walk/Run/AttackCombo times | `godot --headless --path . -s tests/oracle_compare.gd` | `1615 checks, 0 failures` |
| Animator — the real Unity `AxiePlayable` driven frame by frame in Play mode through 10 scenarios (one-shots, crossfades, queues, 1D blends with phase-lock, default blends, pause/time scale, interrupt, seek, `complete()`, user clips, weapon clips): state, every posed transform and every `completed` frame | `godot --headless --path . -s tests/playable_oracle_compare.gd` | `552 checks, 0 failures` |
| Pixels — the same fixtures rendered at 8 yaws + 3 animated poses against Unity renders with the same camera and light | `tools/render_compare.sh` | mean abs error ≤ 0.02 per image (every fixture sits at ≤ 0.007, mystic at ≤ 0.003) |
| Behaviour — gene codec, part fallback, blend weights, every `AnimNames`/`WeaponAnimNames` clip on every body, outline, avatar, weapon attach, catalog integrity | `godot --headless --path . -s tests/run_tests.gd` | `ALL TESTS PASSED` |
| Examples run headless without script errors | `tools/check_examples.sh` | |

`tools/run_gates.sh` runs all five (`--no-render` on a machine without a display). How the pack and the oracles are made, and why clips are baked with Mecanim at 120 samples/s: [`docs/design.md`](docs/design.md).

## Layout

| Path | What |
| --- | --- |
| `addons/axie_mixer_3d/` | The addon: `core/` (descriptor, gene decode, part resolver), `runtime/` (factory, character, combiner, catalog, avatar), `animation/` (playable, blend, clip names), `outline/`, `shaders/`, `import/` (material builder, pack format doc) |
| `addons/axie_mixer_3d_weapon_anims/` | Optional weapon/action clips package (`AxieWeaponAnims`, `AxieWeaponAnimInitializer`, `WeaponAnimNames`) |
| `addons/axie_mixer_3d_assets/` | Generated glTF asset pack (format 2, ~170 MB). Loaded at runtime; `.gdignore` keeps the editor from importing it |
| `examples/` | Community examples (below) |
| `tests/` | Headless test runner, numeric oracle (`oracle/`), playable oracle (`playable_oracle/`), render oracle (`render_oracle/`), pinned sample genes |
| `tools/unity_export/` | The Unity 6000.0 exporter that produces the pack and the three oracles |
| `docs/design.md` | Design notes: pipeline, rig, materials, animation, verification |

## Setup

1. Enable **Axie Mixer 3D** (and optionally **Axie Mixer 3D Weapon Anims**) in Project → Project Settings → Plugins.
2. Put an `AxieMixerInitializer` node in the tree before creating characters — `examples/bootstrap.tscn` is a ready-made one with the weapon initializer as its child. It loads `res://addons/axie_mixer_3d_assets/catalog.json` and assigns `AxieFactory.default_factory` in `_enter_tree` (Unity `Awake`, execution order −10000). `from_genes` / `from_descriptor` return `null` with an error if it is missing.
3. When exporting a game, add `addons/axie_mixer_3d_assets/*` to the export preset's *Filters to export non-resource files*; the pack is read with `FileAccess`, not imported.

## Public API

Types keep their Unity names as `class_name`s; members are the snake_case spelling of the Unity member.

```gdscript
# After AxieMixerInitializer is in the tree:
var axie := AxieCharacter3D.from_genes("0x...")
if axie == null:
    return
add_child(axie.root)

var playable := axie.playable
playable.set_default_blend([
    {"clip_name": AnimNames.Idle, "threshold": 0.0},
    {"clip_name": AnimNames.Walk, "threshold": 1.0},
    {"clip_name": AnimNames.Run, "threshold": 3.5},
])
playable.set_speed(1.5)                       # drives the locomotion blend (phase-locked)
playable.play(AnimNames.Stun)                 # one-shot, returns to the default when done
playable.play(WeaponAnimNames.SwordAttack)    # weapon package
playable.play(AnimNames.Walk, "", true)       # loop
axie.set_outline_layer(2)                     # draw-objects outline; eyes/mouth stay on layer 1
axie.set_outline_layer(1)                     # outline off
axie.dispose()
```

| Unity | Godot |
| --- | --- |
| `AxieFactory.Default` / `CreateCharacter` | `AxieFactory.default_factory` / `create_character` |
| `AxieCharacter3D.FromGenes` / `FromDescriptor` | `AxieCharacter3D.from_genes` / `from_descriptor` |
| `AxieCharacter3D.Root`, `Playable`, `SetOutlineLayer`, `GetAnimClip`, `Dispose` | `root`, `playable`, `set_outline_layer`, `get_anim_clip`, `dispose` |
| `AxieCharacter3D.Left/RightWeaponAttachPoint` | `left_weapon_attach_point` / `right_weapon_attach_point` (null on bodies without `Root_Weapon_*_JNT`, as in Unity) |
| `AxieDescriptor.FromGenes`, `AxiePartDescriptor`, `AxieInstantiationParams` | same names, snake_case members |
| `AxiePlayable.Play / Queue / PlayBlend / SetDefault / SetDefaultBlend / SetSpeed / Stop / Pause / Resume / Interrupt` | `play / queue / play_blend / set_default / set_default_blend / set_speed / stop / pause / resume / interrupt` |
| `AxieAvatarRenderer.Render`, `AxieAvatarRenderParams` | `AxieAvatarRenderer.render`, `AxieAvatarRenderParams` |
| Outline post-process renderer feature | `AxieOutlinePostProcess.attach_to_camera(camera)` |
| `AxieWeaponAnims.Register / Unregister`, `AxieWeaponAnimInitializer` | `AxieWeaponAnims.register / unregister`, `AxieWeaponAnimInitializer` |
| `AnimNames.*`, `WeaponAnimNames.*` | same constants (`Cannon*` resolve to the art's `Canon*` clips) |

Part fallback when a skin/level is not shipped: S{skin} L{level} → S{skin} L1 → S00 L{level} → S00 L1, then the part is skipped with a warning (`has_part` is exact).

## Examples

| Scene | Unity analog | Shows |
| --- | --- | --- |
| `examples/minimal_from_genes.tscn` | README `FromGenes` snippet | Initializer + `from_genes` + looping Idle, in 24 lines |
| `examples/mixer_demo.tscn` (main scene) | `AxieMixer3DExample` | Genes / Axie-ID input (fetches genes from the public GraphQL API), body, class, part and colour pickers, Idle→Walk→Run blend, every body and weapon clip, combine toggle, outline None / Draw-Objects / Post-Process, orbit camera |
| `examples/collection_demo.tscn` | `AxieCombinationsDebug` | 8 bodies × 6 classes grid, skin cycling |
| `examples/spawner_demo.tscn` | `AxieMixer3DSpawner` | Seeded random grid via `from_descriptor`, fps and mesh counters |
| `examples/avatars_demo.tscn` | `AxieAvatars` | Off-screen `AxieAvatarRenderer` snapshots |

```bash
godot --path . res://examples/mixer_demo.tscn
```

## Contributing

Run `tools/run_gates.sh` before opening a pull request (`--no-render` without a GPU; CI runs the headless gates on every push). A change that moves a gate needs a matching oracle re-export, or a note in `docs/design.md` explaining why Unity's output is the one that is wrong. Never add assets that are not in `com.skymavis.axiemixer3d` 1.1.0 / `weaponanims`, and never relicense.

## Regenerating the asset pack

Only needed when the Unity package changes. `tools/unity_export/README.md` documents the one-command export (pack + numeric oracle + reference renders) and the gates to re-run afterwards. The pack format is described in `addons/axie_mixer_3d/import/catalog_format.md`.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `from_genes` / `from_descriptor` returns `null` | No `AxieMixerInitializer` in the tree |
| Weapon clip warns "not found on this body" | Weapon package not registered (`AxieWeaponAnimInitializer` or `AxieWeaponAnims.register`) |
| A part is missing | Catalog has no asset for that class + variant + skin + level; the fallback chain ran out and the part was skipped (warning in the log) |
| Mixer demo "Fetch blocked (HTTP 403) and curl is unavailable" | Cloudflare's bot check rejects Godot's built-in HTTP client by TLS fingerprint (Unity's and `curl` pass). On desktop the demo retries through the system `curl` automatically; elsewhere run the GraphQL query the label prints and paste the genes |
| Characters vanish in an exported build | The pack folder was not added to the export filter |
| No shadow band on the characters | The V5 shader takes Unity's "main light" from the scene's `DirectionalLight3D`; add one (only its direction matters) |

Call `axie.dispose()` when a character is done; leaving `root` in the tree leaks the combined meshes and materials.
