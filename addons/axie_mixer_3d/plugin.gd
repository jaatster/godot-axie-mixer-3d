@tool
extends EditorPlugin

const INITIALIZER_SCRIPT := preload("res://addons/axie_mixer_3d/runtime/axie_mixer_initializer.gd")
const BEHAVIOUR_SCRIPT := preload("res://addons/axie_mixer_3d/runtime/axie_character_3d_behaviour.gd")


func _enter_tree() -> void:
	add_custom_type(
		"AxieMixerInitializer",
		"Node",
		INITIALIZER_SCRIPT,
		null
	)
	add_custom_type(
		"AxieCharacter3DBehaviour",
		"Node3D",
		BEHAVIOUR_SCRIPT,
		null
	)


func _exit_tree() -> void:
	remove_custom_type("AxieMixerInitializer")
	remove_custom_type("AxieCharacter3DBehaviour")
