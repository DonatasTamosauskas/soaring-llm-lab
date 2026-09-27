// The one material every bird shares (scripts/birds/bird_models.gd).
//
// Flat-shaded low poly: vertex colours, per-face normals baked in the mesh.
// Wings, tail, legs and head are animated here from four per-instance
// numbers, so a MultiMesh of 60 birds costs no CPU skinning. The maths is
// BirdPose (scripts/birds/bird_pose.gd) line for line: change both together
// (tests/shots/birds_gpu_check.gd compares their silhouettes and every drawn
// pixel's posed position).
//
// INSTANCE_CUSTOM (written by BirdBatch):
//   x = flap phase 0..1 (0 = top of the upstroke)
//   y = flap amount 0..1 (0 = glide)
//   z = fold (12 bits) + 4096 * perch blend (12 bits)
//   w = edible (8 bits) + 256 * danger (8 bits) + 65536 * seed (8 bits)
// All integers stay below 2^24, so they survive a float exactly.
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_lambert, specular_schlick_ggx;

// Highlight hues (BirdModels.HIGHLIGHT_EDIBLE / HIGHLIGHT_DANGER), sRGB.
// Chosen by measurement (tests/shots/birds_highlight.gd): saturated,
// mid-dark, and far (Oklab) from every colour of the world's palette, so a
// tinted bird stands out against sky, grass, forest, water and red roofs
// alike. For colour-blind eyes they also differ in lightness (and pulse
// rate): Oklab 0.26 apart for deuteranopes, 0.1 for protanopes.
// Edible #4020f0 deep blue-violet, danger #ff00c8 magenta.
uniform vec3 prey_color : source_color = vec3(0.25098, 0.12549, 0.941176);
uniform vec3 threat_color : source_color = vec3(1.0, 0.0, 0.784314);
// A tiny highlighted bird (its wingspan under its species' readable angle:
// a few pixels, too small for its plumage to be told apart) is drawn mostly
// self-lit in the hue, so its colour is the same saturated, mid-dark tone in
// sun and in shade: highlight_mix of the plumage gives way to the hue at
// highlight_albedo brightness, lit (it keeps the facets), plus
// highlight_glow of it, unlit. As the bird grows past its readable angle
// the tint eases out, gone by tint_end x that angle (about 2-3 deg for every
// species), so from there on a highlighted bird wears its own plumage: shape
// AND colour still say which species it is (docs/DESIGN.md), and the marker
// says edible or danger. The readable angle is the species' own
// (BirdModels.min_highlight_angle), carried in COLOR.a (x READABLE_MAX).
uniform float highlight_mix = 0.9;
uniform float highlight_albedo = 0.25;
uniform float highlight_glow = 1.3;
uniform float tint_end = 1.8;
// Highlight marker (group 6: its own mesh, drawn by one extra MultiMesh per
// world for the highlighted birds only; BirdMeshBuilder.build_marker): a
// ring for edible, a warning triangle for danger - the shape is the
// colour-blind cue - around the bird, facing the viewer, at every distance.
// Radius (radians of view): mark_radius, or mark_bird_scale x the bird's
// drawn wingspan angle once that is bigger (just outside its wingtips); the
// triangle's corners reach mark_tri_scale times further, so its edges pass
// outside the wingtips too. Line width mark_width (about 2 px on a Quest
// Pro), growing with the radius (mark_width_k of it) around a big, near
// bird up to mark_width_max (about 4.6 px): a fine line, never a heavy
// band. The line never thins below mark_width (a line under a pixel wide
// breaks up and shimmers); only the state's own 0.1 s blend thins it.
uniform float mark_radius = 0.0056;
uniform float mark_bird_scale = 0.62;
uniform float mark_tri_scale = 1.65;
uniform float mark_width = 0.00175;
uniform float mark_width_k = 0.025;
uniform float mark_width_max = 0.004;
uniform float pulse_test = -1.0;
uniform float roughness = 0.88;
// 0 freezes perched birds' idle head glances (verification renders).
uniform float head_look_amount = 1.0;

