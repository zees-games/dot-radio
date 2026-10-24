class_name DotRadioStation
extends RefCounted

## The one shared station: a playlist, a request queue and a schedule (current track plus the instant it starts), advanced by [method update].

signal track_changed(now: Dictionary)
signal queue_changed
signal playlist_changed
signal rated(id: String, up: int, down: int)

const CHANNEL := "radio"

var library: DotRadioLibrary
var shuffle := false
var loop := true
## Silence between tracks; also the head start clients get to download the next one.
var gap_sec := 2.0
var max_queue := 25
var max_per_requester := 2
## Callable() -> unix seconds; replaceable so a test controls time.
var clock: Callable = Callable()
## Where [method save_state] writes; empty keeps the station in memory.
var state_path := ""
var running := false
var rev := 0

var playlist: Array[String] = []
## Pending requests, front plays next: {id, by}.
var queue: Array[Dictionary] = []

var _current := ""
var _started := 0.0
var _last_list_id := ""
var _bag: Array[String] = []
var _bag_built := false
## id -> {voter: +1 or -1}
var _ratings: Dictionary = {}
var _rng := RandomNumberGenerator.new()


func _init(p_library: DotRadioLibrary = null, seed_value: int = 0) -> void:
	library = p_library if p_library != null else DotRadioLibrary.new()
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	library.track_removed.connect(_on_removed)


func now() -> float:
	return float(clock.call()) if clock.is_valid() else Time.get_unix_time_from_system()


## Starts the schedule at once (a no-op when already running).
func start() -> void:
	if running:
		return
	running = true
	_last_list_id = ""
	_bag.clear()
	_bag_built = false
	_advance(now())


func stop() -> void:
	running = false
	_current = ""
	_bump()
	track_changed.emit({})


## Cuts the current track and starts the next at once.
func skip() -> void:
	if running:
		_advance(now())


## Call every frame or on a timer; moves the schedule on when the current track has finished. Returns true when it changed track.
func update() -> bool:
	if not running:
		return false
	var t := now()
	if _current.is_empty():
		_advance(t)
		return not _current.is_empty()
	var changed := false
	var guard := 0
	while not _current.is_empty() and t >= _end() and guard < 64:
		_advance(_end() + gap_sec)
		changed = true
		guard += 1
	if not _current.is_empty() and t >= _end():
		_advance(t)
	return changed


## The wire form of the schedule. `position` is seconds into the track and is negative during the gap before it starts.
func now_playing(at: float = -1.0) -> Dictionary:
	var t := now() if at < 0.0 else at
	var out := {"running": running, "server_time": t, "rev": rev, "shuffle": shuffle, "loop": loop, "queue_length": queue.size()}
	if _current.is_empty() or not library.has(_current):
		out["id"] = ""
		return out
	var track := library.get_track(_current)
	out.merge({"id": _current, "title": track["title"], "artist": track["artist"], "kind": track["kind"], "size": track["size"],
		"sha256": track["sha256"], "duration": track["duration"], "started_at": _started, "position": t - _started,
		"rating": rating_of(_current)})
	var nxt := peek_next()
	if not nxt.is_empty():
		var n := library.get_track(nxt)
		out["next"] = {"id": nxt, "title": n["title"], "artist": n["artist"], "kind": n["kind"], "size": n["size"],
			"sha256": n["sha256"], "duration": n["duration"], "starts_in": _end() + gap_sec - t}
	return out


func current_id() -> String:
	return _current


## The id that plays after the current track, or "" when the station would stop.
func peek_next() -> String:
	while not queue.is_empty() and not library.has(queue[0]["id"]):
		queue.pop_front()
	if not queue.is_empty():
		return queue[0]["id"]
	return _planned()


func set_playlist(ids: Array) -> DotResult:
	var next: Array[String] = []
	for id in ids:
		if not library.has(str(id)):
			return DotResult.fail(DotError.CODE_INVALID, "no track '%s'" % str(id))
		next.append(str(id))
	playlist = next
	_playlist_edited()
	return DotResult.success(playlist.size())


func add_to_playlist(id: String) -> DotResult:
	if not library.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "no track '%s'" % id)
	if playlist.has(id):
		return DotResult.fail(DotError.CODE_CONFLICT, "'%s' is already in the playlist" % id)
	playlist.append(id)
	_playlist_edited()
	return DotResult.success(playlist.size())


func remove_from_playlist(id: String) -> DotResult:
	if not playlist.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not in the playlist" % id)
	playlist.erase(id)
	_playlist_edited()
	return DotResult.success(playlist.size())


## A listener's request, with the per-requester and total limits; admins use [method enqueue].
func request(id: String, requester: String) -> DotResult:
	if requester.is_empty():
		return DotResult.fail(DotError.CODE_AUTH, "requests need a player")
	var mine := 0
	for q in queue:
		mine += 1 if q["by"] == requester else 0
	if mine >= max_per_requester:
		return DotResult.fail(DotError.CODE_RATE_LIMITED, "you already have %d requests waiting" % mine)
	return enqueue(id, requester)


func enqueue(id: String, by: String = "") -> DotResult:
	if not library.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "no track '%s'" % id)
	if queue.size() >= max_queue:
		return DotResult.fail(DotError.CODE_QUOTA, "the request queue is full")
	if id == _current:
		return DotResult.fail(DotError.CODE_CONFLICT, "'%s' is playing now" % id)
	for q in queue:
		if q["id"] == id:
			return DotResult.fail(DotError.CODE_CONFLICT, "'%s' is already queued" % id)
	queue.append({"id": id, "by": by})
	_bump()
	queue_changed.emit()
	_persist()
	return DotResult.success(queue.size())


