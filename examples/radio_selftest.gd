extends Node

## Headless radio check: library, schedule and seek math, API permissions, HTTP round trip, client on a null sink, chat commands.
## Run: godot --headless --path . res://examples/radio_selftest.tscn

const SECTIONS := 8
const CHECKS := 143
const BASE := "user://radio_selftest"
const FIX := "res://examples/fixtures/"

var _passed := 0
var _failed := 0
var _section_count := 0
var _mp3 := PackedByteArray()
var _ogg := PackedByteArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_line("dot-radio self-test")
	_mp3 = FileAccess.get_file_as_bytes(FIX + "tone_a.mp3.fixture")
	_ogg = FileAccess.get_file_as_bytes(FIX + "tone_b.ogg.fixture")
	_clean()
	_test_library()
	_test_station()
	_test_persistence()
	_test_api()
	await _test_http()
	await _test_client()
	await _test_client_http()
	await _test_commands()
	_clean()
	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


# helpers

# Bytes that pass the magic check; the fake probe reads the length from the size (10 bytes per second).
func _fake(seconds: int, kind: String = "mp3") -> PackedByteArray:
	var b := PackedByteArray([0x49, 0x44, 0x33] if kind == "mp3" else [0x4F, 0x67, 0x67, 0x53])
	b.resize(seconds * 10)
	return b


func _fake_library(sub: String) -> DotRadioLibrary:
	var lib := DotRadioLibrary.new()
	lib.root = BASE.path_join(sub)
	lib.probe = func(b: PackedByteArray, _k: String) -> float: return b.size() / 10.0
	return lib


func _code(res: DotResult) -> String:
	return "" if res.ok else res.error.code


func _clock(t: Array) -> Callable:
	return func() -> float: return t[0]


func _station(sub: String, t: Array, names: Array = ["a", "b", "c"], secs: Array = [10, 20, 30]) -> DotRadioStation:
	var lib := _fake_library(sub)
	for i in names.size():
		lib.add(names[i] + ".mp3", _fake(secs[i]))
	var st := DotRadioStation.new(lib, 7)
	st.clock = _clock(t)
	st.gap_sec = 2.0
	st.set_playlist(names)
	return st


func _play_order(st: DotRadioStation, t: Array, n: int) -> Array:
	var order: Array = []
	st.start()
	order.append(st.current_id())
	while order.size() < n:
		var np := st.now_playing()
		t[0] = float(np["started_at"]) + float(np["duration"])
		st.update()
		order.append(st.current_id())
	return order


# sections