const float DEG = 0.017453292519943295;
const float DOWN_FRAC = 0.42;
const float LAG = 0.08;
const float ELEV_UP = 50.0 * DEG;
const float ELEV_DOWN = 38.0 * DEG;
const float ELEV_C = (ELEV_UP - ELEV_DOWN) * 0.5;
const float ELEV_A = (ELEV_UP + ELEV_DOWN) * 0.5;
const float UP_SWEEP = 12.0 * DEG;
const float UP_RETRACT = 0.3;
const float UP_TWIST = 10.0 * DEG;
const float UP_HAND_SWEEP = 30.0 * DEG;
const float UP_HAND_DROP = 16.0 * DEG;
const float UP_HAND_TWIST = 20.0 * DEG;
const float WHIP = 0.3;
const float DOWN_TWIST = 6.0 * DEG;
const float DOWN_CURL = 10.0 * DEG;
const float FOLD_SWEEP = -84.0 * DEG;
const float FOLD_ELEV_FLY = -55.0 * DEG;
const float FOLD_ELEV_PERCH = -70.0 * DEG;
const float FOLD_DROOP_FLY = 4.0 * DEG;
const float FOLD_RETRACT = 0.72;
const float FOLD_OUT = 0.016;
const float TAIL_FLAP_PITCH = 6.0 * DEG;
const float TAIL_FLAP_SPREAD = 0.12;
const float LEG_TUCK_SCALE = 0.3;
const float HEAD_LOOK = 38.0 * DEG;
const float BOB = 0.014;
// COLOR.a x READABLE_MAX = the species' readable angle (BirdModels).
const float READABLE_MAX = 0.032;
// Sides of the marker's ring (BirdMeshBuilder.MARK_RING_SIDES).
const float MARK_RING_SIDES = 32.0;

// (edible, danger, pulse, tint share for this bird's size in this view)
varying vec4 v_hl;
// 0 = the bird, 1 = the edible ring, 2 = the danger triangle.
varying float v_mark;

float stroke(float p) {
	if (p < DOWN_FRAC) {
		return cos(PI * p / DOWN_FRAC);
	}
	return -cos(PI * (p - DOWN_FRAC) / (1.0 - DOWN_FRAC));
}

float upflex(float p) {
	if (p < DOWN_FRAC) {
		return 0.0;
	}
	return sin(PI * (p - DOWN_FRAC) / (1.0 - DOWN_FRAC));
}

float downpow(float p) {
	if (p < DOWN_FRAC) {
		return sin(PI * p / DOWN_FRAC);
	}
	return 0.0;
}

vec3 rx(vec3 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(v.x, v.y * c - v.z * s, v.y * s + v.z * c);
}

