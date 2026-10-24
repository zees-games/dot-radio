class_name DotRadioCommands
extends RefCounted

## Chat-style commands (!radio, !song, !request, !rate) over a client and a server call, with no dependency on dot-console or dot-chat.
##
## [method execute] takes one line and returns the reply text. [method register] hands the commands to anything that looks like
## a registry: `add_command(name, help, fn)` (dot-console's local console) or `register_command(name, fn)`.

const CHANNEL := "radio"
const COMMANDS := {
	"radio": "!radio [on|off|up|down|mute|0-100]: tune in or out, or set the volume",
	"song": "!song: what is playing",
	"request": "!request <title>: queue a track",
	"rate": "!rate up|down: rate the current track",
}
const ALIASES := {"like": "rate up", "dislike": "rate down"}

var client: DotRadioClient
## Callable(request: Dictionary) -> DotResult, awaitable: the game's way of reaching the server's [DotRadioApi] as this player.
var send: Callable = Callable()
## Local shortcut for a listen server or a test: used when [member send] is not set.
var api: DotRadioApi
var actor: Variant = ""
var prefix := "!"


## Value of the reply for a line like "!song" or "request sunrise"; "" when the line is not a radio command.
func execute(line: String) -> String:
	var text := line.strip_edges()
	if text.begins_with(prefix):
		text = text.substr(prefix.length())
	var parts := text.split(" ", false, 1)
	if parts.is_empty():
		return ""
	var name := parts[0].to_lower()
	var args := parts[1].strip_edges() if parts.size() > 1 else ""
	if ALIASES.has(name):
		return await execute(ALIASES[name])
	match name:
		"radio": return _radio(args)
		"song": return _song()
		"request": return await _request(args)
		"rate": return await _rate(args)
	return ""


## Registers every command with [param registrar]; returns how many it took.
func register(registrar: Object) -> int:
	var n := 0
	for name in COMMANDS:
		var fn := func(args: Variant = "") -> String: return await execute("%s %s" % [name, " ".join(args) if args is Array or args is PackedStringArray else str(args)])
		if registrar.has_method("add_command"):
			registrar.call("add_command", StringName(name), COMMANDS[name], fn)
		elif registrar.has_method("register_command"):
			registrar.call("register_command", name, fn)
		else:
			continue
		n += 1
	return n


func _radio(args: String) -> String:
	match args.to_lower():
		"", "toggle":
			if client.tuned:
				client.tune_out()
			else:
				client.tune_in()
		"on", "in": client.tune_in()
		"off", "out": client.tune_out()
		"up": client.volume_up()
		"down": client.volume_down()
		"mute": client.muted = not client.muted
		_:
			if not args.is_valid_int():
				return COMMANDS["radio"]
			client.volume = clampf(float(args.to_int()) / 100.0, 0.0, 1.0)
	return "Radio %s, volume %d%%%s" % ["on" if client.tuned else "off", roundi(client.volume * 100.0), " (muted)" if client.muted else ""]


func _song() -> String:
	var now := client.now_playing()
	if str(now.get("id", "")).is_empty():
		return "The radio is quiet."
	var artist := str(now.get("artist", ""))
	var r: Variant = now.get("rating", {})
	return "Now playing: %s%s%s" % [now["title"], " by " + artist if not artist.is_empty() else "",
		" (+%d/-%d)" % [r["up"], r["down"]] if r is Dictionary else ""]


func _request(args: String) -> String:
	if args.is_empty():
		return COMMANDS["request"]
	var listing := await _call({"op": "tracks"})
	if not listing.ok:
		return listing.error.message
	var needle := args.to_lower()
	var hit := ""
	for t in listing.value["tracks"]:
		if str(t["id"]) == needle or str(t["title"]).to_lower() == needle:
			hit = t["id"]
			break
		if hit.is_empty() and str(t["title"]).to_lower().contains(needle):
			hit = t["id"]
	if hit.is_empty():
		return "No track matches '%s'." % args
	var res := await _call({"op": "request", "id": hit})
	return "Queued '%s'." % hit if res.ok else res.error.message


func _rate(args: String) -> String:
	var v := 1 if args.to_lower() in ["up", "+", "+1"] else -1 if args.to_lower() in ["down", "-", "-1"] else 0
	if v == 0:
		return COMMANDS["rate"]
	var res := await _call({"op": "rate", "value": v, "id": str(client.now_playing().get("id", ""))})
	return "Thanks (+%d/-%d)." % [res.value["up"], res.value["down"]] if res.ok else res.error.message


func _call(req: Dictionary) -> DotResult:
	if send.is_valid():
		return await send.call(req)
	if api != null:
		return api.handle(actor, req)
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "no server connection for the radio")
