# dot-radio

A shared in-game radio station: the operator uploads MP3 and OGG tracks to the server, the server keeps one schedule (current track plus the instant it started), and every client downloads the files over HTTP and plays them seeked to where the station is. Read [docs/design.md](docs/design.md) first; it records why the clock is shared, why tracks are downloaded rather than streamed, and what is not built.

**The distributable is `addons/dot_radio/`.** `project.godot` and `examples/` exist to validate it alone. It requires dot-core (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored); everything else is duck-typed.

| Path | What |
| --- | --- |
| `dot_radio_codec.gd` | `DotRadioCodec`: MP3/OGG by magic bytes, decode to a stream, length |
| `dot_radio_library.gd` | `DotRadioLibrary`: validation, caps, storage under `user://`, JSON index |
| `dot_radio_station.gd` | `DotRadioStation`: playlist, queue, shuffle/loop, schedule, skip, requests, ratings, state file |
| `dot_radio_api.gd` | `DotRadioApi`: JSON ops, admin flag `radio`, token or identity, listener ops |
| `dot_radio_http.gd` | `DotRadioHttp`: routes on dot-core's `DotHttpServer`, off by default, token from a file only |
| `dot_radio_client.gd` | `DotRadioClient`: downloads, cache, seek, drift, volume, tune in/out, input actions |
| `dot_radio_sink*.gd` | the playback seam: `DotRadioSink` shape, `DotRadioSinkNull` (tests), `DotRadioSinkGodot` |
| `dot_radio_commands.gd` | `DotRadioCommands`: `!radio`, `!song`, `!request`, `!rate` without a console dependency |
| `web/index.html` | the admin page: one file, no build |

- The HTTP server is dot-core's `DotHttpServer`; this addon only mounts routes. Uploads are a raw-body `PUT /api/tracks/<name>`. Do not write a second server or a multipart parser here.
- Admin identity is the api's `identity` and `permit` hooks. `DotWorkbenchIdentity` (dot-workbench) fits them with `flags` set to `["radio"]`; nothing here imports it.
- Time on the wire is `position` (seconds into the track), not a timestamp: clients never need to agree with the server's wall clock.
- Nothing plays until `DotRadioClient.tune_in()` runs from a user gesture (`handle_input`, bound to the `radio_toggle` action). Never start it from `_ready`.
- Secrets (admin token, TLS key) are read from files only, never env or argv.
- The addon provides upload functionality only and ships no audio; the operator is responsible for the rights to what they broadcast. Keep that in the README.
- Validate: import, `--check-only` on every `.gd`, then `res://examples/radio_selftest.tscn` (8 sections, 143 checks), all through `heavy`. One engine line, `Failed to decode mp3 file`, is expected on stderr: it is the check that a file with MP3 magic bytes but junk inside is refused. CI is the shared dot-ci `@v1`.
