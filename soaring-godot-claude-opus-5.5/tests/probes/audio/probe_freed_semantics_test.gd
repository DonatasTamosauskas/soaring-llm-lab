extends TestCase
## Verifier probe: how GDScript 4.7 treats a freed Bird reference in the
## comparisons CallVoices relies on (v.bird != null, v.bird == other).

func test_freed_reference_semantics() -> void:
	var a := Node3D.new()
	add_child(a)
	var b := Node3D.new()
	add_child(b)
	var held: Variant = a
	a.free()
	var ne_null: bool = held != null
	var valid := is_instance_valid(held)
	var eq_other: bool = held == b
	print("[audio] freed: (held != null)=%s valid=%s (held == other)=%s" % [ne_null, valid, eq_other])
	metric("freed_ne_null", ne_null)
	metric("freed_valid", valid)
	check(true, "semantics recorded")
	b.free()
