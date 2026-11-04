# Navidrome libraries and synchronization (5.4.0)

This feature branch extends the verified 5.3.1 fork release. It retains the existing player, queues, local indexing, cache and SMB publishing paths.

## Libraries

The Library tab now has a persisted library selector. All music lists every saved connected source and device music in separate source groups. Create a named library, select its connections and whether it includes device music, then rename/reconfigure/delete it from the menu. Deleting a library never deletes files or server data. Selecting a server-only profile exposes only its configured connections. The server views retrieve their own account's artists, albums, songs, genres, playlists, favourites, recent/frequent albums and radio; they never merge the local index or another server's results. Device-track SQL excludes network and HTTP rows before pagination. The existing combined indexed view is available under All music > Indexed music.

Each server view supports refresh, foreground/resume refresh and a one-minute refresh while visible. Metadata remains account-scoped and cached for five minutes; failed refreshes preserve an already loaded view with a visible synchronization error. Large song/album lists load in pages. New profiles save connection IDs, not credentials; saved connections continue using the existing secure credential store.

## Server writes

Playlist creation, renaming, deletion, adding/removing songs and drag reordering issue authenticated Subsonic mutations. Ordered membership replacement uses a single createPlaylist call with playlistId and repeated songId parameters, preserving duplicate occurrences. Writes use POST form bodies to accommodate large playlists. Existing smart/read-only playlist flags are respected. Before an edit, the current playlist is read fresh and compared with the opened snapshot; conflicts require refresh. Writes within the app are serialized per account and playlist. Lost mutation responses are surfaced instead of automatically replaying a possibly committed write. Manual refresh reconciles the result.

Subsonic has no compare-and-swap/ETag precondition for playlist edits. Another client can change a playlist between the fresh read and the write; the protocol cannot eliminate that narrow race. This implementation does not claim transactional conflict protection across clients. Offline playlist/favourite/rating edits fail visibly and are not queued as stale whole-playlist replacements.

Server favourites, ratings and radio station changes use star/unstar, setRating and radio CRUD endpoints. The player's favourite controls and playlist picker route server songs to their actual server. Local-only favourites remain for local/catalogue music. A playlist cannot contain songs from another server; such a mixed selection is rejected. Server errors and permissions are displayed. Station data comes from the selected server; no example stations are supplied.

## Playback and reporting

Preparation, recovering and ready are distinct. Old engine stop events cannot clear a newer selection's loading state. The UI only reports playing when ready. Network preparation retries recoverable transport/native initialization errors up to three attempts with short bounded backoff; authentication, missing media and unsupported-format errors are not blindly retried. Every asynchronous boundary checks the selection generation. Cancellation resets the native item before the next preparation. The full native preparation has a deadline because audioplayers' Future.wait can otherwise wait indefinitely for the native method even after its prepared-event timeout expires. AVPlayer errors include domain/code without credential-bearing URLs. Darwin timeControlStatus drives buffering and a 45-second buffering deadline. Recoverable runtime network failures have at most two reloads at the current queue position. The existing Android audio-service loading intent is retained for foreground playback; visible playing controls require ready.

Scrobbling distinguishes now-playing from playback submission. Forward listened position, excluding large seeks and paused/preparing ticks, must reach half a known track or four minutes, whichever is shorter. A session submits once. Pending submissions persist source identity, original timestamp and an account fingerprint; credentials are not copied to the journal. Failed submissions are retried on playback/resume, never sent to a changed account. Subsonic supplies no idempotency token: loss of an acknowledgement can produce an at-least-once replay, even though the local journal deduplicates the session and preserves its timestamp.

## Transfers

Transfers provides Uploads and Downloads tabs backed by the existing durable managers. Uploads preserve bytes, tags, artwork and relative folders; duplicates and final published contents are verified. Original deletion requires explicit confirmation, verified destination contents and unchanged local contents. iOS originals require original-folder access; imported picker copies are not represented as original files. Transfers show progress, speed, ETA, retry and cancellation through their existing managers. Destination choices remain device, server or both. Mobile background execution is finite and interrupted SMB retry restarts/reconciles publication, not byte-range resume. Provider downloads can require temporary per-track staging. Access SMB on a private network/VPN, not public TCP 445.

## API and verification limits

Recently played albums and server-provided play counts/metadata are displayed. Standard Subsonic has no full per-song playback-history listing endpoint. No local history is presented as complete server history. Navidrome's documented API v1 is explicitly still under design and not ready for implementation, so this release does not depend on unstable native authentication/history endpoints. This limits complete recent-track/history retrieval; scrobbling still updates the supported server state.

Physical-device background/Bluetooth tests, comparison with another player on the user's server and large live-Navidrome random-selection acceptance require that server and devices. They are not established by mock tests or a simulator. The workflow exercises actual AVPlayer WAV/MP3/FLAC streams, seeking, offline cache, delayed preparation, cancellation and repeated initialization on an iPhone simulator. Desktop source paths are shared; platform-specific success is only reported for checks actually executed. The optional proprietary Discord SDK remains excluded from Lite builds. Unsigned IPAs require signing for sideloading. Runner-generated Android fork keys differ from official and earlier temporary keys.

References consulted:
- https://www.navidrome.org/docs/developers/subsonic-api/
- https://www.subsonic.org/pages/api.jsp
- https://github.com/navidrome/navidrome/blob/master/server/subsonic/playlists.go
- https://www.navidrome.org/docs/developers/api-v1/
