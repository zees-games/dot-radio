class_name DotRadioApi
extends RefCounted

## Maps JSON-able requests onto the library and station; no transport. Listener ops need an actor, admin ops need [member admin_flag].

const CHANNEL := "radio"
const TOKEN_ACTOR := "radio-token"

const PLAYER_OPS := ["now", "tracks", "playlist", "request", "rate"]
const ADMIN_OPS := ["upload", "delete", "edit", "reorder", "playlist_add", "playlist_remove", "queue", "dequeue", "clear_queue", "skip", "mode", "start", "stop"]

var library: DotRadioLibrary
var station: DotRadioStation
## Flag an actor needs for admin ops.
var admin_flag := "radio"
var token_flags := PackedStringArray(["radio"])
## Listeners may request and rate when true; admins always may.
var allow_requests := true
## Append each upload to the playlist.
var auto_playlist := true
## Optional Callable(token) -> actor or null, for dot-auth style identities (duck-typed).
var identity: Callable = Callable()
## The host's Callable(actor, flag) -> bool; the admin token is judged by [member token_flags] instead.
var permit: Callable = Callable()

var _token := ""


func _init(p_library: DotRadioLibrary = null, p_station: DotRadioStation = null) -> void:
	library = p_library if p_library != null else DotRadioLibrary.new()
	station = p_station if p_station != null else DotRadioStation.new(library)


func set_admin_token(token: String) -> void:
	_token = token


## Value on success: the actor to pass to [method handle].
func authenticate(token: String) -> DotResult:
	if token.is_empty():
		return DotResult.fail(DotError.CODE_AUTH, "missing token")
	if identity.is_valid():
		var who: Variant = identity.call(token)
		if who != null:
			return DotResult.success(who)
	if not _token.is_empty() and DotHash.constant_time_equal(token.to_utf8_buffer(), _token.to_utf8_buffer()):
		return DotResult.success(TOKEN_ACTOR)
	DotLog.warn(CHANNEL, "radio auth refused")
	return DotResult.fail(DotError.CODE_AUTH, "bad token")


func is_admin(actor: Variant) -> bool:
	if actor is String and actor == TOKEN_ACTOR:
		return token_flags.has(admin_flag)
	return actor != null and permit.is_valid() and bool(permit.call(actor, admin_flag))


## Call from the host's frame or a timer.
func update() -> bool:
	return station.update()


## One request in, one result out; value on success is JSON-able.
func handle(actor: Variant, req: Dictionary) -> DotResult:
	var op := str(req.get("op", ""))
	if actor == null or (actor is String and actor.is_empty()):
		return DotResult.fail(DotError.CODE_AUTH, "no actor")
	if ADMIN_OPS.has(op) and not is_admin(actor):
		DotLog.warn(CHANNEL, "radio admin op refused", {"op": op, "actor": str(actor)})
		return DotResult.fail(DotError.CODE_FORBIDDEN, "'%s' needs '%s'" % [op, admin_flag])
	if not PLAYER_OPS.has(op) and not ADMIN_OPS.has(op):
		return DotResult.fail(DotError.CODE_INVALID, "unknown op '%s'" % op)
	if (op == "request" or op == "rate") and not allow_requests and not is_admin(actor):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "requests are switched off")
	var id := str(req.get("id", ""))
	var who := _name(actor)
	match op:
		"now": return DotResult.success(station.now_playing())
		"tracks": return DotResult.success(tracks_view())
		"playlist": return DotResult.success(_view())
		"request": return _reply(station.request(id, who))
		"rate":
			if id.is_empty():
				id = station.current_id()
			return station.rate(who, id, int(req.get("value", 0)))
		"upload": return _upload(actor, req)
		"delete": return library.remove(id)
		"edit": return library.update(id, req)
		"reorder": return _reply(station.set_playlist(_ids(req.get("ids", []))))
		"playlist_add": return _reply(station.add_to_playlist(id))
		"playlist_remove": return _reply(station.remove_from_playlist(id))
		"queue": return _reply(station.enqueue(id, who))
		"dequeue": return _reply(station.dequeue(int(req.get("index", -1))))
		"clear_queue":
			station.clear_queue()
			return DotResult.success(_view())
		"skip":
			station.skip()
			return DotResult.success(station.now_playing())
		"mode":
			station.set_modes(bool(req.get("shuffle", station.shuffle)), bool(req.get("loop", station.loop)))
			return DotResult.success(_view())
		"start":
			station.start()
			return DotResult.success(station.now_playing())
		"stop":
			station.stop()
			return DotResult.success(station.now_playing())
	return DotResult.fail(DotError.CODE_INTERNAL, "unhandled op '%s'" % op)


## Raw-bytes upload for transports that carry the body as is (HTTP PUT); the caller has already checked admin.
func upload_bytes(actor: Variant, file_name: String, bytes: PackedByteArray, meta: Dictionary = {}) -> DotResult:
	if not is_admin(actor):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "'upload' needs '%s'" % admin_flag)
	var res := library.add(file_name, bytes, meta, _name(actor))
	if res.ok and auto_playlist and bool(meta.get("playlist", true)):
		station.add_to_playlist(res.value["id"])
	return res


## Token + JSON text in, JSON text out; the whole API for a transport that only moves strings.
func handle_json(token: String, text: String) -> String:
	var auth := authenticate(token)
	if not auth.ok:
		return JSON.stringify(to_reply(auth))
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return JSON.stringify(to_reply(DotResult.fail(DotError.CODE_INVALID, "body must be a JSON object")))
	return JSON.stringify(to_reply(handle(auth.value, parsed)))


## {ok: true, value} or {ok: false, error: {code, message}}.
static func to_reply(res: DotResult) -> Dictionary:
	if res.ok:
		return {"ok": true, "value": res.value}
	return {"ok": false, "error": {"code": res.error.code, "message": res.error.message}}


func _upload(actor: Variant, req: Dictionary) -> DotResult:
	var b64 := str(req.get("data", ""))
	# Base64 inflates by a third; refuse before decoding what could never fit.
	if b64.length() > library.max_track_bytes * 4 / 3 + 8:
		return DotResult.fail(DotError.CODE_INVALID, "track is over the %d byte limit" % library.max_track_bytes)
	return upload_bytes(actor, str(req.get("name", "")), Marshalls.base64_to_raw(b64), req)


## Track metadata with ratings, the one listing both the admin page and listeners read.
func tracks_view() -> Dictionary:
	var rows: Array = []
	for t in library.list():
		t["rating"] = station.rating_of(t["id"])
		t["in_playlist"] = station.playlist.has(t["id"])
		rows.append(t)
	return {"tracks": rows, "bytes": library.total_bytes()}


func _view() -> Dictionary:
	return {"running": station.running, "playlist": station.playlist, "queue": station.queue, "shuffle": station.shuffle, "loop": station.loop, "current": station.current_id()}


func _reply(res: DotResult) -> DotResult:
	return res if not res.ok else DotResult.success(_view())


static func _ids(v: Variant) -> Array:
	return v if v is Array else []


static func _name(actor: Variant) -> String:
	return str(actor)
