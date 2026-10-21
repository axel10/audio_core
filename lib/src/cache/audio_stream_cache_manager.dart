import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages local disk caching and LRU pruning for streamed audio tracks.
class AudioStreamCacheManager {
  static const String defaultCacheSubdir = 'audio_stream_cache';
  Directory? _cacheDir;
  final Directory? customCacheDirectory;
  final int Function()? maxCacheSizeBytesGetter;
  void Function(String cacheKey, File file)? onTrackCached;
  final Map<String, Future<File>> _activeDownloads = {};
  final Map<String, StreamCacheWriter> _activeStreamWrites = {};
  final Set<String> _pendingStreamWriteKeys = {};

  AudioStreamCacheManager({
    this.customCacheDirectory,
    this.maxCacheSizeBytesGetter,
    this.onTrackCached,
  }) {
    if (customCacheDirectory != null) {
      _cacheDir = customCacheDirectory;
    }
  }

  /// Synchronous fallback cache directory.
  Directory get cacheDirectorySync {
    if (_cacheDir != null) return _cacheDir!;
    final dir = Directory(
      p.join(Directory.systemTemp.path, defaultCacheSubdir),
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  /// Resolves the cache directory asynchronously.
  Future<Directory> getCacheDirectory() async {
    if (_cacheDir != null && await _cacheDir!.exists()) {
      return _cacheDir!;
    }
    try {
      final tempDir = await getTemporaryDirectory();
      final targetDir = Directory(p.join(tempDir.path, defaultCacheSubdir));
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      _cacheDir = targetDir;
      return targetDir;
    } catch (_) {
      final targetDir = Directory(
        p.join(Directory.systemTemp.path, defaultCacheSubdir),
      );
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      _cacheDir = targetDir;
      return targetDir;
    }
  }

  /// Derives deterministic local cache file for a cache key.
  Future<File> getCacheFile(String cacheKey) async {
    final dir = await getCacheDirectory();
    final hash = md5.convert(utf8.encode(cacheKey)).toString();
    var ext = p.extension(cacheKey);
    if (ext.contains('?')) {
      ext = ext.split('?').first;
    }
    if (ext.isEmpty || ext.length > 6 || !ext.startsWith('.')) {
      ext = '.cache';
    }
    final primaryFile = File(p.join(dir.path, '$hash$ext'));
    if (ext != '.cache' && !primaryFile.existsSync()) {
      final legacyFile = File(p.join(dir.path, '$hash.cache'));
      if (legacyFile.existsSync()) {
        return legacyFile;
      }
    }
    return primaryFile;
  }

  /// Checks if a cache key is already fully cached.
  Future<bool> isTrackCached(String cacheKey) async {
    final file = await getCacheFile(cacheKey);
    if (!await file.exists()) return false;
    final length = await file.length();
    return length > 0;
  }

  /// Updates access timestamp of a cached file for LRU tracking.
  Future<void> touchCacheFile(File file) async {
    try {
      if (await file.exists()) {
        await file.setLastModified(DateTime.now());
      }
    } catch (_) {}
  }

  /// Prunes oldest cached audio files if total cache size exceeds [limitBytes] or configured limit.
  Future<void> pruneCacheIfNeeded({int? limitBytes}) async {
    final limit = limitBytes ?? maxCacheSizeBytesGetter?.call() ?? 0;
    if (limit <= 0) return; // 0 means unlimited

    final dir = await getCacheDirectory();
    if (!await dir.exists()) return;

    final files = <File>[];
    int totalBytes = 0;

    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && !_isTransient(entity.path)) {
          files.add(entity);
          totalBytes += await entity.length();
        }
      }
    } catch (_) {}

    if (totalBytes <= limit) return;

