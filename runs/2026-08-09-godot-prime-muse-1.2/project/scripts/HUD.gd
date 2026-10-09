extends CanvasLayer

var size_label: Label
var score_label: Label
var speed_label: Label
var state_label: Label
var hint_label: Label
var crosshair: Control

func _ready():
    if not has_node("Panel"):
        _build_ui()
    else:
        # if scene already has UI, fetch lazily
        var panel = get_node_or_null("Panel")
        var vbox = panel.get_node_or_null("VBox") if panel else null
        size_label = get_node_or_null("Panel/VBox/SizeLabel")
        if size_label == null and vbox:
            size_label = vbox.get_node_or_null("SizeLabel")
        score_label = get_node_or_null("Panel/VBox/ScoreLabel")
        speed_label = get_node_or_null("Panel/VBox/SpeedLabel")
        state_label = get_node_or_null("Panel/VBox/StateLabel")
        hint_label = get_node_or_null("Panel/VBox/HintLabel")
        crosshair = get_node_or_null("Crosshair")
        if size_label == null:
            # fallback rebuild
            for c in get_children(): c.queue_free()
            _build_ui()

func _build_ui():
    var panel = Panel.new()
    panel.name = "Panel"
    panel.custom_minimum_size = Vector2(420, 150)
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 18
    panel.offset_top = 18
    panel.offset_right = 438
    panel.offset_bottom = 168
    var style = StyleBoxFlat.new()
    style.bg_color = Color(0,0,0,0.42)
    style.corner_radius_top_left = 12
    style.corner_radius_top_right = 12
    style.corner_radius_bottom_left = 12
    style.corner_radius_bottom_right = 12
    panel.add_theme_stylebox_override("panel", style)
    add_child(panel)
    var vbox = VBoxContainer.new()
    vbox.name = "VBox"
    vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    vbox.offset_left = 12
    vbox.offset_top = 10
    vbox.offset_right = -12
    vbox.offset_bottom = -10
    panel.add_child(vbox)
    var labels = {}
    for n in ["SizeLabel","ScoreLabel","SpeedLabel","StateLabel","HintLabel"]:
        var lbl = Label.new()
        lbl.name = n
        lbl.add_theme_font_size_override("font_size", 18 if n!="HintLabel" else 13)
        lbl.add_theme_color_override("font_color", Color.WHITE if n!="HintLabel" else Color(0.88,0.92,1,1))
        vbox.add_child(lbl)
        labels[n] = lbl
    size_label = labels["SizeLabel"]
    score_label = labels["ScoreLabel"]
    speed_label = labels["SpeedLabel"]
    state_label = labels["StateLabel"]
    hint_label = labels["HintLabel"]

    var ch = Control.new()
    ch.name = "Crosshair"
    ch.set_anchors_preset(Control.PRESET_CENTER)
    ch.custom_minimum_size = Vector2(18,18)
    ch.offset_left = -9
    ch.offset_top = -9
    add_child(ch)
    crosshair = ch

func update_hud(p_size: float, eaten: int, speed: float, perched: bool, flaps: int):
    if size_label == null or not is_instance_valid(size_label):
        return
    # sanitize
    if not is_finite(p_size):
        p_size = 1.0
    if not is_finite(speed):
        speed = 0.0
    p_size = clamp(p_size, 0.5, 3.2)
    eaten = clamp(eaten, 0, 9999)
    flaps = clamp(flaps, 0, 999999)
    size_label.text = "SIZE  %.2f  ×" % p_size
    size_label.modulate = Color(0.62,1,0.62) if p_size>1.35 else Color(1,1,1) if p_size>0.92 else Color(1,0.9,0.42)
    score_label.text = "CAUGHT  %d   FLAPS %d" % [eaten, flaps]
    speed_label.text = "AIRSPEED  %.1f m/s" % speed
    speed_label.modulate = Color(0.42,0.82,1) if speed < 18 else Color(1,0.72,0.22) if speed < 24 else Color(1,0.32,0.22)
    state_label.text = "● PERCHED — flap to take off" if perched else ("▲ STALL!" if speed < 5.8 else "◇ GLIDING" if speed < 11 else "✈ SOARING")
    state_label.modulate = Color(0.88,0.62,1) if perched else Color(1,0.42,0.42) if speed < 5.8 else Color(1,1,1)
    hint_label.text = "(Q/E bank • W dive / S climb • SPACE flap • ESC unlock mouse)   — catch smaller, avoid larger"

func is_finite(v: float) -> bool:
    return not is_nan(v) and not is_inf(v)
