class_name DotRadioSinkGodot
extends DotRadioSink

## Plays through one AudioStreamPlayer on [member bus]; [method attach] puts it in the tree.

var bus := "Master"
var player := AudioStreamPlayer.new()

var _db := 0.0
var _muted := false


## Adds the player under [param parent]; call once.
func attach(parent: Node) -> void:
	player.bus = bus
	parent.add_child(player)


func play(stream: AudioStream, from_sec: float) -> void:
	player.stream = stream
	player.play(maxf(from_sec, 0.0))


func stop() -> void:
	player.stop()


func is_playing() -> bool:
	return player.playing


func position() -> float:
	if not player.playing:
		return 0.0
	return player.get_playback_position() + AudioServer.get_time_since_last_mix()


func set_volume_db(db: float) -> void:
	_db = db
	_apply()


func set_muted(muted: bool) -> void:
	_muted = muted
	_apply()


func _apply() -> void:
	player.volume_db = -80.0 if _muted else _db
