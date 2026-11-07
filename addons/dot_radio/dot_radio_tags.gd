class_name DotRadioTags
extends RefCounted

## Reads title, artist, album and the front cover out of an upload: ID3v2 (2.2, 2.3, 2.4) then ID3v1 for MP3, Vorbis and Opus comments for OGG. Best effort and bounded: a damaged or unknown tag gives an empty result, never an error, and nothing here reads past the buffer.

## Longest title or artist kept.
const MAX_FIELD := 200
## Tag data past this many bytes is not parsed (ID3v2 is read from the file start, the Ogg comment from the first pages).
const MAX_SCAN := 262144
## Largest cover image kept, and how far into an ID3v2 tag [method cover] looks for it.
const MAX_COVER := 524288
const MAX_COVER_SCAN := MAX_COVER + 65536


## {"title": String, "artist": String, "album": String}; any may be empty.
static func read(bytes: PackedByteArray, kind: String = "") -> Dictionary:
	if kind.is_empty():
		kind = DotRadioCodec.kind_of(bytes)
	var out := _blank()
	if kind == DotRadioCodec.MP3:
		_merge(out, _id3v2(bytes))
		if out["title"].is_empty() or out["artist"].is_empty():
			_merge(out, _id3v1(bytes))
	elif kind == DotRadioCodec.OGG:
		_merge(out, _vorbis(bytes))
	return out


## The front cover of an MP3's ID3v2 tag (APIC, or PIC in 2.2) as {"mime": "image/png" or "image/jpeg", "data": PackedByteArray}, or {} when there is none, it is not a PNG or JPEG by its magic bytes, or it is over [constant MAX_COVER]. The mime comes from the bytes, not from the tag. OGG covers are not read: Vorbis stores them base64 across page boundaries.
static func cover(bytes: PackedByteArray, kind: String = "") -> Dictionary:
	if kind.is_empty():
		kind = DotRadioCodec.kind_of(bytes)
	if kind != DotRadioCodec.MP3:
		return {}
	var found: Variant = _id3v2(bytes, true).get("cover", {})
	return found if found is Dictionary else {}


static func _blank() -> Dictionary:
	return {"title": "", "artist": "", "album": ""}


static func _merge(into: Dictionary, from: Dictionary) -> void:
	for k in ["title", "artist", "album"]:
		if str(into[k]).is_empty():
			into[k] = str(from.get(k, ""))


static func _clean(s: String) -> String:
	var t := ""
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 32 and c != 127:
			t += s[i]
	return t.strip_edges().left(MAX_FIELD)


static func _syncsafe(b: PackedByteArray, at: int) -> int:
	return ((b[at] & 0x7F) << 21) | ((b[at + 1] & 0x7F) << 14) | ((b[at + 2] & 0x7F) << 7) | (b[at + 3] & 0x7F)


static func _be(b: PackedByteArray, at: int, n: int) -> int:
	var v := 0
	for i in n:
		v = (v << 8) | b[at + i]
	return v


static func _id3v2(b: PackedByteArray, want_cover: bool = false) -> Dictionary:
	var out := _blank()
	if b.size() < 10 or b[0] != 0x49 or b[1] != 0x44 or b[2] != 0x33:
		return out
	var ver := int(b[3])
	if ver < 2 or ver > 4 or (b[6] | b[7] | b[8] | b[9]) & 0x80 != 0:
		return out
	var end := mini(10 + _syncsafe(b, 6), mini(b.size(), MAX_COVER_SCAN if want_cover else MAX_SCAN))
	var pos := 10
	if ver >= 3 and (b[5] & 0x40) != 0 and pos + 4 <= end:
		var ext := _syncsafe(b, pos) if ver == 4 else _be(b, pos, 4) + 4
		pos += ext
	var head := 6 if ver == 2 else 10
	while pos + head <= end and b[pos] != 0:
		var id := b.slice(pos, pos + (3 if ver == 2 else 4)).get_string_from_ascii()
		var size := _be(b, pos + 3, 3) if ver == 2 else (_syncsafe(b, pos + 4) if ver == 4 else _be(b, pos + 4, 4))
		var body := pos + head
		if size < 0 or body + size > end:
			break
		if want_cover:
			if (id == "APIC" or id == "PIC") and not out.has("cover"):
				var pic := _picture(b.slice(body, body + size), id == "PIC")
				if not pic.is_empty():
					out["cover"] = pic
		elif size > 1:
			var key := ""
			if id == "TIT2" or id == "TT2":
				key = "title"
			elif id == "TPE1" or id == "TP1":
				key = "artist"
			elif id == "TALB" or id == "TAL":
				key = "album"
			if not key.is_empty() and str(out[key]).is_empty():
				out[key] = _clean(_text(b.slice(body, body + size)))
		pos = body + size
	return out