    final stats = <File, DateTime>{};
    for (final f in files) {
      try {
        stats[f] = (await f.stat()).modified;
      } catch (_) {
        stats[f] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    files.sort(
      (a, b) => (stats[a] ?? DateTime(0)).compareTo(stats[b] ?? DateTime(0)),
    );

    // Clean down to 85% of limit to avoid frequent thrashing
    final targetBytes = (limit * 0.85).toInt();
    for (final f in files) {
      if (totalBytes <= targetBytes) break;
      try {
        final len = await f.length();
        await f.delete();
        totalBytes -= len;
        debugPrint(
          '[AudioStreamCache] Pruned cached file: ${f.path} ($len bytes)',
        );
      } catch (_) {}
    }
  }

  /// Calculates the total size of all cached audio files in bytes.
  Future<int> getTotalCacheSize() async {
    final dir = await getCacheDirectory();
    if (!await dir.exists()) return 0;
    int total = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && !_isTransient(entity.path)) {
          total += await entity.length();
        }
      }
    } catch (_) {}
    return total;
  }

  /// Whether a full download or a streaming write-back is already in flight
  /// for [cacheKey].
  ///
  /// Callers use this to avoid stacking a second upstream connection on top of
  /// a track that is already being persisted.
  bool isWriteInProgress(String cacheKey) =>
      _activeStreamWrites.containsKey(cacheKey) ||
      _pendingStreamWriteKeys.contains(cacheKey) ||
      _activeDownloads.containsKey(cacheKey);

  /// Opens a write-back session that mirrors the playback stream into the
  /// cache file, so the bytes forwarded to the player are also persisted.
  ///
  /// Returns `null` when caching is already someone else's job (already cached,
  /// another writer, or a full download in flight) or when [expectedTotal] is
  /// unknown. Callers then keep the pass-through + background prefetch path.
  Future<StreamCacheWriter?> beginStreamWrite({
    required String cacheKey,
    required int expectedTotal,
  }) async {
    if (expectedTotal <= 0) return null;
    if (isWriteInProgress(cacheKey)) return null;

    // Reserve the key synchronously: the awaits below must not let a
    // concurrent request for the same track open a second writer.
    _pendingStreamWriteKeys.add(cacheKey);
    try {
      final finalFile = await getCacheFile(cacheKey);
      if (await finalFile.exists() && await finalFile.length() > 0) {
        await touchCacheFile(finalFile);
        return null;
      }
      final partFile = File(
        '${finalFile.path}.${DateTime.now().microsecondsSinceEpoch}.part',
      );
      final writer = StreamCacheWriter._(
        cacheKey: cacheKey,
        manager: this,
        partFile: partFile,
        finalFile: finalFile,
        sink: partFile.openWrite(),
        expectedTotal: expectedTotal,
      );
      _activeStreamWrites[cacheKey] = writer;
      return writer;
    } catch (e) {
      debugPrint('[AudioStreamCache] Cannot open write-back for $cacheKey: $e');
      return null;
    } finally {
      _pendingStreamWriteKeys.remove(cacheKey);
    }
  }

  /// Removes `.part` files orphaned by an interrupted session (app killed
  /// mid-playback). Safe to call on every startup.
  Future<void> cleanupStalePartFiles({
    Duration maxAge = const Duration(hours: 1),
  }) async {
    try {
      final dir = await getCacheDirectory();
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(maxAge);
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.part')) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
            debugPrint('[AudioStreamCache] Removed stale part file: ${entity.path}');
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  static bool _isTransient(String path) =>
      path.endsWith('.tmp') || path.endsWith('.part');

  /// Ensures a remote track is fully downloaded and cached locally on disk.
  Future<File> ensureTrackCached({
    required String cacheKey,
    required String remoteUrl,
    Map<String, String>? headers,
  }) async {
    final active = _activeDownloads[cacheKey];
    if (active != null) return active;

    // The proxy is already mirroring the playback stream to disk: wait for it
    // instead of opening a second connection for the same bytes.
    final writer = _activeStreamWrites[cacheKey];
    if (writer != null) {
      final mirrored = await writer.done;
      if (mirrored != null) return mirrored;
      // The write-back was aborted (seek / client hang-up); fall through to a
      // regular download. Re-check: someone else may have claimed the key while
      // we were waiting.
      final claimed = _activeDownloads[cacheKey];
      if (claimed != null) return claimed;
    }

    final future = _downloadTrack(
      cacheKey: cacheKey,
      remoteUrl: remoteUrl,
      headers: headers,
    );
    _activeDownloads[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_activeDownloads[cacheKey], future)) {
        _activeDownloads.remove(cacheKey);
      }
    }
  }

  /// Safely parses a URL into a Uri, encoding unencoded path segments without double-encoding.
  static Uri safeParseUri(String url) {
    try {
      final parsed = Uri.parse(url);
      if (parsed.hasScheme && parsed.hasAuthority) {
        return parsed;
      }
    } catch (_) {}
    try {
      final schemeEnd = url.indexOf('://');
      if (schemeEnd > 0) {
        final scheme = url.substring(0, schemeEnd);
        final rest = url.substring(schemeEnd + 3);
        final pathStart = rest.indexOf('/');
        if (pathStart >= 0) {
          final hostPart = rest.substring(0, pathStart);
          final rawPath = rest.substring(pathStart);
          final segments = rawPath.split('/').map((seg) {
            if (seg.isEmpty) return seg;
            try {
              return Uri.encodeComponent(Uri.decodeComponent(seg));
            } catch (_) {
              return Uri.encodeComponent(seg);
            }
          }).join('/');
          return Uri.parse('$scheme://$hostPart$segments');
        }
      }
    } catch (_) {}
    return Uri.parse(Uri.encodeFull(url));
  }

  Future<File> _downloadTrack({
    required String cacheKey,
    required String remoteUrl,
    Map<String, String>? headers,
  }) async {
    final cachedFile = await getCacheFile(cacheKey);
    if (await cachedFile.exists() && await cachedFile.length() > 0) {
      await touchCacheFile(cachedFile);
      return cachedFile;
    }

    final tmpFile = File(
      '${cachedFile.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    if (await tmpFile.exists()) {
      try {
        await tmpFile.delete();
      } catch (_) {}
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..badCertificateCallback = ((cert, host, port) => true);
    try {
      final safeUri = safeParseUri(remoteUrl);
      final req = await client.getUrl(safeUri);
      headers?.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close();
      if (resp.statusCode >= 200 && resp.statusCode < 400) {
        final sink = tmpFile.openWrite();
        try {
          await for (final chunk in resp) {
            sink.add(chunk);
          }
        } finally {
          await sink.flush();
          await sink.close();
        }

        if (await tmpFile.exists() && await tmpFile.length() > 0) {
          if (await cachedFile.exists()) await cachedFile.delete();
          await tmpFile.rename(cachedFile.path);
          await touchCacheFile(cachedFile);
          await pruneCacheIfNeeded();
          onTrackCached?.call(cacheKey, cachedFile);
          return cachedFile;
        }
      }
      throw StateError('Download failed with status ${resp.statusCode}');
    } catch (e) {
      debugPrint('[AudioStreamCacheManager] Failed to download track ($remoteUrl): $e');
      rethrow;
    } finally {
      client.close();
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
    }
  }

  /// Clears all files in the cache directory.
  Future<void> clearCache() async {
    final dir = await getCacheDirectory();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }
}

