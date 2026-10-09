extends RefCounted
## DIAGNOSTICS for the soak (integration hygiene, 2026-09-27): where do
## objects and memory go between two starts of the same run?
##
##  * reach(): every Object reachable from the scene tree (and the static
##    caches the caller names) through children, properties of Object /
##    Array / Dictionary type (engine properties and script variables),
##    metadata and SIGNAL CONNECTIONS (the target and the bound arguments of
##    every connection: a pending `await` is a GDScriptFunctionState held by
##    the bound arguments of a one-shot connection, a lambda connected every
##    run keeps what it captured). Returns counts by class and by a path
##    pattern (digits folded), so two censuses taken at the same moment of
##    two runs can be diffed: what grows run after run holds the creep.
##  * MemTrace: probe nodes at the edges of the physics and idle priority
##    groups the game uses record OS.get_static_memory_usage() at each; the
##    growth between two probes is charged to that bracket (the "between
##    frames" bracket is the engine: the physics server's step, deferred
##    calls, queue_free, the audio and rendering servers). Jumps over a
##    threshold are logged with the moment's context.
##
## Performance.OBJECT_RESOURCE_COUNT counts only resources in the resource
## cache (loaded from disk); resources made in code show up here, by class.

const DIGITS := "0123456789"


static func _fold(s: String) -> String:
	var out := ""
	var prev_digit := false
	for ch in s:
		if DIGITS.contains(ch):
			if not prev_digit:
				out += "#"
			prev_digit = true
		else:
			out += ch
			prev_digit = false
	return out


static func _cls(o: Object) -> String:
	var sc: Variant = o.get_script()
	if sc is Script and (sc as Script).get_global_name() != &"":
		return String((sc as Script).get_global_name())
	if sc is Script:
		var p := (sc as Script).resource_path
		if not p.is_empty():
			return p.get_file().get_basename()
	return o.get_class()


## Reachable objects: {"total": n, "by_class": {cls: n}, "by_path": {"cls @ pattern": n}, "ids": {id: "cls @ path"}}.
## `statics` maps a name to a value (an Array / Dictionary / Object) held
## by a script's static variable.
static func reach(tree: SceneTree, statics: Dictionary) -> Dictionary:
	var by_class := {}
	var by_path := {}
	var ids := {}
	var seen := {}
	var stack: Array = []
	stack.append([tree.root, "/root"])
	for k: String in statics:
		stack.append([statics[k], "static " + k])
	# The SceneTree and the engine's singletons: what they hold through
	# properties and signal connections (a lambda connected to the tree's
	# frame signals, a tracker, a bus effect).
	stack.append([tree, "SceneTree"])
	for sn in Engine.get_singleton_list():
		if sn in ["GodotSharp", "JavaClassWrapper", "JavaScriptBridge"]:
			continue
		var so: Object = Engine.get_singleton(sn)
		if so != null:
			stack.append([so, "singleton " + sn])
	var budget := 2000000
	while not stack.is_empty() and budget > 0:
		budget -= 1
		var it: Array = stack.pop_back()
		var v: Variant = it[0]
		var path: String = it[1]
		match typeof(v):
			TYPE_ARRAY:
				var i := 0
				for e: Variant in v:
					if typeof(e) in [TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_CALLABLE, TYPE_SIGNAL]:
						stack.append([e, "%s[%d]" % [path, i]])
					i += 1
				continue
			TYPE_DICTIONARY:
				for dk: Variant in v:
					var dv: Variant = v[dk]
					if typeof(dk) in [TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY]:
						stack.append([dk, "%s{key}" % path])
					if typeof(dv) in [TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_CALLABLE, TYPE_SIGNAL]:
						stack.append([dv, "%s{%s}" % [path, str(dk).left(24) if typeof(dk) in [TYPE_STRING, TYPE_STRING_NAME, TYPE_INT] else "k"]])
				continue
			TYPE_CALLABLE:
				var cb: Callable = v
				var co: Object = cb.get_object() if cb.is_valid() or cb.is_custom() else null
				if co != null:
					stack.append([co, "%s(callable %s)" % [path, cb.get_method() if cb.is_standard() else "lambda"]])
				for ba: Variant in cb.get_bound_arguments():
					stack.append([ba, "%s(bound)" % path])
				continue
			TYPE_OBJECT:
				if not is_instance_valid(v):
					continue
			_:
				continue
		var o: Object = v
		if o == null:
			continue
		var oid := o.get_instance_id()
		if seen.has(oid):
			continue
		seen[oid] = true
		var cls := _cls(o)
		by_class[cls] = int(by_class.get(cls, 0)) + 1
		var pk := "%s @ %s" % [cls, _fold(path)]
		by_path[pk] = int(by_path.get(pk, 0)) + 1
		ids[oid] = "%s @ %s" % [cls, path]
		var np := path
		if o is Node:
			var n := o as Node
			np = str(n.get_path()) if n.is_inside_tree() else path + "/" + String(n.name)
			for c in n.get_children(true):
				stack.append([c, "%s/%s" % [np, c.name]])
		# Properties holding objects or containers (engine and script).
		for pr: Dictionary in o.get_property_list():
			var t: int = pr["type"]
			if not (t in [TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_CALLABLE]):
				continue
			var usage: int = pr["usage"]
			if not (usage & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_SCRIPT_VARIABLE)):
				continue
			var pn: String = pr["name"]
			if pn in ["script", "owner", "multiplayer"] or (o is Node and pn in ["_import_path"]):
				continue
			var pv: Variant = o.get(pn)
			if typeof(pv) == TYPE_OBJECT and (not is_instance_valid(pv) or pv is Node):
				continue  # nodes are reached through the tree
			stack.append([pv, "%s.%s" % [np, pn]])
		for mk in o.get_meta_list():
			stack.append([o.get_meta(mk), "%s:meta(%s)" % [np, mk]])
		# Signal connections: targets and bound arguments.
		for sg: Dictionary in o.get_signal_list():
			for conn: Dictionary in o.get_signal_connection_list(sg["name"]):
				var cb2: Callable = conn["callable"]
				var tgt: Object = cb2.get_object()
				if tgt != null and is_instance_valid(tgt) and not (tgt is Node):
					stack.append([tgt, "%s!%s->%s" % [np, sg["name"], cb2.get_method() if cb2.is_standard() else "lambda"]])
				for ba2: Variant in cb2.get_bound_arguments():
					stack.append([ba2, "%s!%s(bound)" % [np, sg["name"]]])
	return {"total": seen.size(), "by_class": by_class, "by_path": by_path, "ids": ids}


