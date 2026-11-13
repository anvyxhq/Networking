# Changelog

All notable changes to this package are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- **Breaking:** Products and modules were renamed to `Anvyx*` (`AnvyxNetworkKit`) and the package now requires Swift 6.2 (Xcode 26). Update `.product(name:)` entries and `import` statements.
- **Breaking:** `APIError` cases changed: `.transport(String)` is now `.transport(URLError)`, `.unacceptableStatus(code:data:)` is now `.server(status:body:)`, `.decoding(String)` is now `.decoding(type:path:underlying:)`; new cases `.cancelled` and `.nonHTTPResponse`. Update patterns and exhaustive switches.
- **Breaking:** `ExponentialBackoffRetrier` no longer retries POST/PATCH after a timeout, a lost connection or a 500/502/504, and delays are jittered. Supply a custom `RequestRetrier` to force retries; pass `jitter: 0` for exact delays.
- **Breaking:** `curlString` is redacted by default. Use `curlString(redacting: .none)` for the full command.
- **Breaking:** `OfflineRequestQueue` persists allow-listed headers only. Pass `persistedHeaders:` to keep more and `adapters:` to `flush` to re-attach credentials.
- **Breaking:** A non-HTTP response now throws `.nonHTTPResponse` instead of counting as status 200.

### Added

- Typed errors, cancellation-safe retries, redacted logging
- Server-Sent Events (text/event-stream) parsing
- Progress-reporting download/upload via AsyncStream
- PaginatedSequence for cursor-paginated resources
- HTTP response cache (ETag / Cache-Control)
- Per-endpoint retry override
- Add ImageLoader (async remote image loader, NSCache + in-flight dedup, prefetch) + ImageCaching/DefaultImageCache + UIImageView.setImage(from:)

### Changed

- Durable offline request queue (P2)
- Multipart streaming-from-file + interceptor/multipart tests
- Rename module(s) -> Anvyx* (naming convention)

## [2.3.0] - 2026-07-02

### Added

- APIService protocol — domain service layer over APIClient

## [2.2.0] - 2026-07-02

### Added

- CURL debug logging + APIError HTTP status semantics (learned from app network layers)

## [2.1.0] - 2026-07-02

### Added

- Add HTTPTransport seam for injectable/testable networking

## [2.0.2] - 2026-07-02

_No notable changes._

## [2.0.1] - 2026-07-02

_No notable changes._

## [2.0.0] - 2026-07-02

_No notable changes._

## [1.2.0] - 2026-07-01

### Added

- Adopt iOS 17 + Observation (@Observable); DesignSystem adds Typography/fonts

## [1.1.0] - 2026-07-01

### Added

- Add RequestAdapter/RequestRetrier interceptors, BearerToken adapter, exponential backoff, MultipartFormData

## [1.0.0] - 2026-07-01

### Changed

- Initial release (SwiftUI/async-await iOS base)
