# Subsonic streaming and Navidrome transfers

Changes are based on Mornye v5.3.0 (afee4332a257f1b6aeb288229eddf04ac0777b3c). The existing audioplayers Darwin fork, audio_service integration, desktop decks, queue, metadata, and transport controls remain in use.

## Playback changes

- Apple preparation requests precise timing analysis for completed local files only. Remote files no longer need a full timing index before playback. Local FLAC precision is preserved.
- Authenticated Subsonic requests still go through the existing loopback proxy. The player never receives server passwords or token URLs.
- When a server ignores a byte range on a known-length original, the proxy returns an actual partial representation, with accurate Content-Range and Content-Length. Generic binary MIME types receive the library format's audio MIME hint. JSON/XML/HTML error responses are rejected as media.
- TLS validation, explicit certificate trust, same-origin redirect restrictions, and fresh per-request salted authentication remain enabled.
- Cached progressive reads share a single fill. A cache write failure can continue through an authenticated remote range at the same byte offset.

These are concrete fixes for failure paths found in code. They do not prove that the particular reported iPhone failure is fully resolved: that requires reproduction on an iPhone with the user's server and files. The 5.4.0 integration additionally bounds complete native preparation and retries recoverable network initialization failures; see NAVIDROME_INTEGRATION.md.

## Faster loading and metadata

Album scans request at most four albums at a time. Results preserve ordering, publish incrementally, and retain the scanner's failure/cancellation behavior. Per-song metadata persists across reader/application restarts for five minutes, with explicit refresh and stale fallback on socket failures/timeouts. The metadata directory bounds cover images and metadata documents separately. Existing library scans continue to persist the library in the existing database.

Artist/album/playlist REST responses now use the bounded, account-scoped persistent metadata cache described below. Full-library startup performance still needs measurement against a large real Navidrome library.

## Automatic audio cache

Open Settings > Cache management for automatic caching, queue prefetch count (0–10), storage limit, Wi-Fi/Ethernet-only fills, offline preference, usage, and clearing. Server-track storage menus expose individual cache/remove actions. Completed files are atomically published in a dedicated application-support directory. Permanent downloads are separate and never enter automatic cleanup. Cache filenames are hashes scoped to the saved account/connection and song; credentials are not stored in the cache filenames or a cache manifest.

The current song is requested before queue prefetch. There is a foreground fill and a sequential background lane. Fully cached songs can resolve without contacting the server. In-progress files are served through the loopback proxy rather than handed to the native player as incomplete local files. Recent playback files are protected from automatic eviction. Temporary in-progress data and protected playback files can temporarily exceed the completed-cache budget. Unknown-length responses may use the ordinary remote stream while their cache fill proceeds.

Cache contents are expendable. Operating-system removal of application data is not an offline-download guarantee. Explicit permanent downloads remain the appropriate choice for music that must be retained.

## Configure Navidrome uploads

1. Add the Subsonic/Navidrome connection using existing Network storage settings.
2. Add an SMB connection to the server's music share, for example `smb://host/Music/`. Use the existing username, password, domain, and address fields. Credentials stay in Mornye's secure connection store.
3. Open the Navidrome connection and choose Music transfers in the header.
4. Select the saved SMB connection and optional music subdirectory. Select tracks, a folder/album, or a local M3U/M3U8 playlist. A folder containing playlists offers a playlist chooser; iPhone users retain the granted original-folder access for those tracks. Subsonic server playlists are also browsable and use the same persistent metadata and offline-cache actions.
5. Upload unchanged files. Folder selections preserve their relative structure; individual-file selections preserve filenames. Existing identical destination contents are adopted. Different contents are never overwritten.

SMB should be reachable on a private network or through a VPN. Do not expose TCP 445 directly to the public internet.

## Transfer guarantees and limits

Uploads reuse the existing SMB/WebDAV publishing architecture: hidden temporary file, content verification, non-overwriting publication, and verification of the final published path. A failed or interrupted transfer retains its local original. Retry retains its reserved destination. No audio transcoding, tag rewriting, or embedded-artwork rewriting occurs in this upload path.

