extends RefCounted
## TEST-ONLY settings store with the Settings API (get_value / set_value).
## VR tests persist calibration here, never into the shared
## user://settings.cfg (every sandbox and agent uses the same user dir).
## save_to/load_from round-trip through a ConfigFile exactly like Settings.

var data := {}
var writes := 0


func get_value(key: String, fallback: Variant = null) -> Variant:
	return data.get(key, fallback)


func set_value(key: String, value: Variant) -> void:
	data[key] = value
	writes += 1


func save_to(path: String) -> Error:
	var cfg := ConfigFile.new()
	for k in data:
		cfg.set_value("settings", k, data[k])
	return cfg.save(path)


func load_from(path: String) -> Error:
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if err != OK:
		return err
	data.clear()
	for k in cfg.get_section_keys("settings"):
		data[k] = cfg.get_value("settings", k)
	return OK
