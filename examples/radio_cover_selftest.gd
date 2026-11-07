extends "res://examples/radio_selftest.gd"

## Album and cover tags, the cover route, and the radio page in a workbench registry. Reuses the helpers of radio_selftest.gd (tag builders, raw HTTP) and runs only its own section.
## Run: godot --headless --path . res://examples/radio_cover_selftest.tscn

const COVER_SECTIONS := 1
const COVER_CHECKS := 21


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_line("dot-radio cover self-test")
	_mp3 = FileAccess.get_file_as_bytes(FIX + "tone_a.mp3.fixture")
	_ogg = FileAccess.get_file_as_bytes(FIX + "tone_b.ogg.fixture")
	_clean()
	await _test_cover_and_page()
	_clean()
	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != COVER_SECTIONS or _passed + _failed != COVER_CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, COVER_SECTIONS, COVER_CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


const PNG := [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]


# An ID3v2.3 APIC body: encoding 0, mime, picture type 3, a description, then the image.
static func _apic(mime: String, img: PackedByteArray, enc: int = 0, desc: String = "front") -> PackedByteArray:
	var b := PackedByteArray([enc]) + mime.to_ascii_buffer() + PackedByteArray([0, 3])
	if enc == 1:
		b.append_array(PackedByteArray([0xFF, 0xFE]))
		for i in desc.length():
			b.append_array(PackedByteArray([desc.unicode_at(i), 0]))
		b.append_array(PackedByteArray([0, 0]))
	else:
		b.append_array(desc.to_ascii_buffer() + PackedByteArray([0]))
	return b + img


class FakeBench:
	extends RefCounted
	var server := DotHttpServer.new()
	var pages: Dictionary = {}

	func register_page(id: String, title: String, html: String, flag: String = "") -> bool:
		pages[id] = [title, html, flag]
		return true


