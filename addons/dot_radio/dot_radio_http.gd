class_name DotRadioHttp
extends RefCounted

## Mounts a DotRadioApi on a DotHttpServer: the admin page, bearer-token routes, and the public now-playing and track-file routes clients use. Off by default.
##
## Public (no token, CORS open): GET /now, /tracks, /track/<id>. Admin (Bearer token): POST /api (JSON envelope),
## GET /api/<op>, POST /api/<op>, PUT /api/tracks/<name> (raw body, ?title=&artist=), DELETE /api/tracks/<id>.
## [member base] puts every route under a prefix, so the radio can share a server (the workbench's) with other pages.

const CHANNEL := "radio"
const PAGE := "res://addons/dot_radio/web/index.html"
const CSP := "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"

var api: DotRadioApi
var server := DotHttpServer.new()
var base := ""
var page_path := PAGE
## Bad tokens per address: `rate` tokens a second, `burst` in a row, then 429.
var failures := DotRateLimiter.new(0.1, 5.0)

var _page := ""
var _mounted := false


func _init(p_api: DotRadioApi = null) -> void:
	api = p_api if p_api != null else DotRadioApi.new()


## Reads the `radio:` block of cfg/server.yml (defaults when absent).
static func read_config(path: String = "res://cfg/server.yml") -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var res := DotYaml.parse_file(path)
	if not res.ok or not (res.value is Dictionary):
		return {}
	var block: Variant = (res.value as Dictionary).get("radio", {})
	return block if block is Dictionary else {}


## Adds the routes to [param on], any DotHttpServer, under [param prefix] (e.g. "/radio"). The server is not started.
func mount(on: DotHttpServer, prefix: String = "") -> void:
	base = prefix.rstrip("/")
	server = on
	_load_page()
	on.max_body_bytes = maxi(on.max_body_bytes, api.library.max_track_bytes + 4096)
	if not base.is_empty():
		on.route("GET", base, _on_slash)
	on.route("GET", base + "/", _on_page)
	on.route("GET", base + "/index.html", _on_page)
	on.route("GET", base + "/now", _on_now)
	on.route("GET", base + "/tracks", _on_tracks)
	on.route_prefix("GET", base + "/track", _on_file)
	on.route("POST", base + "/api", _on_envelope)
	for m in ["GET", "POST", "PUT", "DELETE"]:
		on.route_prefix(m, base + "/api", _on_rest)
	_mounted = true


## Starts the HTTP side from the `radio:` block. Disabled (the default) is a success that opens nothing.
## The admin token is read from `token_file` only; there is no environment or command-line path for it.
func start_from_config(cfg: Dictionary) -> DotResult:
	if not bool(cfg.get("enabled", false)):
		return DotResult.success(0)
	var token_file := str(cfg.get("token_file", ""))
	if not token_file.is_empty():
		var tok := DotHttpServer.read_secret_file(token_file)
		if not tok.ok:
			return tok.wrap("radio token")
		api.set_admin_token(tok.value)
	elif not api.identity.is_valid():
		return DotResult.fail(DotError.CODE_INVALID, "radio enabled with no token_file and no identity; refusing to start")
	if cfg.has("library_dir"):
		api.library.root = str(cfg["library_dir"])
	if cfg.has("max_track_mb"):
		api.library.max_track_bytes = int(float(cfg["max_track_mb"]) * 1048576)
	var loaded := api.library.load_index()
	if not loaded.ok:
		return loaded.wrap("radio library")
	if api.station.state_path.is_empty():
		api.station.state_path = api.library.root.path_join("station.json")
	api.station.load_state()
	if not _mounted:
		mount(server, str(cfg.get("base", "")))
	server.read_timeout_sec = float(cfg.get("upload_timeout_sec", 120.0))
	var tls: Dictionary = cfg.get("tls", {}) if cfg.get("tls", {}) is Dictionary else {}
	var native := str(tls.get("mode", "proxy")) == "native"
	var res := server.start(int(cfg.get("port", 8791)), str(cfg.get("bind", DotHttpServer.LOOPBACK)),
		str(tls.get("cert", "")) if native else "", str(tls.get("key", "")) if native else "")
	if res.ok and bool(cfg.get("autostart", true)):
		api.station.start()
	return res


## Call from the host's _process; also moves the station's schedule on.
func poll() -> void:
	server.poll()
	api.update()


func stop() -> void:
	server.stop()


func describe() -> Dictionary:
	return {"server": server.describe(), "base": base, "page_loaded": not _page.is_empty(), "library": api.library.describe(), "station": api.station.describe()}


func _load_page() -> void:
	_page = FileAccess.get_file_as_string(page_path) if FileAccess.file_exists(page_path) else ""
	if _page.is_empty():
		DotLog.warn(CHANNEL, "radio page missing; the API still works", {"path": page_path})