/// A write-back session that mirrors an in-flight playback stream into the
/// cache file.
///
/// The proxy appends every chunk it forwards to the player into a `.part`
/// file; once the declared byte count is reached the file is renamed into
/// place. The `.part` file is therefore always a gap-free prefix starting at
/// offset 0 — a seek or hang-up simply drops it and falls back to a regular
/// download.
class StreamCacheWriter {
  StreamCacheWriter._({
    required this.cacheKey,
    required AudioStreamCacheManager manager,
    required File partFile,
    required File finalFile,
    required IOSink sink,
    required this.expectedTotal,
  })  : _manager = manager,
        _partFile = partFile,
        _finalFile = finalFile,
        _sink = sink;

  final String cacheKey;

  /// Byte size the upstream declared. The write-back only completes when
  /// exactly this many bytes were appended.
  final int expectedTotal;

  final AudioStreamCacheManager _manager;
  final File _partFile;
  final File _finalFile;
  final IOSink _sink;
  final Completer<File?> _completion = Completer<File?>();

  bool _active = true;
  bool _failed = false;
  int _written = 0;

  /// Bytes appended to the `.part` file so far.
  int get written => _written;

  /// Whether this writer still accepts chunks.
  bool get isActive => _active && !_failed;

  /// Completes with the cached file on success, or `null` when the write-back
  /// was aborted (seek, client hang-up, truncated upstream, disk error).
  Future<File?> get done => _completion.future;

  /// Appends one upstream chunk.
  ///
  /// Deliberately synchronous: flipping [isActive] and feeding chunks never
  /// interleaves an await, so a caller that stops feeding cannot race with a
  /// finalize in progress.
  void addChunk(List<int> chunk) {
    if (!isActive) return;
    try {
      _sink.add(chunk);
      _written += chunk.length;
    } catch (e) {
      debugPrint('[AudioStreamCache] Write-back failed for $cacheKey: $e');
      _failed = true;
    }
  }

  /// Finalizes the cache file.
  ///
  /// Returns `null` and discards the `.part` file when the byte count does not
  /// match [expectedTotal] — a partial file must never wear the final name,
  /// because [AudioStreamCacheManager.isTrackCached] only checks for existence.
  Future<File?> complete() async {
    if (!_active) return null;
    if (_failed || _written != expectedTotal) {
      await abort();
      return null;
    }
    _active = false;
    _release();

    try {
      await _sink.flush();
      await _sink.close();
      if (await _finalFile.exists()) await _finalFile.delete();
      await _partFile.rename(_finalFile.path);
      await _manager.touchCacheFile(_finalFile);
      await _manager.pruneCacheIfNeeded();
      _manager.onTrackCached?.call(cacheKey, _finalFile);
      if (!_completion.isCompleted) _completion.complete(_finalFile);
      return _finalFile;
    } catch (e) {
      debugPrint('[AudioStreamCache] Failed to finalize $cacheKey: $e');
      await _deletePart();
      if (!_completion.isCompleted) _completion.complete(null);
      return null;
    }
  }

  /// Drops the session, closes the sink and removes the `.part` file.
  Future<void> abort() async {
    if (!_active && _completion.isCompleted) return;
    _active = false;
    _release();
    try {
      await _sink.close();
    } catch (_) {}
    await _deletePart();
    if (!_completion.isCompleted) _completion.complete(null);
  }

  void _release() {
    if (identical(_manager._activeStreamWrites[cacheKey], this)) {
      _manager._activeStreamWrites.remove(cacheKey);
    }
  }

  Future<void> _deletePart() async {
    try {
      if (await _partFile.exists()) await _partFile.delete();
    } catch (_) {}
  }
}