## Every script's static variables under `dir` (read from the source:
## `static var <name>`), as {"Script.name": value}: the caches a class keeps.
static func all_statics(dir := "res://scripts") -> Dictionary:
	var out := {}
	var stack: Array[String] = [dir]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		var da := DirAccess.open(d)
		if da == null:
			continue
		for sub in da.get_directories():
			stack.append(d.path_join(sub))
		for f in da.get_files():
			if not f.ends_with(".gd"):
				continue
			var path := d.path_join(f)
			var src := FileAccess.get_file_as_string(path)
			if not src.contains("static var "):
				continue
			var sc := load(path) as GDScript
			if sc == null:
				continue
			for line in src.split("\n"):
				if line.begins_with("static var "):
					var nm := line.substr(11).get_slice(":", 0).get_slice(" ", 0).get_slice("=", 0).strip_edges()
					var v: Variant = sc.get(nm)
					if typeof(v) in [TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY]:
						out["%s.%s" % [path.get_file().get_basename(), nm]] = v
	return out


## Sizes of every static container (entries), for the record.
static func static_sizes(statics: Dictionary) -> Dictionary:
	var out := {}
	for k: String in statics:
		var v: Variant = statics[k]
		if typeof(v) in [TYPE_ARRAY, TYPE_DICTIONARY]:
			out[k] = v.size()
	return out