func _test_cover_and_page() -> void:
	DirAccess.make_dir_recursive_absolute(BASE)
	var tf := FileAccess.open(BASE + "/radio.token", FileAccess.WRITE)
	tf.store_string("s3cret\n")
	tf.close()
	_section("album, cover and the workbench page")
	var png := PackedByteArray(PNG)
	var tags := DotRadioTags.read(_id3(3, [["TIT2", _txt(0, "S")], ["TALB", _txt(0, "The Album")]]) + _mp3, "mp3")
	_check(tags["album"] == "The Album", "ID3v2 album")
	var v4 := DotRadioTags.read(_id3(4, [["TALB", _txt(3, "Caf\u00e9")]]) + _mp3, "mp3")
	_check(v4["album"] == "Caf\u00e9", "ID3v2.4 UTF-8 album")
	_check(DotRadioTags.read(_vorbis_tags(["ALBUM=Ogg Album"]), "ogg")["album"] == "Ogg Album", "Vorbis album")
	var with_cover := _id3(3, [["TALB", _txt(0, "A")], ["APIC", _apic("image/png", png)]]) + _mp3
	var cov := DotRadioTags.cover(with_cover, "mp3")
	_check(cov.get("mime", "") == "image/png" and cov.get("data", PackedByteArray()) == png, "APIC cover, found after another frame")
	var jpg := PackedByteArray([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
	var jc := DotRadioTags.cover(_id3(4, [["APIC", _apic("image/png", jpg, 1)]]) + _mp3, "mp3")
	_check(jc.get("mime", "") == "image/jpeg" and jc.get("data", PackedByteArray()) == jpg, "the mime comes from the bytes, and a UTF-16 description is skipped")
	var pic22 := PackedByteArray([0]) + "PNG".to_ascii_buffer() + PackedByteArray([3, 0]) + png
	var t22 := "ID3".to_ascii_buffer() + PackedByteArray([2, 0, 0]) + _ss(6 + pic22.size()) + "PIC".to_ascii_buffer() + PackedByteArray([0, (pic22.size() >> 8) & 0xFF, pic22.size() & 0xFF]) + pic22 + _mp3
	_check(DotRadioTags.cover(t22, "mp3").get("mime", "") == "image/png", "ID3v2.2 PIC cover")
	_check(DotRadioTags.cover(_id3(3, [["APIC", _apic("image/png", "not an image at all".to_ascii_buffer())]]) + _mp3, "mp3").is_empty(), "bytes that are not PNG or JPEG are not a cover")
	var huge := png.duplicate()
	huge.resize(DotRadioTags.MAX_COVER + 1)
	_check(DotRadioTags.cover(_id3(3, [["APIC", _apic("image/png", huge)]]) + _mp3, "mp3").is_empty(), "a cover over the cap is dropped")
	_check(DotRadioTags.cover(_mp3, "mp3").is_empty() and DotRadioTags.cover(_ogg, "ogg").is_empty(), "no cover when there is none, and OGG covers are not read")

	var t := [100.0]
	var h := _http("cov", t)
	var res := h.start_from_config({"enabled": true, "port": 0, "token_file": BASE + "/radio.token", "library_dir": BASE + "/cov", "autostart": false})
	if not res.ok:
		_check(false, "server did not start: " + res.error.message)
		return
	var put := _raw(h, "PUT", "/api/tracks/with_cover.mp3?album=Typed", "s3cret", with_cover)
	var tr: Dictionary = put["json"]["value"] if put["status"] == 200 else {}
	_check(put["status"] == 200 and tr.get("album") == "Typed" and tr.get("cover") == "image/png", "an upload keeps the cover, and a typed album beats the tag")
	var plain := _raw(h, "PUT", "/api/tracks/plain.mp3", "s3cret", _id3(3, [["TALB", _txt(0, "Tag Album")]]) + _mp3)
	_check(plain["json"]["value"]["album"] == "Tag Album" and plain["json"]["value"]["cover"] == "", "an untyped album comes from the tag; no cover means an empty mime")
	var got := _raw(h, "GET", "/cover/with_cover", "")
	_check(got["status"] == 200 and got["body"] == png and got["head"].to_lower().contains("content-type: image/png") and got["head"].to_lower().contains("access-control-allow-origin: *"), "the cover is served publicly with its type")
	_check(_raw(h, "GET", "/cover/plain", "")["status"] == 404 and _raw(h, "GET", "/cover/..%2Flibrary.json", "")["status"] == 404, "no cover, or a traversing id, is 404")
	h.api.station.start()
	_check(h.api.station.now_playing().get("album", "x") != "x" and h.api.station.now_playing().has("cover"), "now-playing names the album and whether there is a cover")
	var lib := h.api.library
	var cpath := lib.cover_path("with_cover", "image/png")
	_check(FileAccess.file_exists(cpath) and lib.read_cover("with_cover").ok and not lib.read_cover("plain").ok, "the library reads a stored cover")
	_check(_raw(h, "DELETE", "/api/tracks/with_cover", "s3cret")["status"] == 200 and not FileAccess.file_exists(cpath), "removing the track removes its cover file")
	h.stop()

	var bench := FakeBench.new()
	var rh := DotRadioHttp.new(_api("wb", t))
	rh.api.set_admin_token("s3cret")
	_check(not DotRadioWorkbench.register(bench, rh, "radio") and bench.pages.is_empty(), "a prefix that is not a plain path is refused")
	_check(DotRadioWorkbench.register(bench, rh, "/radio") and bench.pages.has("radio") and bench.pages["radio"][2] == "radio", "the radio registers its own page behind the radio flag")
	var html: String = bench.pages["radio"][1]
	_check(html.contains('<meta name="radio-root" content="/radio/">') and html.contains("<title>Radio</title>"), "the page carries the radio route root")
	bench.server.start(0)
	_check(_raw(rh, "GET", "/radio/now", "")["status"] == 200 and _raw(rh, "GET", "/radio/", "")["status"] == 200, "the radio routes are mounted on the workbench's server")
	bench.server.stop()
	rh.page_path = "res://nowhere.html"
	_check(not DotRadioWorkbench.register(FakeBench.new(), rh), "a missing page file registers nothing")

