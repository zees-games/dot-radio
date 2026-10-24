class_name DotRadioSinkNull
extends DotRadioSink

## A sink that plays nothing and keeps time from [member clock], so the client's seek and drift logic runs headless.

var clock: Callable = Callable()
## Added to [method position], to simulate a device that has drifted.
var skew := 0.0
var volume_db := 0.0
var muted := false
## Every play call, {id, from}: what a test asserts on.
var plays: Array[Dictionary] = []
var stream: AudioStream

var _playing := false
var _from := 0.0
var _at := 0.0


func play(p_stream: AudioStream, from_sec: float) -> void:
	stream = p_stream
	_playing = true
	_from = from_sec
	_at = _now()
	plays.append({"from": from_sec, "length": p_stream.get_length() if p_stream != null else 0.0})


func stop() -> void:
	_playing = false


func is_playing() -> bool:
	return _playing


func position() -> float:
	return _from + (_now() - _at) + skew if _playing else 0.0


func set_volume_db(db: float) -> void:
	volume_db = db


func set_muted(m: bool) -> void:
	muted = m


func _now() -> float:
	return float(clock.call()) if clock.is_valid() else Time.get_ticks_msec() / 1000.0
