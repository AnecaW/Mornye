# Native iPhone presentation

Base: official `mornyeapp/Mornye` 5.3.1, commit
`b37621c931e4891d0bc8d7588595a406e633b71f`.

This branch replaces the visible iPhone hierarchy with SwiftUI. It keeps the
shared Flutter engine as a nonvisual runtime for the existing controllers and
plugins. It is not a rewrite of the backend in Swift. Rust, application services,
providers, controllers, and third-party plugin sources remain unchanged.

Native screens: welcome, Listen, Library with songs/albums/artists, collection,
provider search, playlists and favorites, downloads, playback settings,
extension store and configuration/account forms, Now Playing,
queue, synced lyrics, track details, audio output picker. Apple system navigation and controls adopt Liquid
Glass on iOS 26+. iOS 16–25 use the standard system materials.

## Preview scope

This is an initial native presentation, **not yet feature parity with every
screen in the cross-platform application**. In particular,
advanced lyrics editing/translation, server configuration, Mornye Link pairing, recognition, statistics,
concerts, full metadata editing and advanced settings still need native screens.
Existing backend implementations and saved data for these remain in the source.
Do not replace a production installation without validating the workflows you
use. The branch is separate from the fork's main branch.

The backend-identity CI step verifies the listed implementation directories
against the official base. This proves source identity; it does not substitute
for device playback, background operation and download testing.

## Build

`.github/workflows/native-iphone.yml` builds with the existing `xcode-27` runner,
audits the Rust framework and uploads an unsigned IPA plus SHA-256 checksum.
A successful build publishes a GitHub prerelease. Unsigned IPAs require signing
for installation; no Apple signing credentials are embedded.

If the repository has `DISCORD_MOBILE_SDK_PASSPHRASE`, the workflow stages the
official encrypted Discord SDK. Without it, the upstream podspec's normal
SDK-absent behavior applies; Discord Social SDK features are not available.

No claim of simulator/device validation is made merely by a successful build.
