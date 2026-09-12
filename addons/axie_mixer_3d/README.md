# Axie Mixer 3D (Godot addon)

Godot 4.7 port of Sky Mavis **Axie Mixer 3D** 1.1.0. Assembles a rigged, coloured, animated 3D Axie at runtime from a 512-bit gene string.

1. Enable **Axie Mixer 3D** in Project Settings → Plugins (and optionally **Axie Mixer 3D Weapon Anims**).
2. Put an `AxieMixerInitializer` node in your scene before any character is created (`res://examples/bootstrap.tscn` is a ready-made one, with the weapon initializer as its child). It loads `res://addons/axie_mixer_3d_assets/catalog.json` and assigns `AxieFactory.default_factory`.
3. Build characters:

```gdscript
var axie := AxieCharacter3D.from_genes("0x...")   # null if the initializer is missing
if axie == null:
    return
add_child(axie.root)
axie.playable.play(AnimNames.Idle, "", true)      # loop
axie.playable.play(WeaponAnimNames.SwordAttack)   # one-shot, optional weapon package
axie.set_outline_layer(2)                         # draw-objects outline; eyes/mouth stay on layer 1
# ...
axie.dispose()
```

Unity name → Godot name is a mechanical `PascalCase → snake_case` mapping (`AxieFactory.Default` → `AxieFactory.default_factory`, `AxieCharacter3D.FromGenes` → `AxieCharacter3D.from_genes`, `Playable.Play` → `playable.play`, …). Types keep their Unity names as `class_name`s.

The asset pack lives in `res://addons/axie_mixer_3d_assets/` (format described in `import/catalog_format.md`) and is loaded at runtime, not imported by the editor; exported games must include that folder through the export preset's non-resource filter (`addons/axie_mixer_3d_assets/*`).

See the repository `README.md` for the examples, the parity gates and the design records.
