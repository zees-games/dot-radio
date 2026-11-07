class_name RadioScheduleMessage
extends DotNetMessage

## The host-side wrapper for [DotRadioReplicator]: one reliable server-to-client dot-net message whose body is the replicator's payload. dot-radio itself has no dot-net dependency, so this lives with the host (here, as the reference one); copy it into a game.

const TYPE := &"radio.schedule"

var payload := PackedByteArray()


func _type_name() -> StringName:
	return TYPE


func _write(writer: DotNetWriter) -> void:
	writer.write_bytes(payload)


func _read(reader: DotNetReader) -> void:
	payload = reader.read_bytes(DotRadioReplicator.MAX_BYTES)


func _validate() -> DotResult:
	if payload.is_empty() or payload.size() > DotRadioReplicator.MAX_BYTES:
		return DotResult.fail(DotError.CODE_INVALID, "radio schedule payload has a bad size", str(payload.size()))
	return DotResult.success(true)


static func make(bytes: PackedByteArray) -> RadioScheduleMessage:
	var m := RadioScheduleMessage.new()
	m.payload = bytes
	return m
