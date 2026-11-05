# Playback investigation and reliability changes

Baseline investigated: Mornye 5.4.1 fork, audioplayers 6.8.1 with the local audioplayers_darwin 6.5.0 fork. The existing queue, source-change serialization, gapless/AutoMix decks and system media session are retained.

## Concrete defects found

1. NetworkStorageService.resolve produced an extensionless loopback URL. Bluefire's official troubleshooting explicitly documents decoder issues with extensionless Darwin URLs. Playback URLs now preserve a safe audio suffix and continue to send the actual media MIME type. Native metadata and upload-hash readers retain their strict extensionless 48-hex loopback contract; the playback hint is explicit.
2. AudioplayersPlaybackDeck registered its cancellation completer after awaiting release. A skip during release could miss cancellation and then start an obsolete prepare. The cancellation boundary now covers release and source preparation.
3. The handler serialized source changes but an obsolete network resolve could hold that queue until its network timeout. PlaybackLoad races the obsolete request against cancellation. A dedicated small HTTP probe closes only its own client, leaving the audible stream intact.
4. Preparation launched an independent full audio-cache fill, and prefetch filled full upcoming files. These compete with AVPlayer on a slow NAS. Preparation now performs one bounded ranged prefix read, keeps up to 32 prefixes (at most 128 KiB), and reuses them for AVPlayer's small initial range probes for 30 seconds. The existing upcoming-track setting controls prefetch count. Explicit offline downloads/cache fills remain available separately.
5. The native status observer was invalidated on readyToPlay, missing failures later in an active stream. It now remains attached to that item, with identity guards and cleanup on replacement. An unknown preparation has a 15-second deadline. timeControlStatus reports native buffering.
6. Completed cache lookup only checked for nonzero length. Published temporary cache files now carry an integrity proof. Lookup verifies size and SHA-256 after restart/change and memoizes verification while file size/mtime remain unchanged. Legacy/unverified or corrupt expendable entries are discarded; permanent downloads are outside this directory.
7. The handler passed exception.toString into the playback state, and the global playback feedback displayed it. State now carries stable categories, feedback localizes them, and native diagnostics retain domain/code rather than credential-bearing NSError descriptions.
8. ReplayGain lookup used a resolved HTTP proxy URL. For saved network sources it now reads server metadata through the existing network metadata service, with a bounded timeout, instead of inspecting audio bytes through the proxy.

9. Ordinary stop in the Darwin fork seeks a retained AVPlayerItem back to zero. The source-change path called stop repeatedly, potentially waiting for a new range from an outgoing NAS stream. Track changes now pause the old stream and release it once at replacement. A deck generation guards the entire retirement/preparation interval, including cancellation before the preparation completer is installed. Because AudioPlayer.release itself calls stop, Darwin uses the supported release mode so that stop drops the item instead of seeking it. Completion in release mode also discards the ended item without seeking it. Pause/resume, Android direct output and explicit user Stop keep their intended behavior.

## Recovery boundaries

A selected network track receives at most three initial attempts with 350/700 ms backoff. Authentication, missing media and invalid responses do not retry as transient failures. Active-stream recovery is bounded separately to two reloads, preserving position. A new transport generation cancels old preparation, prefetch and backoff. After failed network attempts a connectivity restoration may retry that same current selection; a user pause/new selection supersedes it. Shuffle may skip at most two unavailable items automatically, avoiding an unbounded offline traversal of a large queue.

No public SMB exposure, fictitious Subsonic endpoint, codec migration, loss of source metadata, or full-album background download is introduced. Standard Subsonic does not offer a universal per-song change cursor: source synchronization uses genuine revision hints where supported, otherwise a bounded fallback interval. Native local scan checkpoints and cached covers remain reusable; incomplete server snapshots are never published as a complete index.

## References and verification limits

- https://github.com/bluefireteam/audioplayers/blob/main/troubleshooting.md
- Production controller tests use controlled late resolves and the real queue logic. Transport tests use the real audioplayers Dart layer with a native-channel fixture. HTTP tests use loopback Subsonic responses. AVFoundation lifecycle and iOS simulator tests run separately in macOS CI.
- The exact device-specific NSError that caused the user's original failure cannot be proven without that device/server's diagnostics. The defects above are identified in source and covered by regression tests. A physical iPhone and the user's NAS are unavailable here; no claim of complete hardware acceptance is made.
