class_name WorldSky
extends RefCounted
## Sky, sun, fog and clouds. Quest-safe: procedural sky, depth-less
## exponential fog with a little aerial perspective, one directional shadow
## with one orthogonal split, no glow/SSAO/SSR/volumetrics.


static func make_environment(preset: StringName) -> Environment:
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	# The radiance map only feeds ambient light here; keep it tiny and static.
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.glow_enabled = false
	env.ssao_enabled = false
	env.ssr_enabled = false
	env.sdfgi_enabled = false
	env.volumetric_fog_enabled = false
	apply_environment(env, preset)
	return env


static func apply_environment(env: Environment, preset: StringName) -> void:
	var L: Dictionary = Palette.LIGHT.get(preset, Palette.LIGHT[&"day"])
	var sm := env.sky.sky_material as ProceduralSkyMaterial
	sm.sky_top_color = L["sky_top"]
	sm.sky_horizon_color = L["sky_horizon"]
	sm.sky_curve = 0.12
	sm.ground_horizon_color = L["ground_horizon"]
	sm.ground_bottom_color = L["ground_bottom"]
	sm.ground_curve = 0.05
	sm.sky_energy_multiplier = L["sky_energy"]
	sm.sun_angle_max = 18.0
	sm.sun_curve = 0.08
	sm.use_debanding = true
	env.ambient_light_color = L["ambient"]
	env.ambient_light_sky_contribution = 0.55
	env.ambient_light_energy = L["ambient_energy"]
	env.fog_light_color = L["fog"]
	env.fog_light_energy = 1.0
	env.fog_density = L["fog_density"]
	env.fog_sky_affect = L["fog_sky_affect"]
	env.fog_aerial_perspective = 0.25
	env.fog_sun_scatter = 0.12


static func make_sun(preset: StringName) -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	# One orthogonal split: casters are drawn once (Quest budget).
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	# Shadows matter near the bird (branches, eaves); 90 m keeps the shadow
	# pass small on Quest.
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_blend_splits = false
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.directional_shadow_pancake_size = 30.0
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	apply_sun(sun, preset)
	return sun


static func sun_direction(preset: StringName) -> Vector3:
	## Unit vector pointing FROM the ground TOWARD the sun.
	var L: Dictionary = Palette.LIGHT.get(preset, Palette.LIGHT[&"day"])
	var el := deg_to_rad(L["sun_elev"])
	var az := deg_to_rad(L["sun_azim"])
	return Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az)).normalized()


static func apply_sun(sun: DirectionalLight3D, preset: StringName) -> void:
	var L: Dictionary = Palette.LIGHT.get(preset, Palette.LIGHT[&"day"])
	sun.light_color = L["sun"]
	sun.light_energy = L["sun_energy"]
	var to_sun := sun_direction(preset)
	# A DirectionalLight3D shines along its -Z.
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.FORWARD)


## Low-poly cumulus above the ceiling (unreachable, no collision), one mesh.
static func build_clouds(parent: Node3D, seed: int, preset: StringName) -> MeshInstance3D:
	var L: Dictionary = Palette.LIGHT.get(preset, Palette.LIGHT[&"day"])
	var kit := MeshKit.new("clouds", seed)
	kit.collide = false
	kit.jitter = 0.03
	var rng := RandomNumberGenerator.new()
	rng.seed = seed * 31337 + 5
	var count := 30
	for i in count:
		var ang := rng.randf() * TAU
		var r := sqrt(rng.randf()) * 1150.0 + 80.0
		var c := Vector3(cos(ang) * r, rng.randf_range(345.0, 430.0), sin(ang) * r)
		# Beyond the ring clouds may sit lower (they peek over the peaks).
		if r > 800.0:
			c.y = rng.randf_range(300.0, 390.0)
		var size := rng.randf_range(28.0, 60.0)
		var puffs := rng.randi_range(3, 6)
		var dir := Vector3(cos(ang + 1.3), 0.0, sin(ang + 1.3))
		for p in puffs:
			var off := dir * (float(p) - puffs * 0.5) * size * 0.55 + Vector3(rng.randf_range(-0.3, 0.3) * size, 0.0, rng.randf_range(-0.3, 0.3) * size)
			var rad := size * rng.randf_range(0.45, 0.8) * (1.0 - absf(float(p) - puffs * 0.5) / puffs * 0.6)
			kit.blob(c + off + Vector3(0, rad * 0.25, 0), Vector3(rad, rad * 0.55, rad * 0.8), L["cloud"], 0.16, L["cloud_shade"], -0.35)
	var mi := MeshInstance3D.new()
	mi.name = "clouds"
	mi.mesh = kit.to_mesh()
	mi.material_override = Palette.cloud_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta(&"soft", "cloud")
	parent.add_child(mi)
	return mi
