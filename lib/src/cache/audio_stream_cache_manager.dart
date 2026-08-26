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

  AudioStreamCacheManager({
    this.customCacheDirectory,
    this.maxCacheSizeBytesGetter,
  }) {
    if (customCacheDirectory != null) {
      _cacheDir = customCacheDirectory;
    }
  }

  /// Synchronous fallback cache directory.
  Directory get cacheDirectorySync {
    if (_cacheDir != null) return _cacheDir!;
    final dir = Directory(p.join(Directory.systemTemp.path, defaultCacheSubdir));
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
      final targetDir = Directory(p.join(Directory.systemTemp.path, defaultCacheSubdir));
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
    return File(p.join(dir.path, '$hash.cache'));
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
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File && !entity.path.endsWith('.tmp')) {
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
    files.sort((a, b) => (stats[a] ?? DateTime(0)).compareTo(stats[b] ?? DateTime(0)));

    // Clean down to 85% of limit to avoid frequent thrashing
    final targetBytes = (limit * 0.85).toInt();
    for (final f in files) {
      if (totalBytes <= targetBytes) break;
      try {
        final len = await f.length();
        await f.delete();
        totalBytes -= len;
        debugPrint('[AudioStreamCache] Pruned cached file: ${f.path} ($len bytes)');
      } catch (_) {}
    }
  }

  /// Calculates the total size of all cached audio files in bytes.
  Future<int> getTotalCacheSize() async {
    final dir = await getCacheDirectory();
    if (!await dir.exists()) return 0;
    int total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File && !entity.path.endsWith('.tmp')) {
          total += await entity.length();
        }
      }
    } catch (_) {}
    return total;
  }

  /// Ensures a remote track is fully downloaded and cached locally on disk.
  Future<File> ensureTrackCached({
    required String cacheKey,
    required String remoteUrl,
    Map<String, String>? headers,
  }) async {
    final cachedFile = await getCacheFile(cacheKey);
    if (await cachedFile.exists() && await cachedFile.length() > 0) {
      await touchCacheFile(cachedFile);
      return cachedFile;
    }

    final tmpFile = File('${cachedFile.path}.tmp');
    if (await tmpFile.exists()) {
      try {
        await tmpFile.delete();
      } catch (_) {}
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(remoteUrl));
      headers?.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close();
      if (resp.statusCode >= 200 && resp.statusCode < 400) {
        final sink = tmpFile.openWrite();
        await resp.pipe(sink);
        if (await tmpFile.exists() && await tmpFile.length() > 0) {
          if (await cachedFile.exists()) await cachedFile.delete();
          await tmpFile.rename(cachedFile.path);
          await touchCacheFile(cachedFile);
          await pruneCacheIfNeeded();
          return cachedFile;
        }
      }
      throw StateError('Download failed with status ${resp.statusCode}');
    } catch (e) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
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
