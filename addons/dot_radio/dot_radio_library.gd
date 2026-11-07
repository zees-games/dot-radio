class_name DotRadioLibrary
extends RefCounted

## The operator's uploaded tracks: validated by magic bytes, size and decodability, stored under [member root] with a JSON index.

signal track_added(track: Dictionary)
signal track_removed(id: String)

const CHANNEL := "radio"
const INDEX := "library.json"

var root := "user://radio"
var max_track_bytes := 20 * 1024 * 1024
var max_tracks := 500
var max_total_bytes := 1024 * 1024 * 1024
var max_track_seconds := 3600.0
## Callable(bytes, kind) -> seconds; replaceable so a test or a host with its own decoder need not decode.
var probe: Callable = Callable()
## Fill a missing title, artist or album from the file's ID3 or Vorbis tags, and keep an ID3 cover image.
var read_tags := true

## id -> track Dictionary {id, title, artist, album, cover (mime or ""), kind, size, sha256, duration, added_at, added_by}.
var _tracks: Dictionary = {}


## Reads the index; tracks whose file went missing are dropped with a WARN.
func load_index() -> DotResult:
	_tracks.clear()
	var path := root.path_join(INDEX)
	if not FileAccess.file_exists(path):
		return DotResult.success(0)
	var doc := DotPaths.read_json(path)
	if not doc.ok:
		return doc.wrap("radio library index")
	var rows: Variant = (doc.value as Dictionary).get("tracks", []) if doc.value is Dictionary else []
	if not (rows is Array):
		return DotResult.fail(DotError.CODE_PARSE, "library index has no track list", path)
	for row in rows:
		if not (row is Dictionary) or not row.has("id") or not row.has("kind"):
			continue
		var id := str(row["id"])
		if not FileAccess.file_exists(path_of(id, str(row["kind"]))):
			DotLog.warn(CHANNEL, "track file missing; dropped from the library", {"id": id})
			continue
		_tracks[id] = row
	return DotResult.success(_tracks.size())


## Validates and stores one upload. Value on success: the track Dictionary.
## [param meta] may carry `title`, `artist`, `album` and `id` (slugified). Missing ones are read from the file's own tags ([DotRadioTags]); the file name is the last fallback title. The default id comes from the typed title or the file name, never from a tag, so the same upload gets the same id with or without tags.
func add(file_name: String, bytes: PackedByteArray, meta: Dictionary = {}, by: String = "") -> DotResult:
	if bytes.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "empty upload")
	if bytes.size() > max_track_bytes:
		return DotResult.fail(DotError.CODE_INVALID, "track is %d bytes; the limit is %d" % [bytes.size(), max_track_bytes])
	var kind := DotRadioCodec.kind_of(bytes)
	if kind.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "only MP3 and OGG files are accepted")
	var title := str(meta.get("title", "")).strip_edges()
	var artist := str(meta.get("artist", "")).strip_edges()
	var album := str(meta.get("album", "")).strip_edges()
	if title.is_empty():
		title = file_name.get_file().get_basename().strip_edges()
	var id := DotPaths.slugify(str(meta.get("id", title)), 64)
	var tags := DotRadioTags.read(bytes, kind) if read_tags else {}
	if str(meta.get("title", "")).strip_edges().is_empty() and not str(tags.get("title", "")).is_empty():
		title = tags["title"]
	if artist.is_empty():
		artist = str(tags.get("artist", ""))
	if album.is_empty():
		album = str(tags.get("album", ""))
	var pic: Dictionary = DotRadioTags.cover(bytes, kind) if read_tags else {}
	if id.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "the track needs a name with letters or digits")
	if _tracks.has(id):
		return DotResult.fail(DotError.CODE_CONFLICT, "a track called '%s' already exists" % id)
	if _tracks.size() >= max_tracks:
		return DotResult.fail(DotError.CODE_QUOTA, "the library holds %d tracks already" % max_tracks)
	if total_bytes() + bytes.size() > max_total_bytes:
		return DotResult.fail(DotError.CODE_QUOTA, "the library is full")
	var seconds := probe.call(bytes, kind) if probe.is_valid() else DotRadioCodec.length_of(bytes, kind)
	if float(seconds) <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "the file does not decode as %s audio" % kind.to_upper())
	if float(seconds) > max_track_seconds:
		return DotResult.fail(DotError.CODE_INVALID, "track is %d s long; the limit is %d s" % [int(seconds), int(max_track_seconds)])
	var made := DotPaths.ensure_dir(root.path_join("tracks"))
	if not made.ok:
		return made
	var f := FileAccess.open(path_of(id, kind), FileAccess.WRITE)
	if f == null:
		return DotResult.fail(DotError.CODE_IO, "cannot write the track file", error_string(FileAccess.get_open_error()))
	f.store_buffer(bytes)
	f.close()
	var cover_mime := ""
	if not pic.is_empty():
		cover_mime = str(pic["mime"])
		var cf := FileAccess.open(cover_path(id, cover_mime), FileAccess.WRITE) if DotPaths.ensure_dir(root.path_join("covers")).ok else null
		if cf == null:
			cover_mime = ""
		else:
			cf.store_buffer(pic["data"])
			cf.close()
	var track := {
		"id": id, "title": title, "artist": artist, "album": album, "cover": cover_mime, "kind": kind,
		"size": bytes.size(), "sha256": DotHash.sha256_bytes(bytes), "duration": snappedf(float(seconds), 0.001),
		"added_at": int(Time.get_unix_time_from_system()), "added_by": by,
	}
	_tracks[id] = track
	var saved := _save_index()
	if not saved.ok:
		_tracks.erase(id)
		DirAccess.remove_absolute(path_of(id, kind))
		if not cover_mime.is_empty():
			DirAccess.remove_absolute(cover_path(id, cover_mime))
		return saved
	DotLog.info(CHANNEL, "track added", {"id": id, "kind": kind, "bytes": bytes.size(), "by": by})
	track_added.emit(track.duplicate())
	return DotResult.success(track.duplicate())


