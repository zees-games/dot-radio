# dot-radio

An in-game radio for a game server. The operator uploads MP3 and OGG tracks through a small admin page (or the JSON API); the server plays them as one station, and every connected player who tunes in hears the same track at the same point. See [docs/design.md](docs/design.md).

**Licensing: this addon only provides upload functionality. It ships no audio and does not supply, license or check the rights to any music. Operators supply their own audio and are responsible for having the right to broadcast it.**

## Server

```gdscript
var radio := DotRadioHttp.new()
radio.start_from_config(DotRadioHttp.read_config())   # the radio: block of cfg/server.yml
# in _process:
radio.poll()
```

```yaml
radio:
  enabled: true            # off by default
  bind: 127.0.0.1          # loopback unless a proxy or TLS is in front
  port: 8791
  token_file: /etc/dot/radio.token   # the admin token lives in a file, never in the yml, env or argv
  max_track_mb: 20
  upload_timeout_sec: 120
```

Open `http://127.0.0.1:8791/`, paste the token, drop files. Admin routes need `Authorization: Bearer <token>`.

- public: `GET /now`, `GET /tracks`, `GET /track/<id>`
- admin: `POST /api` with `{"op": ...}`, `GET|POST /api/<op>`, `PUT /api/tracks/<file name>?title=&artist=` (raw body), `DELETE /api/tracks/<id>`

```bash
curl -T song.mp3 -H "Authorization: Bearer $(cat radio.token)" "http://127.0.0.1:8791/api/tracks/song.mp3?title=Song"
```

Ops: `now tracks playlist request rate` for listeners; `upload delete edit reorder playlist_add playlist_remove queue dequeue clear_queue skip mode start stop` for admins.

To share another `DotHttpServer` (such as the workbench's) instead of opening a second port: `radio.mount(server, "/radio")`.

## Client

```gdscript
var radio := DotRadioClient.new()
radio.base_url = "http://server:8791"
radio.sink = DotRadioSinkGodot.new()   # then radio.sink.attach(self)
add_child(radio)
```

Playback starts only when the player presses the `radio_toggle` key (default F8; `radio_mute` F9, `radio_volume_up` and `radio_volume_down` Page Up and Page Down). The actions are added to the InputMap only when the project has not defined them, so they can be rebound like any other. `DotRadioCommands` gives `!radio`, `!song`, `!request <title>` and `!rate up|down` to any command registry with `add_command(name, help, fn)`.

Web builds work: files are fetched with `HTTPRequest`, and the public routes allow any origin.

## Test

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
godot --headless --path . --import
godot --headless --path . res://examples/radio_selftest.tscn
```

The two files in `examples/fixtures/` are sine tones generated for the tests; they carry no licence concerns.

MIT licensed.
