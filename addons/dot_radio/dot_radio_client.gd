class_name DotRadioClient
extends Node

## The listener: follows the station's schedule, downloads each track once, and plays it seeked to where the station is.
##
## It never starts by itself. [method tune_in] is the one way in and must be reached from a user gesture (an input event,
## which [method handle_input] provides), because a browser keeps its audio locked until then.
## The schedule comes from polling [member base_url] or from the host calling [method apply_now] with its own transport.

signal tuned_changed(on: bool)
signal track_started(track: Dictionary)
signal track_stopped
signal now_updated(now: Dictionary)
signal failed(message: String)

const CHANNEL := "radio"

## The station's mount, e.g. "http://host:8791" or "http://host:8790/radio"; empty means the host feeds [method apply_now] and tracks come from [member fetcher].
var base_url := ""
## Anything with the [DotRadioSink] methods.
var sink: Variant = DotRadioSink.new():
	set(v):
		sink = v
		_apply_volume()
## Callable(url) -> DotResult of bytes, awaitable; replaces the built-in [DotHttp] (tests, a game's own downloader).
var fetcher: Callable = Callable()
var cache_dir := "user://radio_cache"
var max_cache_bytes := 128 * 1024 * 1024
var poll_interval_sec := 5.0
## Playback further than this from the schedule is re-seeked.
var drift_threshold_sec := 0.6
## Fetch the next track when this little of the current one is left.
var prefetch_sec := 30.0
var retry_sec := 5.0
var step := 0.05
## Rebindable: the names of InputMap actions. [method ensure_actions] adds a default key for each that is missing.
var action_toggle := "radio_toggle"
var action_volume_up := "radio_volume_up"
var action_volume_down := "radio_volume_down"
var action_mute := "radio_mute"
var bind_input := true
## Callable() -> seconds on a steady clock; replaceable for tests.
var clock: Callable = Callable()

var tuned := false
var resyncs := 0
var volume := 0.7:
	set(v):
		volume = clampf(v, 0.0, 1.0)
		_apply_volume()
var muted := false:
	set(v):
		muted = v
		_apply_volume()

var _http: DotHttp
var _now: Dictionary = {}
var _anchor_t := 0.0
var _anchor_pos := 0.0
var _playing_id := ""
var _ready_id := ""
var _stream: AudioStream
var _streams: Dictionary = {}
var _loading := ""
var _polling := false
var _last_poll := -1000.0
var _retry_at := 0.0
var _prefetching := ""


func _ready() -> void:
	if bind_input:
		ensure_actions()
	_apply_volume()


func _process(_delta: float) -> void:
	tick()


func _unhandled_input(event: InputEvent) -> void:
	if bind_input and handle_input(event):
		get_viewport().set_input_as_handled()


## Adds a default key to each radio action the project has not defined; a rebind in the project or the settings screen wins.
func ensure_actions() -> void:
	var defaults := {action_toggle: KEY_F8, action_mute: KEY_F9, action_volume_up: KEY_PAGEUP, action_volume_down: KEY_PAGEDOWN}
	for action in defaults:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = defaults[action]
		InputMap.action_add_event(action, ev)


## Acts on the radio actions; true when the event was one of them.
func handle_input(event: InputEvent) -> bool:
	if _pressed(event, action_toggle):
		if tuned:
			tune_out()
		else:
			tune_in()
		return true
	if _pressed(event, action_mute):
		muted = not muted
		return true
	if _pressed(event, action_volume_up, true):
		volume += step
		return true
	if _pressed(event, action_volume_down, true):
		volume -= step
		return true
	return false


## Starts listening. Call it from a user gesture.
func tune_in() -> void:
	if tuned:
		return
	tuned = true
	_apply_volume()
	tuned_changed.emit(true)
	if not base_url.is_empty():
		# What was known before tuning out is stale; wait for the station's answer.
		_now = {}
		_poll()


func tune_out() -> void:
	if not tuned:
		return
	tuned = false
	_halt()
	tuned_changed.emit(false)


## Takes a schedule from the host's own transport (or [method _poll]). [param latency] is the one-way delay to add to its position.
func apply_now(now: Dictionary, latency: float = 0.0) -> void:
	var was := str(_now.get("id", ""))
	_now = now
	_anchor_t = _clock()
	_anchor_pos = float(now.get("position", 0.0)) + (latency if not str(now.get("id", "")).is_empty() else 0.0)
	if _playing_id != "" and str(now.get("id", "")) != _playing_id:
		_halt_sink()
	if str(now.get("id", "")) != was:
		_retry_at = 0.0
	now_updated.emit(now)


## Seconds into the current track the station is at now; negative before it starts.
func expected_position() -> float:
	return _anchor_pos + (_clock() - _anchor_t)


func now_playing() -> Dictionary:
	return _now


func is_playing() -> bool:
	return not _playing_id.is_empty() and sink.is_playing()


## Drives playback; [method _process] calls it, a test calls it by hand.
func tick() -> void:
	if not tuned:
		return
	var t := _clock()
	var id := str(_now.get("id", ""))
	var over := not id.is_empty() and expected_position() >= float(_now.get("duration", 0.0))
	var due := poll_interval_sec if not over else 1.0
	if not base_url.is_empty() and not _polling and t - _last_poll >= due:
		_poll()
	if id.is_empty():
		return
	var pos := expected_position()
	if over:
		if _playing_id != "":
			_halt_sink()
		return
	_prefetch_next(pos)
	if _playing_id == id and pos < 0.0:
		_halt_sink()
	elif _playing_id == id:
		var drift: float = sink.position() - pos
		if not sink.is_playing() or absf(drift) > drift_threshold_sec:
			resyncs += 1
			DotLog.debug(CHANNEL, "re-seeking", {"drift": drift})
			sink.play(_stream, pos)
	else:
		if _ready_id != id and _loading.is_empty() and t >= _retry_at:
			_load_current()
		# A cached track is ready at once; a downloaded one on a later tick.
		if _ready_id == id and pos >= 0.0:
			sink.play(_stream, pos)
			_playing_id = id
			track_started.emit(_now)


