# Existing music sources (5.4.1)

The original 5.3.1 streaming UI/player/navigation was restored from `b21b5494263df527a097f87f51fefdc1eb56466a`. Custom library profiles, management pages and alternate library screens introduced afterwards were removed. The one additional library control chooses Local, an existing saved connection, or All libraries. No server library is created. Existing secure connection settings remain authoritative.

Songs, Albums, Artists, search, album details and folders use the original index/database and original screens, with connection filtering before SQL grouping and pagination. Indexing reads original server metadata and artwork, never copies audio to another server. Connection IDs namespace song and album identities. Server labels distinguish equal titles in the combined view. Device downloads and local files remain independent.

Selecting a saved Subsonic connection indexes its existing catalogue. Foreground refresh checks scan revisions each minute, uses a five minute fallback for compatible servers without scan revisions, and retains cached metadata during outages. Explicit refresh rechecks connections and server state. Password/account changes retire only the previous account's cached metadata. Other connected services and local library settings retain their existing purpose.

The original playlist UI now reads server playlists and routes create, add, remove, reorder, rename and delete to authenticated Subsonic writes. Server snapshots stay outside local collection persistence and local backups. Repeated playlist positions remain distinct. Fresh revision checks reject conflicting external edits. Server changes are reloaded on mutation and periodically in the foreground; an unavailable server retains its last in-memory playlist snapshot.

Home's existing Recent area merges real server last-played songs with independent local recents, applying the chosen source. Navidrome exposes `played` on album songs: recent albums are read in batches of four and only songs with real timestamps are listed, deduplicated per account/song. Compatible servers exposing only album timestamps show recent albums instead. This is a latest-played view, not a complete chronological play-event archive. The original player observes elapsed listening and submits a scrobble after half the duration (maximum four minutes), once per listening session. Pausing or seeking does not count as extra listening. Durable, account-bound pending scrobbles retain their original timestamp on retry. Subsonic offers no idempotency key if a server accepts a write but its acknowledgement is lost.

Server radio stations appear in the existing Playlists page, using the original player. Servers without that endpoint simply omit the section.

Explicit Upload opens the existing Music transfers page. Navidrome has no standard Subsonic upload endpoint. Files go unchanged to the configured music share through the existing SMB transfer engine, with duplicate checks, verified completion, retry/resume, progress and scan/refresh requests. Local-original deletion remains opt-in, confirmed and conditional on server-side verification. Use SMB through a private network or VPN. Offline Download remains a separate action and never automatically uploads a downloaded song back into the server.

Primary API references: https://www.navidrome.org/docs/developers/subsonic-api/ and https://www.subsonic.org/pages/api.jsp . The unstable native API is not required.

Validation results and exact source/package hashes are recorded in the delivery report. A generated unsigned IPA requires the user's normal signing/sideloading process. Runtime checks on an actual iPhone and the user's SMB share must be reported separately from unit/API/package verification.