Transfer progress, speed, remaining time, cancel, retry, and completed/failed states are available in Music transfers. The journal persists destinations and interrupted work without copying server credentials into it. Transfers continue while navigating within the running application. Transfers acquire the existing Android foreground-work and iOS finite background-work leases. They are not an unlimited OS-native background-transfer service: suspension or process termination can interrupt them, and Retry restarts/reconciles the transfer rather than promising byte-level SMB resume.

Removal of originals is opt-in per selection, with explicit confirmation. On iOS, select an original folder through the native Files picker; its security-scoped bookmark is stored in the Keychain and reopened for transfer/retry. Individual imported picker copies are never represented as deletable originals. Removal requires verified final server content and an unchanged local hash. Expired access or failed verification preserves the original.

After uploads, the client requests Subsonic startScan and polls getScanStatus. Completion schedules a refresh through the existing local-library scanner. Servers/accounts that reject these endpoints show a manual-scan message. Scan completion is distinct from verified SMB publication.

## Download destinations

Existing download-to-device and SMB download destinations remain available. The transfer page can select its SMB folder as the download destination. Files settings add “Download to both server and this device”; this preference is captured in each queued item. A verified permanent local copy is retained under the app Documents/Mornye Downloads directory, independently of the temporary staging cache.

Navidrome/Subsonic does not provide a standard upload or arbitrary server-to-server import endpoint. This implementation transfers bytes using the SMB share. Existing provider downloads may require temporary per-track local staging for metadata/finalization and upload. It does not claim that the source transfers directly to the server without involving the device.

## Verification boundaries

Automated tests cover authentication, proxy ranges, caching/offline resolution, metadata reuse, bounded album concurrency, publication/retry, deletion guards, and existing playback behavior. Live iPhone AVPlayer playback, actual user-server SMB uploads, and platform background behavior require device/server acceptance tests. A macOS host is required to build and test iOS/macOS native code.

Album and artist folders expose cache and cache-removal actions with bounded traversal and cancellation between tracks. Explicit downloads are not affected. Not included in this increment: a complete local-library bulk-action integration for every track/album/artist/playlist selection; an OS-native mobile background uploader; deletion of originals when only an imported picker copy is available; and a server-side transfer agent. These limits are explicit rather than represented by placeholder controls.

## Primary references

- [Apple: precise duration and timing](https://developer.apple.com/documentation/avfoundation/avurlassetpreferprecisedurationandtimingkey)
- [Subsonic API](https://www.subsonic.org/pages/api.jsp)
- [Navidrome: uploading music through the music directory](https://www.navidrome.org/docs/faq/)
- [Navidrome Subsonic API compatibility](https://www.navidrome.org/docs/developers/subsonic-api/)


## Delivery and validation

The source starts at upstream v5.3.0 and is versioned 5.3.1+167. The dedicated `mobile-delivery.yml` builds Android release APKs and a real unsigned iOS release IPA from the same commit. It tests WAV, MP3 and FLAC through native AVPlayer on an iPhone simulator, including authenticated proxy streaming, seeking and cached playback after disconnecting the server. Package audits verify native libraries, version, release AOT code and the embedded commit identifier; SHA-256 manifests accompany artifacts.

The clean-fork build uses the supported Lite configuration, omitting the proprietary optional Discord SDK. Android release signing uses a temporary runner-generated key and cannot update an official installation signed by another key. The unsigned IPA requires a sideloading tool to apply the user's signing identity.

Persistent Subsonic REST metadata is account-scoped and bounded to 64 MB / 256 entries, with a five-minute freshness window, forced scan refresh and stale fallback for connection failures. Authentication errors do not silently reuse stale metadata. In-flight invalidation prevents old responses repopulating a refreshed library.

The delivery workflow runs full-project Dart analysis, Flutter tests with an exported machine-readable report, Rust formatting/Clippy/tests, native simulator AVPlayer checks and release package audits. Build manifests record the exact source commit and SHA-256. Flutter split APKs add ABI offsets to the source build number: build 167 becomes Android arm64 version code 2167 and armv7 code 1167; the IPA retains build 167. Live testing against the user's SMB server and physical iPhone remains a separate acceptance check.
