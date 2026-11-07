extends Node

## End to end: a real server [DotNetManager] pushes the station's schedule to a real client manager through [RadioNetHost] and [RadioScheduleMessage], and the [DotRadioClient] follows it. Needs dot-net (and dot-profile) linked beside dot-core.
## Run: godot --headless --path . res://examples/radio_net_selftest.tscn

const SECTIONS := 1
const CHECKS := 20
const BASE := "user://radio_net_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_line("dot-radio dot-net self-test")
	_test_end_to_end()
	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _manager(server: bool, scope: StringName, peer: int) -> DotNetManager:
	var m := DotNetManager.new()
	m.is_server = server
	m.local_peer_id = peer
	m.auto_tick = false
	m.config_file = ""
	m.service_scope = scope
	add_child(m)
	m.setup()
	return m


func _test_end_to_end() -> void:
	_section("schedule over dot-net")
	var t := [100.0]
	var mp3 := FileAccess.get_file_as_bytes("res://examples/fixtures/tone_a.mp3.fixture")
	var lib := DotRadioLibrary.new()
	lib.root = BASE.path_join("lib")
	lib.add("a.mp3", mp3, {"id": "a", "title": "Alpha", "artist": "X"})
	lib.add("b.mp3", mp3, {"id": "b", "title": "Beta", "artist": "Y"})
	var st := DotRadioStation.new(lib, 3)
	st.clock = func() -> float: return t[0]
	st.set_playlist(["a", "b"])

	var server := _manager(true, &"radio_net_server", 1)
	var peer := _manager(false, &"radio_net_client", 2)
	var wire: Array = []
	server.send_fn = func(to: int, payload: PackedByteArray, _d: int) -> void: wire.append([1, to, payload])
	peer.send_fn = func(to: int, payload: PackedByteArray, _d: int) -> void: wire.append([2, to, payload])

	var rc := DotRadioClient.new()
	rc.bind_input = false
	rc.clock = func() -> float: return t[0]
	rc.cache_dir = BASE.path_join("cache")
	rc.fetcher = func(_url: String) -> DotResult: return DotResult.success(mp3)
	var sink := DotRadioSinkNull.new()
	sink.clock = rc.clock
	rc.sink = sink
	add_child(rc)
	rc.set_process(false)

	var host := RadioNetHost.serve(server, st)
	host.replicator.clock = func() -> float: return t[0]
	rc.base_url = "http://unused.invalid"
	var follower := RadioNetHost.follow(peer, rc)
	server.start()
	peer.start()
	_check(not rc.poll_schedule, "following a pushed schedule turns polling off")
	server.add_peer(2)
	_pump(wire, server, peer)

	st.start()
	_check(host.update(), "the first update broadcasts")
	host.greet(2)
	_pump(wire, server, peer)
	_check(follower.applied == 2 and follower.refused == 0, "the client applied the broadcast and the greeting")
	_check(str(rc.now_playing().get("id", "")) == "a" and rc.now_playing().get("title", "") == "Alpha", "the client follows the server's track and title")
	_check(is_equal_approx(rc.expected_position(), st.now_playing()["position"]), "positions agree")

	t[0] += 3.0
	_check(not host.update(), "no broadcast inside the heartbeat while nothing changed")
	st.skip()
	_check(host.update(), "a skip broadcasts at once")
	_pump(wire, server, peer)
	_check(str(rc.now_playing().get("id", "")) == "b", "the client moved to the next track")
	_check(follower.applied == 3, "one more schedule applied")

	t[0] += 6.0
	_check(host.update(), "the heartbeat re-sends")
	_pump(wire, server, peer)
	_check(follower.applied == 4, "the heartbeat reached the client")
	_check(server.stats.messages_sent >= 4, "the server counted its sends")

	# A client may not push a schedule at the server: the message is TO_CLIENT only.
	var forged := peer.send(RadioScheduleMessage.make(host.replicator.snapshot()), 1)
	var before := wire.size()
	_check(forged.ok and before > 0, "the client managed to encode a forged schedule")
	var refused := server.receive(wire[wire.size() - 1][2], 2)
	_check(not refused.ok and refused.code() == DotError.CODE_FORBIDDEN, "the server refuses a schedule from a client")
	wire.clear()

	# A payload the radio refuses leaves the schedule alone.
	var rev_id := str(rc.now_playing().get("id", ""))
	server.send(RadioScheduleMessage.make("nope".to_utf8_buffer()), 2)
	_pump(wire, server, peer)
	_check(follower.refused == 1 and str(rc.now_playing().get("id", "")) == rev_id, "garbage is counted and the last schedule stays")
	var empty := RadioScheduleMessage.new()
	_check(not empty.validate().ok, "an empty payload fails validation")
	var big := RadioScheduleMessage.make(PackedByteArray())
	big.payload.resize(DotRadioReplicator.MAX_BYTES + 1)
	_check(not big.validate().ok, "an oversized payload fails validation")
	_check(RadioScheduleMessage.make("x".to_utf8_buffer()).validate().ok, "a small payload validates")
	var decoded := RadioScheduleMessage.new()
	decoded.read(DotNetReader.new(RadioScheduleMessage.make("hi".to_utf8_buffer()).to_bytes()))
	_check(decoded.payload == "hi".to_utf8_buffer(), "the body round-trips through the writer and reader")

	rc.tune_out()
	server.stop()
	peer.stop()
	_check(true, "both managers stopped")


# Delivers queued payloads to the other end; the schema tables travel first and are handled by the managers.
func _pump(wire: Array, server: DotNetManager, peer: DotNetManager) -> void:
	var guard := 0
	while not wire.is_empty() and guard < 100:
		guard += 1
		var w: Array = wire.pop_front()
		if int(w[0]) == 1:
			peer.receive(w[2], 1)
		else:
			server.receive(w[2], 2)


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