func dequeue(index: int) -> DotResult:
	if index < 0 or index >= queue.size():
		return DotResult.fail(DotError.CODE_INVALID, "no queue entry %d" % index)
	queue.remove_at(index)
	_bump()
	queue_changed.emit()
	_persist()
	return DotResult.success(queue.size())


func clear_queue() -> void:
	queue.clear()
	_bump()
	queue_changed.emit()
	_persist()


## Records one voter's rating of a track (+1, -1, or 0 to withdraw); a voter has one vote per track.
func rate(voter: String, id: String, value: int) -> DotResult:
	if voter.is_empty():
		return DotResult.fail(DotError.CODE_AUTH, "rating needs a player")
	if not library.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "no track '%s'" % id)
	var votes: Dictionary = _ratings.get(id, {})
	if value == 0:
		votes.erase(voter)
	else:
		votes[voter] = 1 if value > 0 else -1
	_ratings[id] = votes
	var r := rating_of(id)
	rated.emit(id, r["up"], r["down"])
	_persist()
	return DotResult.success(r)


func rating_of(id: String) -> Dictionary:
	var up := 0
	var down := 0
	for v in (_ratings.get(id, {}) as Dictionary).values():
		up += 1 if int(v) > 0 else 0
		down += 1 if int(v) < 0 else 0
	return {"up": up, "down": down, "score": up - down}


func set_modes(p_shuffle: bool, p_loop: bool) -> void:
	shuffle = p_shuffle
	loop = p_loop
	_bag.clear()
	_bag_built = false
	_bump()
	_persist()


func save_state() -> DotResult:
	if state_path.is_empty():
		return DotResult.success()
	var made := DotPaths.ensure_parent_dir(state_path)
	if not made.ok:
		return made
	var f := FileAccess.open(state_path, FileAccess.WRITE)
	if f == null:
		return DotResult.fail(DotError.CODE_IO, "cannot write the station state", error_string(FileAccess.get_open_error()))
	f.store_string(JSON.stringify({"version": 1, "playlist": playlist, "queue": queue, "shuffle": shuffle, "loop": loop, "ratings": _ratings}))
	f.close()
	DotWeb.sync_filesystem()
	return DotResult.success()


## Restores playlist, queue, modes and ratings; ids no longer in the library are dropped.
func load_state() -> DotResult:
	if state_path.is_empty() or not FileAccess.file_exists(state_path):
		return DotResult.success()
	var doc := DotPaths.read_json(state_path)
	if not doc.ok or not (doc.value is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "station state is not readable", state_path)
	var d: Dictionary = doc.value
	playlist.clear()
	for id in d.get("playlist", []):
		if library.has(str(id)):
			playlist.append(str(id))
	queue.clear()
	for q in d.get("queue", []):
		if q is Dictionary and library.has(str(q.get("id", ""))):
			queue.append({"id": str(q["id"]), "by": str(q.get("by", ""))})
	shuffle = bool(d.get("shuffle", shuffle))
	loop = bool(d.get("loop", loop))
	var r: Variant = d.get("ratings", {})
	_ratings = r if r is Dictionary else {}
	_bag.clear()
	_bag_built = false
	_bump()
	return DotResult.success()


func describe() -> Dictionary:
	return {"running": running, "current": _current, "playlist": playlist.size(), "queue": queue.size(), "shuffle": shuffle, "loop": loop, "rev": rev}


func _end() -> float:
	return _started + float(library.get_track(_current).get("duration", 0.0))


func _bump() -> void:
	rev += 1


func _persist() -> void:
	var res := save_state()
	if not res.ok:
		DotLog.warn(CHANNEL, "station state not saved", {"error": res.error.message})


func _playlist_edited() -> void:
	_bag.clear()
	_bag_built = false
	_bump()
	playlist_changed.emit()
	_persist()


# The next playlist track without consuming it: in order after the last one played, or the head of the shuffle bag.
func _planned() -> String:
	if playlist.is_empty():
		return ""
	if shuffle:
		if _bag.is_empty() and (loop or not _bag_built):
			_bag.assign(playlist)
			# Fisher-Yates on our own generator, so a seed makes a reproducible order.
			for i in range(_bag.size() - 1, 0, -1):
				var j := _rng.randi_range(0, i)
				var tmp := _bag[i]
				_bag[i] = _bag[j]
				_bag[j] = tmp
			if _bag.size() > 1 and _bag[0] == _last_list_id:
				_bag.push_back(_bag.pop_front())
			_bag_built = true
		return _bag[0] if not _bag.is_empty() else ""
	var at := playlist.find(_last_list_id) + 1
	if at >= playlist.size():
		return playlist[0] if loop else ""
	return playlist[at]


func _advance(start_at: float) -> void:
	var id := ""
	while not queue.is_empty():
		var q: Dictionary = queue.pop_front()
		if library.has(q["id"]):
			id = q["id"]
			queue_changed.emit()
			_persist()
			break
	if id.is_empty():
		id = _planned()
		if not id.is_empty():
			if shuffle and not _bag.is_empty():
				_bag.pop_front()
			_last_list_id = id
	_current = id
	_started = start_at
	_bump()
	if id.is_empty():
		running = false
		DotLog.info(CHANNEL, "station stopped: nothing left to play")
	else:
		DotLog.debug(CHANNEL, "track changed", {"id": id, "starts_in": start_at - now()})
	track_changed.emit(now_playing())


func _on_removed(id: String) -> void:
	playlist.erase(id)
	var kept: Array[Dictionary] = []
	for q in queue:
		if q["id"] != id:
			kept.append(q)
	queue = kept
	_ratings.erase(id)
	_bag.erase(id)
	_bump()
	playlist_changed.emit()
	queue_changed.emit()
	if _current == id and running:
		_advance(now())
	else:
		_persist()