func _on_page(_req: DotHttpRequest) -> DotHttpResponse:
	if _page.is_empty():
		return DotHttpResponse.error(404, "no page installed")
	var r := DotHttpResponse.html(_page)
	r.headers["Cache-Control"] = "no-store"
	r.headers["Content-Security-Policy"] = CSP
	r.headers["Referrer-Policy"] = "no-referrer"
	return r


func _on_slash(_req: DotHttpRequest) -> DotHttpResponse:
	var moved := DotHttpResponse.make(301)
	moved.headers["Location"] = base + "/"
	return moved


func _on_now(_req: DotHttpRequest) -> DotHttpResponse:
	return _public(DotHttpResponse.json(api.station.now_playing()), true)


func _on_tracks(_req: DotHttpRequest) -> DotHttpResponse:
	return _public(DotHttpResponse.json(api.tracks_view()), true)


func _on_file(req: DotHttpRequest) -> DotHttpResponse:
	var id := req.rest
	if not api.library.has(id):
		return _public(DotHttpResponse.error(404), false)
	var track := api.library.get_track(id)
	var bytes := api.library.read_bytes(id)
	if not bytes.ok:
		return _public(DotHttpResponse.error(500), false)
	var r := DotHttpResponse.make(200, bytes.value, DotRadioCodec.mime(str(track["kind"])))
	r.headers["ETag"] = '"%s"' % track["sha256"]
	r.headers["Cache-Control"] = "public, max-age=3600"
	return _public(r, false)


func _on_envelope(req: DotHttpRequest) -> DotHttpResponse:
	var auth: Variant = _gate(req)
	if auth is DotHttpResponse:
		return auth
	var body := req.json_body()
	if not body.ok or not (body.value is Dictionary):
		return _reply(DotResult.fail(DotError.CODE_INVALID, "body must be a JSON object"))
	return _reply(api.handle(auth.value, body.value))


func _on_rest(req: DotHttpRequest) -> DotHttpResponse:
	var auth: Variant = _gate(req)
	if auth is DotHttpResponse:
		return auth
	var seg := PackedStringArray()
	for s in req.rest.split("/", false):
		seg.append(s)
	if seg.is_empty():
		return DotHttpResponse.error(404)
	match req.method:
		"GET":
			return _reply(api.handle(auth.value, {"op": seg[0]}))
		"PUT":
			if seg[0] != "tracks" or seg.size() < 2:
				return _reply(DotResult.fail(DotError.CODE_INVALID, "PUT /api/tracks/<file name> with the audio as the body"))
			var name := "/".join(seg.slice(1))
			return _reply(api.upload_bytes(auth.value, name, req.body, {"title": str(req.query.get("title", "")), "artist": str(req.query.get("artist", ""))}))
		"DELETE":
			if seg[0] != "tracks" or seg.size() != 2:
				return DotHttpResponse.error(404)
			return _reply(api.handle(auth.value, {"op": "delete", "id": seg[1]}))
	var op: Dictionary = {}
	if not req.body.is_empty():
		var parsed := req.json_body()
		if not parsed.ok or not (parsed.value is Dictionary):
			return _reply(DotResult.fail(DotError.CODE_INVALID, "body must be a JSON object"))
		op = parsed.value
	op["op"] = seg[0]
	return _reply(api.handle(auth.value, op))


# Returns a refusal response, or the authenticate() result when the token is good.
func _gate(req: DotHttpRequest) -> Variant:
	var addr := req.remote_address
	if not failures.peek(addr):
		var r := DotHttpResponse.json(DotRadioApi.to_reply(DotResult.fail(DotError.CODE_RATE_LIMITED, "too many failed tokens; try again later")), 429)
		r.headers["Retry-After"] = str(int(ceil(failures.retry_after(addr))))
		return r
	var auth := api.authenticate(req.bearer_token())
	if auth.ok:
		failures.reset(addr)
		return auth
	failures.allow(addr)
	var r := DotHttpResponse.json(DotRadioApi.to_reply(auth), 401)
	r.headers["WWW-Authenticate"] = "Bearer"
	return r


func _reply(res: DotResult) -> DotHttpResponse:
	var status := 200
	if not res.ok:
		match res.error.code:
			DotError.CODE_AUTH: status = 401
			DotError.CODE_FORBIDDEN: status = 403
			DotError.CODE_CONFLICT: status = 409
			DotError.CODE_QUOTA: status = 413
			DotError.CODE_RATE_LIMITED: status = 429
			DotError.CODE_INTERNAL, DotError.CODE_IO: status = 500
			_: status = 400
	var r := DotHttpResponse.json(DotRadioApi.to_reply(res), status)
	r.headers["Cache-Control"] = "no-store"
	return r


# Clients may be a web build on another origin, so the public reads allow any origin; nothing here is credentialed.
func _public(r: DotHttpResponse, no_store: bool) -> DotHttpResponse:
	r.headers["Access-Control-Allow-Origin"] = "*"
	if no_store:
		r.headers["Cache-Control"] = "no-store"
	return r