func remove(id: String) -> DotResult:
	if not _tracks.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "no track '%s'" % id)
	var track: Dictionary = _tracks[id]
	_tracks.erase(id)
	DirAccess.remove_absolute(path_of(id, str(track["kind"])))
	if not str(track.get("cover", "")).is_empty():
		DirAccess.remove_absolute(cover_path(id, str(track["cover"])))
	var saved := _save_index()
	DotLog.info(CHANNEL, "track removed", {"id": id})
	track_removed.emit(id)
	return saved


## Changes the title, artist and album only; the id and the file never change.
func update(id: String, fields: Dictionary) -> DotResult:
	if not _tracks.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "no track '%s'" % id)
	for k in ["title", "artist", "album"]:
		if fields.has(k):
			var v := str(fields[k]).strip_edges()
			if k == "title" and v.is_empty():
				return DotResult.fail(DotError.CODE_INVALID, "the title cannot be empty")
			(_tracks[id] as Dictionary)[k] = v
	var saved := _save_index()
	return saved if not saved.ok else DotResult.success((_tracks[id] as Dictionary).duplicate())


func has(id: String) -> bool:
	return _tracks.has(id)


## A copy of one track's metadata, or {}.
func get_track(id: String) -> Dictionary:
	return (_tracks[id] as Dictionary).duplicate() if _tracks.has(id) else {}


func ids() -> PackedStringArray:
	return PackedStringArray(_tracks.keys())


## Copies of every track in upload order.
func list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _tracks:
		out.append((_tracks[id] as Dictionary).duplicate())
	return out


func total_bytes() -> int:
	var n := 0
	for id in _tracks:
		n += int(_tracks[id]["size"])
	return n


func path_of(id: String, kind: String = "") -> String:
	if kind.is_empty() and _tracks.has(id):
		kind = str(_tracks[id]["kind"])
	return root.path_join("tracks").path_join("%s.%s" % [id, kind])


func cover_path(id: String, mime: String) -> String:
	return root.path_join("covers").path_join("%s.%s" % [id, "png" if mime == "image/png" else "jpg"])


## {"mime", "data"} of a track's cover image, or a failure when it has none.
func read_cover(id: String) -> DotResult:
	var mime := str(get_track(id).get("cover", ""))
	if mime.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "track '%s' has no cover" % id)
	var bytes := DotPaths.read_bytes(cover_path(id, mime))
	return DotResult.success({"mime": mime, "data": bytes.value}) if bytes.ok else bytes


func read_bytes(id: String) -> DotResult:
	if not _tracks.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "no track '%s'" % id)
	return DotPaths.read_bytes(path_of(id))


func describe() -> Dictionary:
	return {"root": root, "tracks": _tracks.size(), "bytes": total_bytes(), "limits": {"track_bytes": max_track_bytes, "tracks": max_tracks, "total_bytes": max_total_bytes}}


func _save_index() -> DotResult:
	var made := DotPaths.ensure_dir(root)
	if not made.ok:
		return made
	var f := FileAccess.open(root.path_join(INDEX), FileAccess.WRITE)
	if f == null:
		return DotResult.fail(DotError.CODE_IO, "cannot write the library index", error_string(FileAccess.get_open_error()))
	f.store_string(JSON.stringify({"version": 1, "tracks": _tracks.values()}, "\t"))
	f.close()
	DotWeb.sync_filesystem()
	return DotResult.success()
