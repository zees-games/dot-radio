class_name DotRadioSink
extends RefCounted

## What [DotRadioClient] plays through. Any object with these methods works; this is the documented shape and a silent default.

func play(_stream: AudioStream, _from_sec: float) -> void:
	pass


func stop() -> void:
	pass


func is_playing() -> bool:
	return false


## Seconds into the stream that are audible now.
func position() -> float:
	return 0.0


func set_volume_db(_db: float) -> void:
	pass


func set_muted(_muted: bool) -> void:
	pass
