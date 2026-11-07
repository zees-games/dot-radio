class_name DotRadioHud
extends PanelContainer

## A listener HUD for a DotRadioClient: tune button, "artist - title", a position bar, a volume slider and a mute toggle. Built in code, no scene, no theme assumptions; place it yourself. Bind with [method bind].

var client: DotRadioClient

var tune_button := Button.new()
var title_label := Label.new()
var next_label := Label.new()
var progress := ProgressBar.new()
var volume_slider := HSlider.new()
var mute_button := CheckButton.new()

var _syncing := false


func _init() -> void:
	var box := VBoxContainer.new()
	add_child(box)
	var top := HBoxContainer.new()
	box.add_child(top)
	tune_button.toggle_mode = true
	tune_button.text = "Radio"
	top.add_child(tune_button)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top.add_child(title_label)
	progress.show_percentage = false
	progress.custom_minimum_size.y = 6
	box.add_child(progress)
	next_label.modulate = Color(1, 1, 1, 0.6)
	box.add_child(next_label)
	var bottom := HBoxContainer.new()
	box.add_child(bottom)
	volume_slider.min_value = 0.0
	volume_slider.max_value = 1.0
	volume_slider.step = 0.01
	volume_slider.custom_minimum_size.x = 120
	volume_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(volume_slider)
	mute_button.text = "Mute"
	bottom.add_child(mute_button)
	tune_button.toggled.connect(_on_tune_toggled)
	volume_slider.value_changed.connect(_on_volume_changed)
	mute_button.toggled.connect(_on_mute_toggled)
	set_process(false)


## Attaches to [param c] (once; rebinding drops the old client's connections) and shows its state.
func bind(c: DotRadioClient) -> void:
	if client != null:
		client.tuned_changed.disconnect(_on_client_changed)
		client.now_updated.disconnect(_on_client_changed)
	client = c
	if client != null:
		client.tuned_changed.connect(_on_client_changed)
		client.now_updated.connect(_on_client_changed)
	set_process(client != null)
	refresh()


func _process(_delta: float) -> void:
	_update_progress()
	# Volume and mute change from the keyboard actions too, which emit no signal.
	if client != null and (not is_equal_approx(volume_slider.value, client.volume) or mute_button.button_pressed != client.muted):
		_syncing = true
		volume_slider.value = client.volume
		mute_button.button_pressed = client.muted
		_syncing = false


## "Artist - Title", just the title when there is no artist, "Nothing playing" for an idle station.
static func format_now(now: Dictionary) -> String:
	if str(now.get("id", "")).is_empty():
		return "Nothing playing"
	var title := str(now.get("title", now.get("id", "")))
	var artist := str(now.get("artist", ""))
	return title if artist.is_empty() else "%s - %s" % [artist, title]


## "m:ss" for a non-negative number of seconds.
static func format_time(sec: float) -> String:
	var s := maxi(0, int(sec))
	return "%d:%02d" % [s / 60, s % 60]


## Re-reads the client into the widgets without feeding the change back to it.
func refresh() -> void:
	if client == null:
		return
	_syncing = true
	tune_button.button_pressed = client.tuned
	volume_slider.value = client.volume
	mute_button.button_pressed = client.muted
	_syncing = false
	var now := client.now_playing()
	title_label.text = format_now(now)
	var nxt: Variant = now.get("next", {})
	next_label.text = ("Next: " + format_now(nxt)) if nxt is Dictionary and not (nxt as Dictionary).is_empty() else ""
	next_label.visible = not next_label.text.is_empty()
	_update_progress()


func _update_progress() -> void:
	var now := client.now_playing() if client != null else {}
	var dur := float(now.get("duration", 0.0))
	progress.max_value = maxf(dur, 0.001)
	progress.value = clampf(client.expected_position(), 0.0, dur) if dur > 0.0 and client != null else 0.0
	tooltip_text = "%s / %s" % [format_time(progress.value), format_time(dur)] if dur > 0.0 else ""


func _on_client_changed(_arg: Variant = null) -> void:
	refresh()


func _on_tune_toggled(on: bool) -> void:
	if _syncing or client == null:
		return
	if on:
		client.tune_in()
	else:
		client.tune_out()


func _on_volume_changed(v: float) -> void:
	if not _syncing and client != null:
		client.volume = v


func _on_mute_toggled(on: bool) -> void:
	if not _syncing and client != null:
		client.muted = on
