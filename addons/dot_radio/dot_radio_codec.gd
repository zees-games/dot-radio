class_name DotRadioCodec
extends RefCounted

## What a byte buffer is (MP3 or OGG by magic bytes, never by file name), how long it plays, and how to make a stream of it.

const MP3 := "mp3"
const OGG := "ogg"


## "mp3", "ogg", or "" when the bytes are neither.
static func kind_of(bytes: PackedByteArray) -> String:
	if bytes.size() < 4:
		return ""
	if bytes[0] == 0x4F and bytes[1] == 0x67 and bytes[2] == 0x67 and bytes[3] == 0x53:
		return OGG
	if bytes[0] == 0x49 and bytes[1] == 0x44 and bytes[2] == 0x33:
		return MP3
	# A bare frame: 11 sync bits, and a layer other than the reserved 00.
	if bytes[0] == 0xFF and (bytes[1] & 0xE0) == 0xE0 and ((bytes[1] >> 1) & 3) != 0:
		return MP3
	return ""


static func mime(kind: String) -> String:
	return "audio/mpeg" if kind == MP3 else "audio/ogg" if kind == OGG else "application/octet-stream"


## Decodes [param bytes] into a stream; fails with CODE_PARSE when the data is not decodable audio.
static func stream_from_bytes(bytes: PackedByteArray, kind: String = "") -> DotResult:
	if kind.is_empty():
		kind = kind_of(bytes)
	if kind == MP3:
		var s := AudioStreamMP3.new()
		s.data = bytes
		if s.get_length() <= 0.0:
			return DotResult.fail(DotError.CODE_PARSE, "not decodable MP3 audio")
		return DotResult.success(s)
	if kind == OGG:
		var o := AudioStreamOggVorbis.load_from_buffer(bytes)
		if o == null or o.get_length() <= 0.0:
			return DotResult.fail(DotError.CODE_PARSE, "not decodable OGG Vorbis audio")
		return DotResult.success(o)
	return DotResult.fail(DotError.CODE_INVALID, "neither MP3 nor OGG")


## Playing time in seconds; 0 when the bytes do not decode.
static func length_of(bytes: PackedByteArray, kind: String = "") -> float:
	var res := stream_from_bytes(bytes, kind)
	return (res.value as AudioStream).get_length() if res.ok else 0.0
