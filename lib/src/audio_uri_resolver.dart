import 'dart:async';

/// Callback signature for resolving arbitrary raw URIs (e.g. `subsonic://...`, `webdav://...`)
/// into playable physical file paths or HTTP stream URLs.
typedef AudioUriResolver = Future<String> Function(String uri);