func volume_up() -> void:
	volume += step


func volume_down() -> void:
	volume -= step


func describe() -> Dictionary:
	return {"tuned": tuned, "playing": _playing_id, "volume": volume, "muted": muted, "position": expected_position() if not _now.is_empty() else 0.0,
		"resyncs": resyncs, "cached": _streams.keys()}


static func _pressed(event: InputEvent, action: String, echo: bool = false) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action, echo)


func _clock() -> float:
	return float(clock.call()) if clock.is_valid() else Time.get_ticks_msec() / 1000.0


func _apply_volume() -> void:
	if sink == null:
		return
	sink.set_volume_db(linear_to_db(maxf(volume, 0.0001)))
	sink.set_muted(muted)


func _halt_sink() -> void:
	sink.stop()
	_playing_id = ""
	track_stopped.emit()


func _halt() -> void:
	_halt_sink()
	_ready_id = ""
	_stream = null


func _fetch(url: String) -> DotResult:
	if fetcher.is_valid():
		return await fetcher.call(url)
	if _http == null:
		_http = DotHttp.new()
		add_child(_http)
	return await _http.get_bytes(url)


func _poll() -> void:
	_polling = true
	_last_poll = _clock()
	var t0 := _clock()
	var res := await _fetch(base_url.rstrip("/") + "/now")
	_polling = false
	if not tuned:
		return
	var parsed: Variant = JSON.parse_string((res.value as PackedByteArray).get_string_from_utf8()) if res.ok else null
	if parsed is Dictionary:
		apply_now(parsed, (_clock() - t0) / 2.0)
	else:
		_fail("the station did not answer: %s" % ("not a schedule" if res.ok else res.error.message))


func _fail(message: String) -> void:
	_retry_at = _clock() + retry_sec
	DotLog.warn(CHANNEL, message)
	failed.emit(message)


func _load_current() -> void:
	var track := _now.duplicate()
	var id := str(track["id"])
	_loading = id
	var res := await _stream_for(track)
	_loading = ""
	if not tuned:
		return
	if not res.ok:
		_fail("cannot load '%s': %s" % [id, res.error.message])
		return
	_ready_id = id
	_stream = res.value


func _prefetch_next(pos: float) -> void:
	var nxt: Variant = _now.get("next", {})
	if not (nxt is Dictionary) or (nxt as Dictionary).is_empty() or not _prefetching.is_empty():
		return
	var id := str(nxt["id"])
	if _streams.has(id) or float(_now.get("duration", 0.0)) - pos > prefetch_sec or _clock() < _retry_at:
		return
	_prefetching = id
	var res := await _stream_for(nxt)
	_prefetching = ""
	if not res.ok:
		_retry_at = _clock() + retry_sec
		DotLog.debug(CHANNEL, "prefetch failed", {"id": id, "error": res.error.message})


# The decoded stream for a track: from memory, else the disk cache, else downloaded, checked against the station's hash, and cached.
func _stream_for(track: Dictionary) -> DotResult:
	var id := str(track["id"])
	if _streams.has(id):
		return DotResult.success(_streams[id])
	var kind := str(track.get("kind", ""))
	var path := cache_dir.path_join("%s-%s.%s" % [id, str(track.get("sha256", "")).left(12), kind])
	var bytes := PackedByteArray()
	var cached: DotResult = DotPaths.read_bytes(path) if FileAccess.file_exists(path) else null
	if cached != null and cached.ok and (cached.value as PackedByteArray).size() == int(track.get("size", -1)):
		bytes = cached.value
	else:
		var got := await _fetch(base_url.rstrip("/") + "/track/" + id.uri_encode())
		if not got.ok:
			return got
		bytes = got.value
		var want := str(track.get("sha256", ""))
		if not want.is_empty() and DotHash.sha256_bytes(bytes) != want:
			return DotResult.fail(DotError.CODE_INTEGRITY, "the downloaded file does not match the station's hash", id)
		_store(path, bytes)
	var decoded := DotRadioCodec.stream_from_bytes(bytes, kind)
	if decoded.ok:
		_streams[id] = decoded.value
		_trim_streams(id)
	return decoded


func _trim_streams(keep: String) -> void:
	var wanted := [keep, str(_now.get("id", "")), str((_now.get("next", {}) as Dictionary).get("id", ""))]
	for id in _streams.keys():
		if not wanted.has(id) and _streams.size() > 3:
			_streams.erase(id)


func _store(path: String, bytes: PackedByteArray) -> void:
	if DotPaths.ensure_parent_dir(path).ok:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(bytes)
			f.close()
			DotWeb.sync_filesystem()
	_evict(path)


# Oldest files go first; the one just written never does.
func _evict(keep: String) -> void:
	var files: Array[Dictionary] = []
	var total := 0
	for f in DirAccess.get_files_at(cache_dir):
		var p := cache_dir.path_join(f)
		var size := FileAccess.open(p, FileAccess.READ).get_length() if FileAccess.file_exists(p) else 0
		total += size
		files.append({"path": p, "size": size, "mtime": FileAccess.get_modified_time(p)})
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["mtime"] < b["mtime"])
	for e in files:
		if total <= max_cache_bytes:
			break
		if e["path"] != keep:
			DirAccess.remove_absolute(e["path"])
			total -= int(e["size"])
