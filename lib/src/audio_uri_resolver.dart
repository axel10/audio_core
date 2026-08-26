import 'dart:async';

/// Represents a resolved audio URI with optional request headers and cache identifier.
class ResolvedAudioUri {
  /// The playable remote HTTP/HTTPS URL or local file path.
  final String uri;

  /// Optional HTTP headers for authentication (e.g. Authorization, User-Agent).
  final Map<String, String>? headers;

  /// Optional cache key to uniquely identify the track (defaults to URI hash if omitted).
  final String? cacheKey;

  const ResolvedAudioUri({
    required this.uri,
    this.headers,
    this.cacheKey,
  });

  @override
  String toString() => 'ResolvedAudioUri(uri: $uri, cacheKey: $cacheKey)';
}

/// Callback signature for resolving arbitrary raw URIs (e.g. `subsonic://...`, `webdav://...`)
/// into playable physical file paths, HTTP stream URLs, or [ResolvedAudioUri] objects.
typedef AudioUriResolver = FutureOr<dynamic> Function(String rawUri);