## Signal connections by emitter pattern, signal and target: {key: n}.
static func connections(tree: SceneTree) -> Dictionary:
	var out := {}
	var stack: Array[Node] = [tree.root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children(true):
			stack.append(c)
		for sg: Dictionary in n.get_signal_list():
			for conn: Dictionary in n.get_signal_connection_list(sg["name"]):
				var cb: Callable = conn["callable"]
				var tgt: Object = cb.get_object()
				var k := "%s!%s -> %s.%s" % [_fold(str(n.get_path())), sg["name"], _cls(tgt) if tgt != null and is_instance_valid(tgt) else "?",
					cb.get_method() if cb.is_standard() else "<lambda>"]
				out[k] = int(out.get(k, 0)) + 1
	return out


## The dynamic fonts' glyph caches: {"bytes": texture image bytes, "glyphs":
## cached glyphs, "pages": textures, "sizes": {size: pages}, "rids": fonts}
## over the TextServer fonts behind `fonts` (Font.get_rids(): a
## FontVariation's own linked variation and its base; each counted once).
static func font_caches(fonts: Array) -> Dictionary:
	var ts := TextServerManager.get_primary_interface()
	var rids := {}
	for f: Variant in fonts:
		if f is Font:
			for r: RID in (f as Font).get_rids():
				rids[r.get_id()] = r
	var out := {"bytes": 0, "glyphs": 0, "pages": 0, "sizes": {}, "rids": rids.size()}
	for id in rids:
		var r: RID = rids[id]
		for sz: Vector2i in ts.font_get_size_cache_list(r):
			out["glyphs"] += ts.font_get_glyph_list(r, sz).size()
			var nt := ts.font_get_texture_count(r, sz)
			out["pages"] += nt
			out["sizes"]["%d/%d" % [sz.x, id % 1000]] = nt
			for ti in nt:
				var img := ts.font_get_texture_image(r, sz, ti)
				if img != null:
					out["bytes"] += img.get_data_size()
	return out


static func diff(a: Dictionary, b: Dictionary, min_abs := 1) -> Array:
	var d := []
	for k in b:
		var dv := int(b[k]) - int(a.get(k, 0))
		if absi(dv) >= min_abs:
			d.append([dv, k])
	for k in a:
		if not b.has(k) and int(a[k]) >= min_abs:
			d.append([-int(a[k]), k])
	d.sort_custom(func(x: Array, y: Array) -> bool: return absi(x[0]) > absi(y[0]))
	return d


## Persistent memory steps: static memory once a frame (at the start of the
## idle frame); a step is a rise of the recent floor (the least over the
## last second) over the floor of the two seconds before it by more than
## `threshold`. Logged with the context of the frame the rise began in
## (the frame's events, the game's state, the audio director's players).
class MemTrace:
	extends Node
	var threshold := 1048576
	var context: Callable
	## Called when a step is found (costly facts: the font caches).
	var detail: Callable
	var frame := 0
	var mem: PackedInt64Array = []
	var ctx: Array = []
	var events_now: Array[String] = []
	var steps: Array = []
	var _quiet_until := 0
	const WIN := 216
	const RECENT := 72

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = -1000

	func _ready() -> void:
		for sg: Dictionary in Events.get_signal_list():
			var nm: String = sg["name"]
			if nm in ["player_flapped"]:
				continue
			var na: int = sg["args"].size()
			Events.connect(nm, _on_event.bind(nm).unbind(na) if na > 0 else _on_event.bind(nm))

	func _on_event(nm: String) -> void:
		if events_now.size() < 12:
			events_now.append(nm)

	func _exit_tree() -> void:
		for sg: Dictionary in Events.get_signal_list():
			for conn: Dictionary in Events.get_signal_connection_list(sg["name"]):
				if (conn["callable"] as Callable).get_object() == self:
					Events.disconnect(sg["name"], conn["callable"])

	func _process(_dt: float) -> void:
		frame += 1
		mem.append(OS.get_static_memory_usage())
		var c: Variant = context.call() if context.is_valid() else {}
		ctx.append({"frame": frame, "events": events_now.duplicate(), "ctx": c})
		events_now.clear()
		if mem.size() > WIN:
			mem = mem.slice(mem.size() - WIN)
			ctx = ctx.slice(ctx.size() - WIN)
		if mem.size() < WIN or frame < _quiet_until:
			return
		var lo_before := mem[0]
		for i in WIN - RECENT:
			lo_before = mini(lo_before, mem[i])
		var lo_recent := mem[WIN - RECENT]
		for i in range(WIN - RECENT, WIN):
			lo_recent = mini(lo_recent, mem[i])
		if lo_recent - lo_before < threshold:
			return
		# The frame the rise began: the first frame whose memory stays over
		# the floor before by half the step from then on.
		var half := lo_before + (lo_recent - lo_before) / 2
		var start := WIN - 1
		for i in range(WIN - 1, -1, -1):
			if mem[i] < half:
				break
			start = i
		var rec := {"frame": ctx[start]["frame"], "mb": snappedf((lo_recent - lo_before) / 1048576.0, 0.001),
			"at": ctx[start], "before": ctx[maxi(start - 1, 0)], "jump_mb": snappedf((mem[start] - mem[maxi(start - 1, 0)]) / 1048576.0, 0.001),
			"detail": detail.call() if detail.is_valid() else {}}
		steps.append(rec)
		print("[integration] memtrace step: +%.3f MB from frame %d (that frame +%.3f MB): %s; the frame before: %s; now %s" % [
			rec["mb"], rec["frame"], rec["jump_mb"], rec["at"], rec["before"], rec["detail"]])
		_quiet_until = frame + WIN


static func install_memtrace(host: Node, threshold_mb: float, context: Callable) -> MemTrace:
	var t := MemTrace.new()
	t.name = "MemTrace"
	t.threshold = int(threshold_mb * 1048576.0)
	t.context = context
	host.add_child(t)
	return t
