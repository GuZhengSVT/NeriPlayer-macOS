# M5 Online Sources

## Modules

- `Core/Online/OnlineModels.swift`: platform-native `SongData`, collections and client contracts.
- `NeteaseClient`: official EAPI anonymous search and playable URL, WEAPI detail, playlists, daily recommendations, likes and QR login. CommonCrypto supplies AES-CBC/ECB; Security supplies raw RSA; CryptoKit supplies compatibility MD5.
- `BilibiliClient`: WBI signing, anonymous fingerprint cookies, exact multipart video identity, DASH audio, favorite folders, favorites writes and QR login.
- `YouTubeMusicClient`: WEB_REMIX bootstrap, Innertube search/browse/player, continuation paging, Cookie import, signed authentication headers and account-bound bootstrap cache.
- `YouTubeMusicSolver`: JavaScriptCore bridge for signature and throttling parameters. Bundled yt-dlp/ejs assets retain their Unlicense, ISC and MIT notices. Swift behavior is adapted from the Android project (GPL-3.0-or-later); release licensing still needs repository-wide review.
- `OnlineSearchManager`: concurrent independent platform requests, stable platform/result order, normalization and partial failure reporting.
- `PlaybackResolver` / `OnlinePlaybackCoordinator`: requested source first, title/artist/duration scoring, conservative cross-source alternatives, one runtime refresh per candidate, then source switch and bounded queue skip.

## Playback Identity

`Track.url` retains a stable `neriplayer-online` identity. `SongData` is persisted with the queue; signed CDN URLs and HTTP headers are not. The store binds resolved media URL to a generation UUID, discards late completions after stop/local selection, and uses the actual media URL for readiness/EOF checks. Startup creates the resolver before restoring a queue.

Natural EOF and errors are separate native events. Seeking after restore/refresh waits for a loaded-file event. Positive source replacement does not overwrite the original song title or NetEase lyric identity.

## Transport

NetEase and Bilibili stream through libmpv's HTTP backend. Explicit macOS HTTP proxies are read per target URL via CFNetwork; system settings are never changed. Local loads clear headers and proxy state. `User-Agent` and `Referer` use mpv's dedicated properties; other fields use its native string-list API. yt-dlp hooks are disabled because URLs are already resolved.

YouTube audio uses a loopback-only URLSession transport because a tested signed URL returned 206 to URLSession but 403 to FFmpeg on this machine. The listener binds only `127.0.0.1`, uses a fresh opaque path per load, limits connections/header bytes, fetches 512 KiB Range chunks, validates Content-Range and forwards with backpressure. It does not download or retain a whole audio file. Stop/replacement cancels connections and tasks. Only media bytes cross the loopback path; API cookies stay in Keychain.

This is a native networking adaptation, not a PoToken, entitlement or region bypass. PAC/WPAD and SOCKS-only mpv proxy configurations are not implemented. YouTube requests use the system URLSession route. Cross-platform full-byte traffic accounting and persistent media caching are not part of this implementation.

## Sessions

Credentials are isolated per platform in Keychain with device-only accessibility. Tests inject an in-memory store. Imports accept a raw Cookie header or Netscape export filtered by platform domain and expiry. Bootstrap snapshots store a SHA256 cookie fingerprint, not the Cookie header; a different account invalidates cached state. Cookies are deliberately not sent to audio CDN URLs.

QR polling is cancellable and bounded. Closing the login sheet cancels polling; authorized state must be received before login is considered successful. NetEase now uses `/st/platform/scanlogin` with the same chainId in QR content and poll headers, web request metadata, transient cookies and x-refresh-token handling; account verification must pass before committing the session to Keychain. The legacy `/login?codekey=` content was a compatibility defect corrected after a real confirmation failure. After a real 8821 confirmation rejection, macOS now obtains ydDeviceToken, sDeviceId and same-session cookies from the official page's createNEFingerprint SDK using an ephemeral WKWebView. Empty or failed device contexts abort QR preparation instead of sending an empty token; no device token is fabricated. Account access and private playlists still require valid user credentials. There is no claim that arbitrary expired Cookie imports can be silently renewed.

## Boundaries

No premium entitlement bypass, comment UI, downloads, persistent audio cache, PoToken generation, YouTube WebView fallback, complex challenge recovery, or OAuth credential collection. Bilibili's generic favorite action adds to the first created folder; removal uses favored folders reported by the service. YouTube favorite writes are unsupported. Collection detail accepts native platform IDs; Bilibili collections are favorite-folder IDs and multipart playback IDs use `BV...:page`.
