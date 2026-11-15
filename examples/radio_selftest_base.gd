extends Node

## [code]radio_selftest.gd[/code]'s helpers and its library section: the counters, the fake library and clock, and the report lines.

const BASE := "user://radio_selftest"
const FIX := "res://examples/fixtures/"

var _passed := 0
var _failed := 0
var _section_count := 0
var _mp3 := PackedByteArray()
var _ogg := PackedByteArray()


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