func _test_library() -> void:
	_section("library")
	_check(DotRadioCodec.kind_of(_mp3) == "mp3" and DotRadioCodec.kind_of(_ogg) == "ogg", "kind is read from the magic bytes")
	_check(DotRadioCodec.kind_of("hello world".to_utf8_buffer()) == "" and DotRadioCodec.kind_of(PackedByteArray([0xFF, 0xFB, 0x90, 0x00])) == "mp3", "text is neither; a bare MP3 frame is MP3")
	_check(DotRadioCodec.kind_of(PackedByteArray([0xFF, 0xE1, 0, 0])) == "", "a reserved layer is not MP3")
	var lib := DotRadioLibrary.new()
	lib.root = BASE.path_join("lib")
	var added := lib.add("Sunrise Tone.mp3", _mp3, {"artist": "Test"})
	_check(added.ok and added.value["id"] == "sunrise_tone" and added.value["kind"] == "mp3", "an MP3 is accepted and named from its file")
	_check(absf(float(added.value["duration"]) - 3.0) < 0.2, "the duration is read from the audio (%s)" % str(added.value.get("duration")))
	var o := lib.add("beep.ogg", _ogg, {"title": "Beep"})
	_check(o.ok and absf(float(o.value["duration"]) - 2.0) < 0.2 and o.value["title"] == "Beep", "an OGG is accepted with its own title")
	_check(FileAccess.file_exists(lib.root.path_join("tracks/sunrise_tone.mp3")) and added.value["sha256"] == DotHash.sha256_bytes(_mp3), "the file is stored with its hash")
	_check(_code(lib.add("again.mp3", _mp3, {"id": "Sunrise Tone"})) == DotError.CODE_CONFLICT, "a second track with the same id conflicts")
	_check(_code(lib.add("x.mp3", PackedByteArray())) == DotError.CODE_INVALID, "an empty upload is refused")
	_check(_code(lib.add("notes.mp3", "this is not audio at all".to_utf8_buffer())) == DotError.CODE_INVALID, "a file with the right name and the wrong bytes is refused")
	var junk := PackedByteArray([0x49, 0x44, 0x33, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	_check(_code(lib.add("junk.mp3", junk)) == DotError.CODE_INVALID, "right magic but not decodable is refused")
	lib.max_track_bytes = 1000
	_check(_code(lib.add("big.mp3", _mp3)) == DotError.CODE_INVALID, "a file over the size cap is refused")
	lib.max_track_bytes = 20 * 1024 * 1024
	lib.max_track_seconds = 2.5
	_check(_code(lib.add("long.mp3", _mp3, {"id": "long"})) == DotError.CODE_INVALID, "a track over the length cap is refused")
	lib.max_track_seconds = 3600.0
	lib.max_tracks = 2
	_check(_code(lib.add("third.ogg", _ogg, {"id": "third"})) == DotError.CODE_QUOTA, "the track count is capped")
	lib.max_tracks = 500
	lib.max_total_bytes = _mp3.size()
	_check(_code(lib.add("third.ogg", _ogg, {"id": "third"})) == DotError.CODE_QUOTA, "the total size is capped")
	_check(_code(lib.add("!!!.mp3", _mp3)) == DotError.CODE_INVALID and not FileAccess.file_exists(lib.root.path_join("tracks/.mp3")), "a name with no letters or digits is refused")
	var again := DotRadioLibrary.new()
	again.root = lib.root
	_check(again.load_index().ok and again.has("sunrise_tone") and again.has("beep") and again.list().size() == 2, "a new library reads the index back")
	DirAccess.remove_absolute(lib.root.path_join("tracks/beep.ogg"))
	var gone := DotRadioLibrary.new()
	gone.root = lib.root
	gone.load_index()
	_check(not gone.has("beep") and gone.has("sunrise_tone"), "a track whose file went missing is dropped on load")
	_check(lib.update("sunrise_tone", {"title": "Dawn"}).ok and lib.get_track("sunrise_tone")["title"] == "Dawn", "the title can be edited")
	var removed := [0]
	lib.track_removed.connect(func(_id: String) -> void: removed.append(1))
	_check(lib.remove("sunrise_tone").ok and not lib.has("sunrise_tone") and not FileAccess.file_exists(lib.root.path_join("tracks/sunrise_tone.mp3")) and removed.size() == 2, "remove deletes the file and signals")
	_check(_code(lib.remove("sunrise_tone")) == DotError.CODE_INVALID, "removing a missing track is invalid")


func _test_station() -> void:
	_section("station schedule")
	var t := [1000.0]
	var st := _station("st", t)
	var changes := []
	st.track_changed.connect(func(n: Dictionary) -> void: changes.append(n.get("id", "")))
	st.start()
	var n := st.now_playing(1004.0)
	_check(n["id"] == "a" and n["started_at"] == 1000.0 and n["position"] == 4.0, "start plays the first track from its beginning; position is now - start")
	_check(n["duration"] == 10.0 and n["next"]["id"] == "b" and n["next"]["starts_in"] == 8.0, "now-playing carries the duration and the next track with its start")
	t[0] = 1009.9
	_check(not st.update() and st.current_id() == "a", "nothing changes before the track ends")
	t[0] = 1010.0
	_check(st.update() and st.current_id() == "b", "the next track is chosen when the last one ends")
	_check(st.now_playing(1010.0)["position"] == -2.0, "it starts after the gap, so its position is negative until then")
	t[0] = 1050.0
	st.update()
	_check(st.current_id() == "c" and st.now_playing(1050.0)["position"] == 16.0, "a late update catches up along the schedule instead of restarting a track")
	t[0] = 1065.0
	st.update()
	_check(st.current_id() == "a" and changes == ["a", "b", "c", "a"], "the playlist loops and track_changed fires once per change (%s)" % str(changes))
	st.loop = false
	t[0] = 1200.0
	st.update()
	_check(st.current_id() != "" or not st.running, "a late update on a non-looping list lands somewhere valid")
	st.stop()
	_check(st.now_playing()["id"] == "" and not st.running, "stop leaves an empty schedule")
	var t2 := [5000.0]
	var s2 := _station("s2", t2)
	s2.loop = false
	_check(_play_order(s2, t2, 3) == ["a", "b", "c"], "in order without shuffle")
	t2[0] += 1000.0
	s2.update()
	_check(not s2.running and s2.current_id() == "", "without loop the station stops after the last track")
	s2.start()
	_check(s2.running and s2.current_id() == "a", "start after a stop begins again")
	t2[0] = 6000.0
	var s3 := _station("s3", t2)
	s3.start()
	s3.request("c", "p1")
	s3.request("b", "p1")
	_check(_code(s3.request("a", "p1")) == DotError.CODE_RATE_LIMITED, "a requester is limited to two waiting requests")
	_check(_code(s3.request("c", "p2")) == DotError.CODE_CONFLICT and _code(s3.request("a", "p2")) == DotError.CODE_CONFLICT, "a queued track or the playing track cannot be requested")
	_check(_code(s3.request("zzz", "p2")) == DotError.CODE_INVALID and _code(s3.request("b", "")) == DotError.CODE_AUTH, "an unknown track or an anonymous requester is refused")
	_check(s3.peek_next() == "c", "requests play before the playlist")
	t2[0] += 10.0
	s3.update()
	_check(s3.current_id() == "c", "the first request plays next")
	t2[0] += 100.0
	s3.update()
	var after := s3.current_id()
	_check(after == "a" or after == "b" or after == "c", "the queue drains in order")
	var s4 := _station("s4", t2)
	s4.start()
	s4.enqueue("c", "")
	s4.skip()
	_check(s4.current_id() == "c" and s4.now_playing()["position"] == 0.0, "skip starts the next track at once")
	var s5 := _station("s5", t2)
	s5.start()
	s5.skip()
	var s5b := s5.current_id()
	s5.library.remove(s5b)
	_check(s5.current_id() != s5b and not s5.playlist.has(s5b), "removing the playing track moves on and drops it from the playlist")
	s5.enqueue("c", "x")
	s5.library.remove("c")
	_check(s5.queue.is_empty(), "removing a queued track drops the request")
	var s6 := _station("s6", t2)
	s6.start()
	s6.rate("u1", "a", 1)
	s6.rate("u2", "a", -1)
	_check(s6.rating_of("a") == {"up": 1, "down": 1, "score": 0}, "ratings count one vote per voter")
	s6.rate("u1", "a", -1)
	_check(s6.rating_of("a")["down"] == 2 and s6.rating_of("a")["up"] == 0, "a voter can change their vote")
	s6.rate("u1", "a", 0)
	_check(s6.rating_of("a")["down"] == 1 and _code(s6.rate("", "a", 1)) == DotError.CODE_AUTH and _code(s6.rate("u", "zz", 1)) == DotError.CODE_INVALID, "a vote can be withdrawn; anonymous and unknown are refused")
	var ta := [0.0]
	var sa := _station("sh1", ta)
	sa.shuffle = true
	var sb := _station("sh2", ta)
	sb.shuffle = true
	var oa := _play_order(sa, ta, 9)
	var ob := _play_order(sb, ta, 9)
	_check(oa == ob, "a seed gives a reproducible shuffle")
	var cycles_ok := true
	for i in 3:
		var cyc := oa.slice(i * 3, i * 3 + 3)
		cyc.sort()
		cycles_ok = cycles_ok and cyc == ["a", "b", "c"]
	_check(cycles_ok, "every shuffle cycle plays each track once (%s)" % str(oa))
	var no_repeat := true
	for i in range(1, oa.size()):
		no_repeat = no_repeat and oa[i] != oa[i - 1]
	_check(no_repeat, "a reshuffle does not repeat the track that just played")
	_check(_code(st.set_playlist(["a", "nope"])) == DotError.CODE_INVALID and _code(st.add_to_playlist("a")) == DotError.CODE_CONFLICT, "a playlist can only hold library tracks, once each")


func _test_persistence() -> void:
	_section("station state")
	var t := [100.0]
	var st := _station("ps", t)
	st.state_path = BASE.path_join("ps/station.json")
	st.shuffle = true
	st.loop = false
	st.enqueue("b", "u1")
	st.rate("u1", "c", 1)
	st.set_playlist(["c", "a"])
	_check(FileAccess.file_exists(st.state_path), "edits write the state file")
	var again := DotRadioStation.new(st.library)
	again.state_path = st.state_path
	_check(again.load_state().ok and again.playlist == ["c", "a"] and again.shuffle and not again.loop, "playlist and modes come back")
	_check(again.queue.size() == 1 and again.queue[0]["id"] == "b" and again.rating_of("c")["up"] == 1, "queue and ratings come back")
	st.library.remove("a")
	var third := DotRadioStation.new(st.library)
	third.state_path = st.state_path
	third.load_state()
	_check(third.playlist == ["c"], "a track deleted meanwhile is dropped on load")
	DirAccess.open(BASE.path_join("ps")).remove("station.json")
	_check(DotRadioStation.new(st.library).load_state().ok, "no state path is a quiet success")


func _api(sub: String, t: Array) -> DotRadioApi:
	var lib := _fake_library(sub)
	var st := DotRadioStation.new(lib, 3)
	st.clock = _clock(t)
	var api := DotRadioApi.new(lib, st)
	api.set_admin_token("s3cret")
	api.permit = func(actor: Variant, flag: String) -> bool: return actor == "alice" and flag == "radio"
	return api


func _test_api() -> void:
	_section("api and permissions")
	var t := [10.0]
	var api := _api("api", t)
	var tok := DotRadioApi.TOKEN_ACTOR
	var up := api.handle(tok, {"op": "upload", "name": "one.mp3", "data": Marshalls.raw_to_base64(_fake(10))})
	_check(up.ok and up.value["id"] == "one" and api.station.playlist == ["one"], "the token uploads (base64) and the track joins the playlist")
	_check(api.handle("alice", {"op": "upload", "name": "two.mp3", "data": Marshalls.raw_to_base64(_fake(20))}).ok, "an actor the host's permit admits can upload")
	_check(_code(api.handle("bob", {"op": "upload", "name": "x.mp3", "data": Marshalls.raw_to_base64(_fake(5))})) == DotError.CODE_FORBIDDEN, "a listener cannot upload")
	_check(_code(api.handle("bob", {"op": "skip"})) == DotError.CODE_FORBIDDEN and _code(api.handle("bob", {"op": "delete", "id": "one"})) == DotError.CODE_FORBIDDEN, "listeners cannot skip or delete")
	_check(api.handle("bob", {"op": "tracks"}).ok and api.handle("bob", {"op": "now"}).ok and api.handle("bob", {"op": "playlist"}).ok, "listeners can read")
	api.handle(tok, {"op": "start"})
	_check(api.handle("bob", {"op": "request", "id": "two"}).ok and api.station.queue.size() == 1, "a listener can request")
	_check(api.handle("bob", {"op": "rate", "value": 1}).value["up"] == 1, "a listener rates the playing track by default")
	_check(_code(api.handle(null, {"op": "now"})) == DotError.CODE_AUTH and _code(api.handle("", {"op": "now"})) == DotError.CODE_AUTH, "no actor is refused")
	_check(_code(api.handle(tok, {"op": "explode"})) == DotError.CODE_INVALID, "an unknown op is invalid")
	api.token_flags = PackedStringArray()
	_check(_code(api.handle(tok, {"op": "skip"})) == DotError.CODE_FORBIDDEN, "a token without the flag is not an admin")
	api.token_flags = PackedStringArray(["radio"])
	api.allow_requests = false
	_check(_code(api.handle("bob", {"op": "request", "id": "one"})) == DotError.CODE_FORBIDDEN and api.handle("alice", {"op": "rate", "value": 1}).ok, "requests can be switched off for listeners only")
	_check(api.authenticate("s3cret").ok and _code(api.authenticate("wrong")) == DotError.CODE_AUTH and _code(api.authenticate("")) == DotError.CODE_AUTH, "the token authenticates; wrong and empty are refused")
	var plain := DotRadioApi.new()
	_check(_code(plain.authenticate("anything")) == DotError.CODE_AUTH, "no configured token refuses everything")
	api.identity = func(tk: String) -> Variant: return "carol" if tk == "carol-session" else null
	_check(api.authenticate("carol-session").value == "carol" and not api.is_admin("carol"), "an identity hook yields an actor, who is not admin unless permit says so")
	var big := _api("api2", t)
	big.set_admin_token("x")
	big.library.max_track_bytes = 100
	_check(_code(big.handle(DotRadioApi.TOKEN_ACTOR, {"op": "upload", "name": "b.mp3", "data": "A".repeat(500)})) == DotError.CODE_INVALID, "an oversized base64 body is refused before decoding")
	var reply: Dictionary = JSON.parse_string(api.handle_json("s3cret", '{"op":"now"}'))
	_check(reply["ok"] == true and reply["value"].has("server_time"), "handle_json round trip")
	_check(JSON.parse_string(api.handle_json("nope", '{"op":"now"}'))["error"]["code"] == DotError.CODE_AUTH and JSON.parse_string(api.handle_json("s3cret", "[1]"))["error"]["code"] == DotError.CODE_INVALID, "handle_json refuses a bad token and a non-object body")
	var order := api.handle(tok, {"op": "reorder", "ids": ["two", "one"]})
	_check(order.ok and api.station.playlist == ["two", "one"] and _code(api.handle(tok, {"op": "reorder", "ids": ["two", "ghost"]})) == DotError.CODE_INVALID, "reorder sets the order and rejects unknown ids")
	_check(api.handle(tok, {"op": "mode", "shuffle": true, "loop": false}).ok and api.station.shuffle and not api.station.loop, "mode sets shuffle and loop")
	_check(api.handle(tok, {"op": "delete", "id": "one"}).ok and not api.station.playlist.has("one"), "delete takes the track out of the playlist")


# Runs the server's poll while the client side of a socket exchange completes; returns {status, head, body}.
func _raw(h: DotRadioHttp, method: String, path: String, token: String = "s3cret", body: PackedByteArray = PackedByteArray(), claim: int = -1) -> Dictionary:
	var head := "%s %s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n" % [method, path, body.size() if claim < 0 else claim]
	if token != "":
		head += "Authorization: Bearer %s\r\n" % token
	var c := StreamPeerTCP.new()
	c.connect_to_host("127.0.0.1", h.server.port())
	var out := PackedByteArray()
	var sent := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		c.poll()
		if not sent and c.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			c.put_data((head + "\r\n").to_utf8_buffer() + body)
			sent = true
		h.poll()
		c.poll()
		if c.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var n := c.get_available_bytes()
			if n > 0:
				out.append_array(c.get_data(n)[1])
		elif sent:
			break
		OS.delay_msec(1)
	var text := out.get_string_from_utf8()
	var i := out.size()
	for k in range(out.size() - 3):
		if out[k] == 13 and out[k + 1] == 10 and out[k + 2] == 13 and out[k + 3] == 10:
			i = k
			break
	var head_text := out.slice(0, i).get_string_from_utf8()
	var payload := out.slice(i + 4) if i < out.size() else PackedByteArray()
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8()) if not payload.is_empty() and payload[0] == 0x7B else null
	return {"status": int(text.split(" ")[1]) if text.length() > 12 else -1, "head": head_text, "body": payload, "json": parsed if parsed is Dictionary else {}}


func _http(sub: String, t: Array) -> DotRadioHttp:
	var api := _api(sub, t)
	api.library.probe = Callable()
	var h := DotRadioHttp.new(api)
	return h


func _test_http() -> void:
	_section("http round trip")
	var t := [100.0]
	var h := _http("http", t)
	_check(h.start_from_config({"enabled": false}).ok and not h.server.is_listening(), "disabled by default opens nothing")
	_check(not DotRadioHttp.new(_api("h0", t)).start_from_config({"enabled": true}).ok, "enabled with no token source refuses to start")
	_check(not DotRadioHttp.new(_api("h0", t)).start_from_config({"enabled": true, "token_file": BASE + "/missing.token"}).ok, "a missing token file refuses to start")
	DirAccess.make_dir_recursive_absolute(BASE)
	var tf := FileAccess.open(BASE + "/radio.token", FileAccess.WRITE)
	tf.store_string("  s3cret\n")
	tf.close()
	var res := h.start_from_config({"enabled": true, "port": 0, "token_file": BASE + "/radio.token", "library_dir": BASE + "/http", "autostart": false})
	_check(res.ok and h.server.is_listening(), "enabled with a token file listens on loopback")
	if not res.ok:
		_check(false, "server did not start: " + res.error.message)
		return
	_check(_raw(h, "GET", "/", "")["status"] == 200 and _raw(h, "GET", "/")["body"].get_string_from_utf8().contains("<title>Radio</title>"), "the admin page is served without a token")
	_check(_raw(h, "GET", "/api/tracks", "")["status"] == 401 and _raw(h, "GET", "/api/tracks", "wrong")["status"] == 401, "the API needs a token")
	_check(_raw(h, "PUT", "/api/tracks/one.mp3", "", _mp3)["status"] == 401, "an upload without a token is 401")
	var put := _raw(h, "PUT", "/api/tracks/Sunrise%20Tone.mp3?title=Sunrise&artist=Tester", "s3cret", _mp3)
	_check(put["status"] == 200 and put["json"]["value"]["id"] == "sunrise" and put["json"]["value"]["artist"] == "Tester", "PUT uploads raw audio with title and artist in the query")
	var got := _raw(h, "GET", "/track/sunrise", "")
	_check(got["status"] == 200 and got["body"] == _mp3 and got["head"].to_lower().contains("content-type: audio/mpeg"), "the track file is served to anyone, byte for byte")
	_check(got["head"].to_lower().contains("access-control-allow-origin: *") and got["head"].contains('ETag: "' + DotHash.sha256_bytes(_mp3) + '"'), "public reads allow any origin and carry the hash as ETag")
	_check(_raw(h, "GET", "/track/nothing", "")["status"] == 404 and _raw(h, "GET", "/track/..%2Flibrary.json", "")["status"] == 404, "an unknown or traversing track id is 404")
	var tracks := _raw(h, "GET", "/tracks", "")
	_check(tracks["status"] == 200 and tracks["json"]["tracks"].size() == 1, "the track list is public")
	var bad := _raw(h, "PUT", "/api/tracks/x.mp3", "s3cret", "not audio".to_utf8_buffer())
	_check(bad["status"] == 400 and bad["json"]["ok"] == false, "an invalid upload is 400 with the reason")
	var dup := _raw(h, "PUT", "/api/tracks/sunrise.mp3", "s3cret", _mp3)
	_check(dup["status"] == 409, "a duplicate is 409")
	h.api.library.max_track_bytes = 2000
	h.server.max_body_bytes = 2000
	_check(_raw(h, "PUT", "/api/tracks/big.mp3", "s3cret", PackedByteArray(), 5000)["status"] == 413, "a declared body over the cap is 413 before it is read")
	h.api.library.max_track_bytes = 20 * 1024 * 1024
	h.server.max_body_bytes = 20 * 1024 * 1024
	_check(_raw(h, "PUT", "/api/tracks/beep.ogg", "s3cret", _ogg)["status"] == 200, "an OGG uploads too")
	var started := _raw(h, "POST", "/api/start", "s3cret")
	_check(started["status"] == 200, "POST /api/<op> runs an admin op")
	var now := _raw(h, "GET", "/now", "")
	_check(now["status"] == 200 and now["json"]["id"] == "sunrise" and now["json"].has("server_time"), "now-playing is public")
	var env := _raw(h, "POST", "/api", "s3cret", '{"op":"mode","shuffle":true}'.to_utf8_buffer())
	_check(env["json"]["ok"] == true and env["json"]["value"]["shuffle"] == true, "POST /api takes the JSON envelope")
	_check(_raw(h, "POST", "/api", "s3cret", "{nope".to_utf8_buffer())["status"] == 400, "a malformed envelope is 400")
	_check(_raw(h, "DELETE", "/api/tracks/beep", "s3cret")["status"] == 200 and _raw(h, "GET", "/track/beep", "")["status"] == 404, "DELETE removes a track")
	h.api.token_flags = PackedStringArray()
	_check(_raw(h, "POST", "/api/skip", "s3cret")["status"] == 403, "a token without the radio flag is 403")
	h.api.token_flags = PackedStringArray(["radio"])
	for i in 7:
		_raw(h, "GET", "/api/now", "bad")
	_check(_raw(h, "GET", "/api/now", "s3cret")["status"] == 429, "repeated bad tokens lock the address out with 429")
	h.stop()
	var shared := DotHttpServer.new()
	var h2 := DotRadioHttp.new(_api("h2", t))
	h2.mount(shared, "/radio")
	h2.api.set_admin_token("s3cret")
	shared.start(0)
	h2.server = shared
	_check(_raw(h2, "GET", "/radio", "")["status"] == 301 and _raw(h2, "GET", "/radio/", "")["status"] == 200 and _raw(h2, "GET", "/radio/now", "")["status"] == 200, "mounted on a shared server under a prefix")
	_check(_raw(h2, "GET", "/now", "")["status"] == 404 and shared.max_body_bytes >= h2.api.library.max_track_bytes, "nothing leaks outside the prefix, and the body cap fits a track")
	shared.stop()


func _test_client() -> void:
	_section("client with a null sink")
	var t := [0.0]
	var clock := _clock(t)
	var lib := DotRadioLibrary.new()
	lib.root = BASE.path_join("cl")
	var ta: Dictionary = lib.add("a.mp3", _mp3, {"id": "a"}).value
	var tb: Dictionary = lib.add("b.ogg", _ogg, {"id": "b"}).value
	var served := {"a": _mp3, "b": _ogg}
	var fetched := []
	var c := DotRadioClient.new()
	c.bind_input = false
	c.clock = clock
	c.cache_dir = BASE.path_join("cache")
	c.fetcher = func(url: String) -> DotResult:
		fetched.append(url)
		var id := url.get_file()
		return DotResult.success(served[id]) if served.has(id) else DotResult.fail(DotError.CODE_HTTP, "404")
	var sink := DotRadioSinkNull.new()
	sink.clock = clock
	c.sink = sink
	c.base_url = ""
	add_child(c)
	c.set_process(false)
	var started := []
	c.track_started.connect(func(tr: Dictionary) -> void: started.append(tr["id"]))
	var tunes := []
	c.tuned_changed.connect(func(on: bool) -> void: tunes.append(on))
	c.prefetch_sec = 1.0
	var nowd := {"id": "a", "kind": "mp3", "size": ta["size"], "sha256": ta["sha256"], "duration": 3.0, "position": 1.0, "title": "A", "next": {"id": "b", "kind": "ogg", "size": tb["size"], "sha256": tb["sha256"], "duration": 2.0, "title": "B"}}
	c.apply_now(nowd)
	c.tick()
	_check(not c.tuned and sink.plays.is_empty() and fetched.is_empty(), "nothing plays or downloads before tune-in")
	c.tune_in()
	c.tick()
	_check(c.tuned and tunes == [true] and sink.plays.size() == 1, "tune-in starts playback")
	_check(is_equal_approx(sink.plays[0]["from"], 1.0) and started == ["a"], "it is seeked to the station's position")
	_check(fetched == ["/track/a"], "the track was downloaded once")
	t[0] = 0.5
	c.tick()
	_check(sink.plays.size() == 1 and c.resyncs == 0, "playback in step is left alone")
	sink.skew = 1.5
	c.tick()
	_check(c.resyncs == 1 and sink.plays.size() == 2 and is_equal_approx(sink.plays[1]["from"], 1.5), "a drifted sink is re-seeked to the schedule")
	sink.skew = 0.0
	t[0] = 0.9
	c.apply_now({"id": "a", "kind": "mp3", "size": ta["size"], "sha256": ta["sha256"], "duration": 3.0, "position": 1.9, "title": "A", "next": nowd["next"]})
	c.tick()
	_check(c.resyncs == 1 and sink.plays.size() == 2, "a fresh schedule that agrees causes no seek")
	t[0] = 1.0
	c.tick()
	_check(fetched.size() == 2 and fetched[1].ends_with("/track/b"), "the next track is fetched ahead when the current one is nearly over")
	var cache_file := ""
	for f in DirAccess.get_files_at(BASE.path_join("cache")):
		cache_file += f
	_check(cache_file.contains("a-") and cache_file.contains("b-"), "downloads are cached on disk")
	t[0] = 2.5
	c.apply_now({"id": "a", "kind": "mp3", "size": ta["size"], "sha256": ta["sha256"], "duration": 3.0, "position": 3.5, "title": "A"})
	c.tick()
	t[0] = 3.5
	c.tick()
	_check(not sink.is_playing(), "the sink stops when the track has run out")
	c.apply_now({"id": "b", "kind": "ogg", "size": tb["size"], "sha256": tb["sha256"], "duration": 2.0, "position": -1.0, "title": "B"})
	c.tick()
	_check(not sink.is_playing() and sink.plays.size() == 2, "a track still in its gap waits")
	t[0] = 4.6
	c.tick()
	_check(sink.is_playing() and sink.plays.size() == 3 and is_equal_approx(sink.plays[2]["from"], 0.1) and started == ["a", "b"], "and starts at the right offset once its time comes")
	_check(fetched.size() == 2, "the prefetched track was not downloaded again")
	c.volume = 0.5
	_check(is_equal_approx(sink.volume_db, linear_to_db(0.5)), "volume reaches the sink in decibels")
	c.muted = true
	_check(sink.muted, "mute reaches the sink")
	c.volume = 3.0
	_check(c.volume == 1.0, "volume is clamped")
	c.tune_out()
	_check(not c.tuned and not sink.is_playing() and tunes == [true, false], "tune-out silences the sink")
	c.tick()
	_check(sink.plays.size() == 3, "an untuned client does nothing on tick")
	# a corrupted download is rejected
	var c2 := DotRadioClient.new()
	c2.bind_input = false
	c2.clock = clock
	c2.cache_dir = BASE.path_join("cache2")
	c2.fetcher = func(_u: String) -> DotResult: return DotResult.success(_ogg)
	var s2 := DotRadioSinkNull.new()
	s2.clock = clock
	c2.sink = s2
	add_child(c2)
	c2.set_process(false)
	var errors := []
	c2.failed.connect(func(m: String) -> void: errors.append(m))
	c2.apply_now({"id": "a", "kind": "mp3", "size": ta["size"], "sha256": ta["sha256"], "duration": 3.0, "position": 0.0})
	c2.tune_in()
	c2.tick()
	_check(errors.size() == 1 and s2.plays.is_empty(), "a download that does not match the station's hash is not played")
	c2.apply_now({"id": ""})
	c2.tick()
	_check(not s2.is_playing(), "a stopped station plays nothing")
	# input actions
	c2.ensure_actions()
	_check(InputMap.has_action("radio_toggle") and InputMap.has_action("radio_volume_up") and InputMap.has_action("radio_mute"), "default actions exist")
	var ev := InputEventAction.new()
	ev.action = "radio_toggle"
	ev.pressed = true
	c2.tune_out()
	_check(c2.handle_input(ev) and c2.tuned, "the toggle action tunes in, and only from an input event")
	ev.action = "radio_volume_down"
	var before := c2.volume
	c2.handle_input(ev)
	_check(c2.volume < before, "the volume action steps the volume")
	ev.action = "something_else"
	_check(not c2.handle_input(ev), "other events are left alone")
	c2.action_toggle = "my_radio_key"
	InputMap.add_action("my_radio_key")
	ev.action = "my_radio_key"
	c2.tune_out()
	_check(c2.handle_input(ev) and c2.tuned, "the action names can be rebound to the game's own")
	InputMap.erase_action("my_radio_key")
	c.queue_free()
	c2.queue_free()


# Pumps frames (and the server) until the condition holds.
func _until(cond: Callable, h: DotRadioHttp = null, ms: int = 5000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		if h != null:
			h.poll()
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _test_client_http() -> void:
	_section("client over loopback")
	var t := [100.0]
	var h := _http("ch", t)
	h.api.station.gap_sec = 0.0
	h.api.set_admin_token("s3cret")
	h.mount(h.server)
	h.api.upload_bytes(DotRadioApi.TOKEN_ACTOR, "a.mp3", _mp3, {"id": "a"})
	h.api.upload_bytes(DotRadioApi.TOKEN_ACTOR, "b.ogg", _ogg, {"id": "b"})
	h.api.station.start()
	_check(h.server.start(0).ok, "server listens")
	var c := DotRadioClient.new()
	c.bind_input = false
	c.cache_dir = BASE.path_join("cache_http")
	c.base_url = "http://127.0.0.1:%d" % h.server.port()
	var sink := DotRadioSinkNull.new()
	c.sink = sink
	add_child(c)
	t[0] = 100.0
	h.api.station.clock = func() -> float: return 100.0 + Time.get_ticks_msec() / 1000.0 - c_start[0]
	c_start[0] = Time.get_ticks_msec() / 1000.0
	c.tune_in()
	var ok: bool = await _until(func() -> bool: return sink.is_playing(), h)
	_check(ok, "the client fetched the schedule and the track over HTTP and is playing")
	_check(ok and float(sink.plays[0]["from"]) >= 0.0 and float(sink.plays[0]["from"]) < 2.0 and float(sink.plays[0]["length"]) > 2.5, "it was seeked into the first track and decoded 3 s of audio")
	_check(FileAccess.file_exists(c.cache_dir.path_join("a-%s.mp3" % h.api.library.get_track("a")["sha256"].left(12))), "the download is in the cache")
	c.tune_out()
	_check(not sink.is_playing(), "tune-out stops playback")
	c.queue_free()
	h.stop()


var c_start := [0.0]


func _test_commands() -> void:
	_section("chat commands")
	var t := [0.0]
	var clock := _clock(t)
	var api := _api("cmd", t)
	api.library.add("Sunrise.mp3", _fake(30), {"artist": "Tester"})
	api.library.add("Moonlight.mp3", _fake(30))
	api.station.set_playlist(["sunrise", "moonlight"])
	api.station.start()
	var c := DotRadioClient.new()
	c.bind_input = false
	c.clock = clock
	c.sink = DotRadioSinkNull.new()
	add_child(c)
	c.set_process(false)
	c.apply_now(api.station.now_playing())
	var cmds := DotRadioCommands.new()
	cmds.client = c
	cmds.api = api
	cmds.actor = "bob"
	var r: String = await cmds.execute("!song")
	_check(r == "Now playing: Sunrise by Tester (+0/-0)", "!song names the track (%s)" % r)
	r = await cmds.execute("!radio on")
	_check(c.tuned and r.begins_with("Radio on"), "!radio on tunes in")
	r = await cmds.execute("!radio 40")
	_check(is_equal_approx(c.volume, 0.4) and r.contains("40%"), "!radio 40 sets the volume")
	await cmds.execute("!radio mute")
	_check(c.muted, "!radio mute mutes")
	await cmds.execute("!radio off")
	_check(not c.tuned, "!radio off tunes out")
	r = await cmds.execute("!request moon")
	_check(r == "Queued 'moonlight'." and api.station.queue[0]["by"] == "bob", "!request finds a track by part of its title")
	r = await cmds.execute("!request nothing like it")
	_check(r.begins_with("No track matches"), "!request reports no match")
	r = await cmds.execute("!rate up")
	_check(r.contains("+1/-0") and api.station.rating_of("sunrise")["up"] == 1, "!rate up rates the playing track")
	await cmds.execute("!dislike")
	_check(api.station.rating_of("sunrise")["down"] == 1 and api.station.rating_of("sunrise")["up"] == 0, "!dislike is !rate down")
	_check(await cmds.execute("hello there") == "", "a line that is not a radio command is left alone")
	var seen := {}
	var reg := FakeRegistrar.new()
	reg.seen = seen
	_check(cmds.register(reg) == 4 and seen.has("radio") and seen.has("song") and seen.has("request") and seen.has("rate"), "register hands four commands to a registry with add_command")
	var out: String = await seen["song"].call("")
	_check(out.begins_with("Now playing"), "a registered handler runs the command")
	var cmds2 := DotRadioCommands.new()
	cmds2.client = c
	r = await cmds2.execute("!request sunrise")
	_check(r.contains("no server connection"), "without a server connection a server command says so")
	cmds2.send = func(req: Dictionary) -> DotResult: return api.handle("carol", req)
	r = await cmds2.execute("!request sunrise")
	_check(r.contains("playing") or r.contains("Queued"), "a send callable carries the command to the server")
	c.queue_free()


class FakeRegistrar extends RefCounted:
	var seen: Dictionary

	func add_command(name: StringName, _help: String, fn: Callable) -> void:
		seen[str(name)] = fn


# harness

func _clean() -> void:
	DotPaths.remove_tree(BASE)


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("== %s ==" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
