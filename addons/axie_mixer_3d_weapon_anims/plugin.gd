@tool
extends EditorPlugin
## Optional weapon-anims addon. Clip names resolve through AxieWeaponAnims.register.

const INITIALIZER_SCRIPT := preload("res://addons/axie_mixer_3d_weapon_anims/axie_weapon_anim_initializer.gd")


func _enter_tree() -> void:
	add_custom_type(
		"AxieWeaponAnimInitializer",
		"Node",
		INITIALIZER_SCRIPT,
		null
	)


func _exit_tree() -> void:
	remove_custom_type("AxieWeaponAnimInitializer")
