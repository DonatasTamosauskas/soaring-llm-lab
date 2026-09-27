extends Node
## Dev-only: synthesizes every procedural clip without the cache and prints
## what each costs, then how long a warm launch takes to read them all back
## from the cache (first-launch evidence for docs/areas/AUDIO.md).
##   tools/gd.sh audio --headless res://scenes/dev/audio_synth_timing.tscn


func _ready() -> void:
	var bank := AudioBank.new()
	bank.use_cache = false
	bank.build_sync()
	var total := 0.0
	var keys: Array = bank.build_ms.keys()
	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return bank.build_ms[a] > bank.build_ms[b])
	for k in keys:
		total += float(bank.build_ms[k])
		var st := bank.get_stream(k)
		print("[audio] synth %-16s %7.1f ms  %5.2f s" % [k, bank.build_ms[k], st.get_length()])
	print("[audio] synth total %.0f ms of work over %d clips, %.0f ms of wall time on the pool's %d threads (a game launch uses %d)" % [
		total, keys.size(), bank.synth_ms_total, OS.get_processor_count(), AudioBank.SYNTH_THREADS])
	# A game launch: in the background on SYNTH_THREADS threads.
	var bg := AudioBank.new()
	bg.use_cache = false
	bg.start_async()
	while not bg.is_ready():
		await get_tree().process_frame
	bg.poll()
	print("[audio] synth in the background (a first launch): %.0f ms of wall time" % bg.synth_ms_total)
	var warm := AudioBank.new()
	warm.build_sync()
	print("[audio] warm launch: %d clips read from the cache in %.1f ms (%.1f ms for the whole job pass)" % [
		warm.cached, warm.cache_load_ms, warm.synth_ms_total])
	get_tree().quit()
