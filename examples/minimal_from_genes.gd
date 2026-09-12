extends Node3D
## Smallest product path: initializer in the scene, from_genes, loop Idle.

const DemoKit := preload("res://examples/demo_kit.gd")

var _axie: AxieCharacter3D


func _ready() -> void:
	DemoKit.ensure_bootstrap(self)
	DemoKit.ensure_stage(self)
	_axie = AxieCharacter3D.from_genes(DemoKit.SAMPLE_GENES)
	if _axie == null or _axie.root == null:
		push_error("from_genes returned null. Add AxieMixerInitializer (see bootstrap.tscn).")
		return
	add_child(_axie.root)
	if _axie.playable:
		_axie.playable.play(AnimNames.Idle, "", true)


func _exit_tree() -> void:
	if _axie:
		_axie.dispose()
	_axie = null
