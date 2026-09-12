# Axie Mixer 3D Weapon Anims

Optional clip catalog (`SwordAttack`, `AttackCombo`, `CannonAttack`, …).

1. Enable this plugin after **Axie Mixer 3D**.
2. Add `AxieWeaponAnimInitializer` as a child of `AxieMixerInitializer` (runs after the mixer assigns `AxieFactory.default_factory`).
3. Leave `catalog_path` empty to use the factory's v2 pack (`bodies[].weapon_anims_glb`), or call `AxieWeaponAnims.register(catalog, factory)` after the factory is assigned.

Unregistered weapon names no-op with a warning. They do not crash playback.
