class_name DotRadioReplicator
extends RefCounted

## Pushes the station's schedule to clients over any transport, dot-net included, instead of each client polling `GET /now`. Transport-agnostic on purpose: dot-radio does not depend on dot-net, so the host wraps [method encode]'s bytes in one `DotNetMessage` (TO_CLIENT, RELIABLE) whose body is a byte string, and hands the received bytes to [method DotRadioClient.apply_wire]. Audio still comes over HTTP; only the schedule moves.
##
## Call [method update] from the server's tick. It sends when the station's `rev` changed (track change, queue, playlist, rating) and otherwise every `heartbeat_sec`, so a client that missed one still converges and positions stay anchored.

## Wire format version, first key of every payload.
const VERSION := 1
## Largest payload [method decode] accepts, so a hostile server cannot make a client parse megabytes.
const MAX_BYTES := 4096

var station: DotRadioStation
## Callable(payload: PackedByteArray) -> void, broadcasting to every listener.
var broadcast: Callable
var heartbeat_sec := 5.0
## Override for tests: Callable() -> seconds.
var clock := Callable()

var sent := 0
var _last_rev := -1
var _last_sent := -1000000.0


func _init(p_station: DotRadioStation = null) -> void:
	station = p_station


func update() -> bool:
	if station == null or not broadcast.is_valid():
		return false
	var t := _now()
	if station.rev == _last_rev and t - _last_sent < heartbeat_sec:
		return false
	_last_rev = station.rev
	_last_sent = t
	broadcast.call(encode(station.now_playing()))
	sent += 1
	return true


## The payload for one joining peer: call from the host's peer-connected hook and send to that peer only.
func snapshot() -> PackedByteArray:
	return encode(station.now_playing())


static func encode(now: Dictionary) -> PackedByteArray:
	var d := now.duplicate(true)
	d["v"] = VERSION
	return JSON.stringify(d).to_utf8_buffer()


## The schedule dictionary, or a failure for anything oversized, malformed, of another version, or lacking the fields a client needs.
static func decode(payload: PackedByteArray) -> DotResult:
	if payload.size() > MAX_BYTES:
		return DotResult.fail(DotError.CODE_INVALID, "radio schedule payload too large", str(payload.size()))
	var json := JSON.new()
	var parsed: Variant = json.data if json.parse(payload.get_string_from_utf8()) == OK else null
	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "radio schedule payload is not an object")
	var d: Dictionary = parsed
	if int(d.get("v", 0)) != VERSION:
		return DotResult.fail(DotError.CODE_VERSION, "radio schedule version %s is not supported" % str(d.get("v", "none")))
	if not (d.get("id", null) is String):
		return DotResult.fail(DotError.CODE_INVALID, "radio schedule has no id")
	d.erase("v")
	return DotResult.success(d)


func _now() -> float:
	return float(clock.call()) if clock.is_valid() else Time.get_ticks_msec() / 1000.0
