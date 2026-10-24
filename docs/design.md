# dot-radio design

## What it is

One station per server. A library of operator-uploaded tracks, a playlist, a request queue, and a schedule: which track is current and the instant it starts. Clients follow the schedule; they do not receive audio from the server in real time.

## Why a shared clock

The station is a single object, so every listener hears the same thing and chat commands (`!song`) mean the same track for everyone. The server advances the schedule (`DotRadioStation.update`); it never waits for a client.

On the wire the position is `position`, seconds into the current track as of `server_time`, negative during the gap before a track starts. Clients anchor it to their own steady clock plus half the round trip, so they never need to agree with the server's wall clock. Between tracks there is a gap (`gap_sec`, default 2 s); the next track is already chosen, so a client can fetch it during the current one and start on time.

## Why download, then play

Godot has no streaming decode of a remote MP3 or OGG, and `HTTPRequest` (the only HTTP client on web) returns whole bodies. So the client downloads the file, checks its SHA-256 against the station's metadata, caches it on disk (capped, oldest first out), builds an `AudioStreamMP3` or `AudioStreamOggVorbis` from the bytes and plays it from `position`. The next track is prefetched ahead of time. Seeking into the middle of a local file is free, which makes late joiners and drift correction cheap. The cost is that a track must arrive before it plays and is size-capped (20 MB default), which suits music-length tracks.

## Paths, not streams

The server sends no audio frames. It serves files at `GET /track/<id>` (public, ETag = hash, any origin allowed so a web build can fetch) and a small JSON schedule at `GET /now`. Streams would need a codec, a mixer and a clock on the server; files need none of that. Carrying the schedule is the client's choice: poll `/now`, or feed `DotRadioClient.apply_now` from the game's own replication.

## Layers

1. `DotRadioCodec`, `DotRadioLibrary`, `DotRadioStation`: no transport, no nodes, testable headless with a fake clock and a fake length probe.
2. `DotRadioApi`: a request dictionary in, a `DotResult` out. Listener ops need any actor; admin ops need the `radio` flag. Actors come from the admin token or from the `identity` hook; `permit` is the host's check, as in dot-workbench.
3. `DotRadioHttp`: routes on dot-core's `DotHttpServer`. Off by default, loopback by default, token from a file only, bad tokens throttled with `DotRateLimiter`. Upload is a raw-body `PUT`: `DotHttpServer` already reads bodies up to `max_body_bytes` (1 MiB by default; the radio raises it to fit a track), and a multipart parser would be a second HTTP implementation. `Expect: 100-continue` and `Range` are not supported by `DotHttpServer`. `read_timeout_sec` is raised to `upload_timeout_sec` for slow uplinks, which also lengthens the time a stalled connection holds a slot.
4. `web/index.html`: drag and drop upload with progress, library, playlist, queue, now playing, skip, delete.
5. `DotRadioClient` over a duck-typed sink: `DotRadioSinkNull` for tests, `DotRadioSinkGodot` for an `AudioStreamPlayer`. `tick()` compares the sink position with the schedule and re-seeks beyond `drift_threshold_sec`. `tune_in()` is the only way playback starts and is reached from an input event, the user gesture a browser needs to unlock audio.
6. `DotRadioCommands`: `!radio`, `!song`, `!request`, `!rate`, with no dependency on dot-console or dot-chat.

## Validation

A file is accepted when its magic bytes say MP3 (`ID3` or an MPEG frame sync) or OGG (`OggS`) whatever its name; it is within `max_track_bytes`; it decodes to a non-zero length within `max_track_seconds`; the library has room; and its id (a slug of the title or file name) is free. Writes go to `user://` and call `DotWeb.sync_filesystem()`.

## Workbench

dot-workbench has one page and no page registry, so there is nothing to register with. `DotRadioHttp.mount(server, "/radio")` puts the whole radio on any `DotHttpServer`, including the workbench's, and `DotWorkbenchIdentity` fits the identity hooks by duck typing. A tab inside the workbench page needs a page-contribution seam in dot-workbench first.

## Not built

- A listener-side UI (now-playing HUD, volume slider); the client exposes signals and `describe()`.
- Replicating the schedule over dot-net.
- Player requests and ratings over HTTP; they go through the game's server-side commands into `DotRadioApi`.
- Reading ID3 or Vorbis tags for title and artist; the admin types them.
- HTTP `Range`, resumable or chunked upload, `Expect: 100-continue`.
- Crossfade and gain normalisation.
- Persisting volume and mute (belongs in dot-settings).
- A shared admin-identity gate in dot-core: the radio reuses dot-workbench's hooks instead of copying them.