# An APIC/PIC frame body: encoding, mime (3 bytes in PIC, NUL-terminated in APIC), picture type, description, image.
static func _picture(f: PackedByteArray, v22: bool) -> Dictionary:
	if f.size() < 8:
		return {}
	var enc := int(f[0])
	var at := 4
	if not v22:
		var z := f.find(0, 1)
		if z < 0:
			return {}
		at = z + 1
	at += 1
	# The description ends in one NUL byte, or two aligned ones for UTF-16.
	if enc == 1 or enc == 2:
		while at + 1 < f.size() and (f[at] != 0 or f[at + 1] != 0):
			at += 2
		at += 2
	else:
		var z2 := f.find(0, at)
		if z2 < 0:
			return {}
		at = z2 + 1
	if at >= f.size() or f.size() - at > MAX_COVER:
		return {}
	var img := f.slice(at)
	var mime := _image_mime(img)
	return {} if mime.is_empty() else {"mime": mime, "data": img}


static func _image_mime(img: PackedByteArray) -> String:
	if img.size() > 8 and img[0] == 0x89 and img[1] == 0x50 and img[2] == 0x4E and img[3] == 0x47:
		return "image/png"
	if img.size() > 4 and img[0] == 0xFF and img[1] == 0xD8 and img[2] == 0xFF:
		return "image/jpeg"
	return ""


# An ID3 text frame body: an encoding byte then the string; multiple values are separated by NULs, the first is used.
static func _text(f: PackedByteArray) -> String:
	var enc := int(f[0])
	var d := f.slice(1)
	match enc:
		0:
			var n := d.find(0)
			return _latin1(d if n < 0 else d.slice(0, n))
		3:
			var n := d.find(0)
			return (d if n < 0 else d.slice(0, n)).get_string_from_utf8()
		1, 2:
			var be := enc == 2
			var i := 0
			if d.size() >= 2 and d[0] == 0xFF and d[1] == 0xFE:
				i = 2
			elif d.size() >= 2 and d[0] == 0xFE and d[1] == 0xFF:
				i = 2
				be = true
			var s := ""
			while i + 1 < d.size():
				var c := (d[i] << 8 | d[i + 1]) if be else (d[i + 1] << 8 | d[i])
				i += 2
				if c == 0:
					break
				if c >= 0xD800 and c < 0xDC00 and i + 1 < d.size():
					var c2 := (d[i] << 8 | d[i + 1]) if be else (d[i + 1] << 8 | d[i])
					if c2 >= 0xDC00 and c2 < 0xE000:
						i += 2
						c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00)
				s += char(c)
			return s
	return ""


static func _latin1(d: PackedByteArray) -> String:
	var s := ""
	for v in d:
		s += char(v)
	return s


static func _id3v1(b: PackedByteArray) -> Dictionary:
	var out := _blank()
	var n := b.size()
	if n < 128 or b[n - 128] != 0x54 or b[n - 127] != 0x41 or b[n - 126] != 0x47:
		return out
	out["title"] = _clean(_field(b.slice(n - 125, n - 95)))
	out["artist"] = _clean(_field(b.slice(n - 95, n - 65)))
	return out


static func _field(d: PackedByteArray) -> String:
	var i := d.find(0)
	return _latin1(d if i < 0 else d.slice(0, i))


# Vorbis comment header ("\x03vorbis") or Opus ("OpusTags"), near the start of the stream.
static func _vorbis(b: PackedByteArray) -> Dictionary:
	var out := _blank()
	var head := b.slice(0, mini(b.size(), MAX_SCAN))
	var at := _find(head, "\u0003vorbis".to_utf8_buffer())
	var start := 7
	if at < 0:
		at = _find(head, "OpusTags".to_utf8_buffer())
		start = 8
	if at < 0:
		return out
	var p := at + start
	if p + 4 > head.size():
		return out
	p += 4 + _le(head, p)
	if p < 0 or p + 4 > head.size():
		return out
	var count := _le(head, p)
	p += 4
	for i in mini(count, 256):
		if p + 4 > head.size():
			break
		var len := _le(head, p)
		p += 4
		if len < 0 or p + len > head.size():
			break
		var kv := head.slice(p, p + len).get_string_from_utf8()
		p += len
		var eq := kv.find("=")
		if eq <= 0:
			continue
		var key := kv.left(eq).to_upper()
		if key == "TITLE" and str(out["title"]).is_empty():
			out["title"] = _clean(kv.substr(eq + 1))
		elif key == "ARTIST" and str(out["artist"]).is_empty():
			out["artist"] = _clean(kv.substr(eq + 1))
		elif key == "ALBUM" and str(out["album"]).is_empty():
			out["album"] = _clean(kv.substr(eq + 1))
	return out


static func _le(b: PackedByteArray, at: int) -> int:
	return b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)


static func _find(hay: PackedByteArray, needle: PackedByteArray) -> int:
	var n := needle.size()
	var first := needle[0]
	var i := hay.find(first)
	while i >= 0 and i + n <= hay.size():
		if hay.slice(i, i + n) == needle:
			return i
		i = hay.find(first, i + 1)
	return -1
