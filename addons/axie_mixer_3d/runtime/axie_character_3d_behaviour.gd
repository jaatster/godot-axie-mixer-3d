class_name AxieCharacter3DBehaviour
extends Node3D

@export var axie_genes: String = ""
var axie_descriptor: AxieDescriptor

var character: AxieCharacter3D

var playable: AxiePlayable:
	get:
		return character.playable if character else null


func _ready() -> void:
	if character == null:
		rebuild()


func _exit_tree() -> void:
	_cleanup()


func rebuild() -> void:
	if not axie_genes.strip_edges().is_empty():
		axie_descriptor = AxieDescriptor.from_genes(axie_genes)
	if character != null:
		character.apply_descriptor(axie_descriptor)
		return
	character = AxieCharacter3D.from_descriptor(axie_descriptor)
	if character == null:
		return
	add_child(character.root)


func refresh() -> void:
	rebuild()


func _cleanup() -> void:
	if character:
		character.dispose()
	character = null