vec3 ry(vec3 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

vec3 rz(vec3 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(v.x * c - v.y * s, v.x * s + v.y * c, v.z);
}

float fpos(float x) {
	return x - floor(x);
}

float head_look(float seed, float t) {
	float u = t * (0.45 + 0.35 * seed) + seed * 31.0;
	float k = floor(u);
	float f = u - k;
	float a0 = fpos(k * 0.6180339887 + seed) * 2.0 - 1.0;
	float a1 = fpos((k + 1.0) * 0.6180339887 + seed) * 2.0 - 1.0;
	return mix(a0, a1, smoothstep(0.0, 0.18, f));
}

void vertex() {
	float phase = INSTANCE_CUSTOM.x;
	float amount = INSTANCE_CUSTOM.y;
	float fp = INSTANCE_CUSTOM.z;
	float perch_q = floor(fp / 4096.0);
	float fold = (fp - perch_q * 4096.0) / 4095.0;
	float perch = perch_q / 4095.0;
	float hp_w = INSTANCE_CUSTOM.w;
	float seed_q = floor(hp_w / 65536.0);
	float rest = hp_w - seed_q * 65536.0;
	float danger_q = floor(rest / 256.0);
	float edible = (rest - danger_q * 256.0) / 255.0;
	float danger = danger_q / 255.0;
	float seed = seed_q / 255.0;

	int group = int(round(CUSTOM0.x));
	float amp = CUSTOM3.x;
	float a_eff = amount * (1.0 - fold) * (1.0 - fold);
	float s = stroke(phase);
	float sl = stroke(fpos(phase - LAG));
	vec3 q = VERTEX;
	vec3 m = NORMAL;
	if (group == 1 || group == 2) {
		float fx = upflex(phase);
		float pw = downpow(phase);
		float retr = CUSTOM3.z;
		float elev = a_eff * amp * (ELEV_C + ELEV_A * s) + fold * mix(FOLD_ELEV_FLY, FOLD_ELEV_PERCH, perch) * CUSTOM3.y;
		float sweep = -a_eff * fx * UP_SWEEP * retr + fold * FOLD_SWEEP * CUSTOM2.w;
		float twist = a_eff * (fx * UP_TWIST - pw * DOWN_TWIST) * retr;
		float span_k = 1.0 - (a_eff * fx * UP_RETRACT + fold * FOLD_RETRACT) * retr;
		bool mirror = CUSTOM0.y < 0.0;
		if (mirror) {
			q.x = -q.x;
			m.x = -m.x;
		}
		vec3 sh = CUSTOM1.xyz;
		q.z -= fold * (2.0 - fold) * CUSTOM0.w;
		vec3 d;
		if (group == 1) {
			d = q - sh;
			d.x *= span_k;
			m = normalize(vec3(m.x / span_k, m.y, m.z));
		} else {
			vec3 wc = CUSTOM2.xyz;
			vec3 dw = wc - sh;
			dw.x *= span_k;
			float hw = CUSTOM0.z;
			float h_elev = hw * (a_eff * amp * (ELEV_A * WHIP * (sl - s) - fx * UP_HAND_DROP) + a_eff * pw * DOWN_CURL) - fold * UV.x;
			float h_sweep = -hw * a_eff * fx * UP_HAND_SWEEP;
			float h_twist = hw * a_eff * fx * UP_HAND_TWIST;
			d = dw + rz(ry(rx(q - wc, h_twist), h_sweep), h_elev);
			m = rz(ry(rx(m, h_twist), h_sweep), h_elev);
		}
		float droop = fold * mix(FOLD_DROOP_FLY, UV.y, perch) * retr;
		float flatten = -fold * CUSTOM1.w;
		q = sh + rx(rz(ry(rx(rz(d, flatten), twist), sweep), elev), droop);
		m = rx(rz(ry(rx(rz(m, flatten), twist), sweep), elev), droop);
		q.x += fold * FOLD_OUT * retr;
		// The fold hug (UV2, baked per wing station): in onto the back and up
		// over the rump, as fold^3.
		float hug = fold * fold * fold;
		q.x -= hug * UV2.x;
		q.y += hug * UV2.y;
		if (mirror) {
			q.x = -q.x;
			m.x = -m.x;
		}
	} else if (group == 3) {
		vec3 t = CUSTOM1.xyz;
		float tc = max(fold, perch);
		float spread = 1.0 + a_eff * TAIL_FLAP_SPREAD - CUSTOM2.w * tc * (2.0 - tc);
		float tp = a_eff * amp * TAIL_FLAP_PITCH * sl + perch * CUSTOM1.w;
		vec3 d = q - t;
		d.x *= spread;
		q = t + rx(d, -tp);
		m = rx(normalize(vec3(m.x / spread, m.y, m.z)), -tp);
	} else if (group == 4) {
		vec3 hip = CUSTOM1.xyz;
		float k = mix(LEG_TUCK_SCALE, 1.0, perch);
		float ang = mix(CUSTOM1.w, -CUSTOM3.w, perch);
		q = hip + rx((q - hip) * k, ang);
		m = rx(m, ang);
	} else if (group == 5) {
		vec3 nk = CUSTOM1.xyz;
		float look = perch * HEAD_LOOK * head_look(seed, TIME) * head_look_amount;
		float hp = -perch * CUSTOM3.w;
		q = nk + rx(ry(q - nk, look), hp);
		m = rx(ry(m, look), hp);
	}
	float bp = perch * CUSTOM3.w;
	q = rx(q, bp);
	m = rx(m, bp);
	q.y -= BOB * a_eff * amp * sl;
	v_mark = 0.0;
	if (group == 6) {
		// The highlight marker: around the bird, facing the viewer (the view's
		// camera; in stereo the centre between the eyes, so both eyes see one
		// flat marker), a fixed angular size (world size = distance x angle),
		// in model space (the instance transform is a rotation and a uniform
		// scale, so its inverse is its transpose over the scale squared).
		mat3 mb = mat3(MODEL_MATRIX);
		float s2 = max(dot(mb[0], mb[0]), 1e-12);
		float dist = max(distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD), 0.001);
		float ang_bird = sqrt(s2) / dist;
		bool tri = CUSTOM1.z > 0.5;
		float wgt = tri ? danger : edible;
		float r_out = max(mark_radius, mark_bird_scale * ang_bird) * (tri ? mark_tri_scale : 1.0);
		float w = clamp(mark_width_k * r_out, mark_width, mark_width_max);
		// A ring's corners come in by the width over cos(pi / sides), a
		// triangle's by twice the width, so the line is w across everywhere;
		// the state's weight (it blends over 0.1 s) thins it in and out.
		float r_in = r_out - w * wgt * (tri ? 2.0 : 1.0 / cos(PI / MARK_RING_SIDES));
		float r = (CUSTOM1.w > 0.5 ? r_out : r_in) * dist;
		vec3 wdir = (INV_VIEW_MATRIX[0].xyz * CUSTOM1.x + INV_VIEW_MATRIX[1].xyz * CUSTOM1.y) * r;
		q = (transpose(mb) * wdir) / s2;
		m = transpose(mb) * INV_VIEW_MATRIX[2].xyz;
		if (IN_SHADOW_PASS || wgt <= 0.0) {
			// Casts no shadow; the other state's shape: nothing at all.
			q = vec3(0.0);
		}
		v_mark = tri ? 2.0 : 1.0;
	}
	VERTEX = q;
	NORMAL = normalize(m);
	// Edible pulses slowly, danger quickly: readable even without colour.
	float wave_e = sin(TIME * 7.0 + seed * 6.283);
	float wave_d = sin(TIME * 13.0 + seed * 6.283);
	if (pulse_test >= 0.0) {
		wave_e = pulse_test * 2.0 - 1.0;
		wave_d = wave_e;
	}
	float pulse = danger > edible ? 0.72 + 0.28 * wave_d : 0.8 + 0.2 * wave_e;
	// How big this bird is drawn in this view (its instance transform holds
	// the owner's scale), against its species' readable angle: fully tinted
	// below it, its own plumage from tint_end x it.
	float ang = length(MODEL_MATRIX[0].xyz) / max(distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD), 0.001);
	float readable = max(COLOR.a * READABLE_MAX, 1e-4);
	float tint = 1.0 - smoothstep(readable, readable * tint_end, ang);
	v_hl = vec4(edible, danger, pulse, tint);
}

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	float hl = max(v_hl.x, v_hl.y);
	vec3 hue = (prey_color * v_hl.x + threat_color * v_hl.y) / max(v_hl.x + v_hl.y, 1e-4);
	if (v_mark > 0.5) {
		// The marker: its own state's hue, as a tiny tinted bird looks.
		vec3 mh = v_mark > 1.5 ? threat_color : prey_color;
		ALBEDO = mh * highlight_albedo;
		EMISSION = mh * v_hl.z * highlight_glow;
	} else {
		// Vertex colours are sRGB bytes (see BirdMeshBuilder._tri). A tiny
		// highlighted bird is the hue, lit and glowing; a readable one is
		// exactly its own plumage (the marker carries its state: a glow or
		// rim on flat faces would recolour whole facets and blur species
		// together).
		vec3 plum = srgb_to_linear(COLOR.rgb);
		float k = hl * v_hl.w;
		ALBEDO = mix(plum, hue * highlight_albedo, k * highlight_mix);
		EMISSION = hue * (k * v_hl.z * highlight_glow);
	}
	ROUGHNESS = roughness;
	SPECULAR = 0.25;
}
