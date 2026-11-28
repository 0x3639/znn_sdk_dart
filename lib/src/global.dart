import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

export 'package:logging/logging.dart' show Level;

const znnSdkVersion = '1.2.0';
const znnRootDirectory = 'znn';

class ZnnPaths {
  Directory main;
  Directory wallet;
  Directory cache;

  ZnnPaths({
    required this.main,
    required this.wallet,
    required this.cache,
  });
}

ZnnPaths? _znnPaths;
String Function() _operatingSystemProvider = () => Platform.operatingSystem;
Map<String, String> Function() _environmentProvider =
    () => Platform.environment;

/// Configures the SDK's active [ZnnPaths] explicitly.
///
/// Mobile platforms (Android and iOS) must call this before accessing
/// [znnDefaultPaths], [znnDefaultDirectory], [znnDefaultWalletDirectory],
/// [znnDefaultCacheDirectory], [ensureDirectoriesExist], or
/// `Zenon().keyStoreManager`.
void configureZnnPaths(ZnnPaths paths) {
  _znnPaths = paths;
}

/// Resets cached SDK paths and optionally overrides the platform/environment
/// providers for tests.
///
/// Calling this with no arguments clears configured/cached paths and restores
/// real `Platform.operatingSystem` and `Platform.environment` lookups.
void resetZnnPathsForTesting({
  String? operatingSystem,
  Map<String, String>? environment,
}) {
  _znnPaths = null;
  _operatingSystemProvider = operatingSystem != null
      ? () => operatingSystem
      : () => Platform.operatingSystem;
  _environmentProvider = environment != null
      ? () => environment
      : () => Platform.environment;
}

ZnnPaths _getDefaultPaths() {
  final os = _operatingSystemProvider();
  final env = _environmentProvider();

  if (os == 'android' || os == 'ios') {
    throw StateError(
      'Default ZNN paths are not available on $os. '
      'Call configureZnnPaths(...) before accessing default paths.',
    );
  }

  late Directory main;
  if (os == 'linux') {
    final home = env['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError(
        'Cannot resolve default ZNN paths on linux because HOME is not set. '
        'Call configureZnnPaths(...) before accessing default paths.',
      );
    }
    main = Directory(path.join(home, '.$znnRootDirectory'));
  } else if (os == 'macos') {
    final home = env['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError(
        'Cannot resolve default ZNN paths on macos because HOME is not set. '
        'Call configureZnnPaths(...) before accessing default paths.',
      );
    }
    main = Directory(path.join(home, 'Library', znnRootDirectory));
  } else if (os == 'windows') {
    final appData = env['AppData'] ?? env['APPDATA'];
    if (appData == null || appData.isEmpty) {
      throw StateError(
        'Cannot resolve default ZNN paths on windows because AppData is not set. '
        'Call configureZnnPaths(...) before accessing default paths.',
      );
    }
    main = Directory(path.join(appData, znnRootDirectory));
  } else {
    final home = env['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError(
        'Cannot resolve default ZNN paths on $os because HOME is not set. '
        'Call configureZnnPaths(...) before accessing default paths.',
      );
    }
    main = Directory(path.join(home, znnRootDirectory));
  }

  return ZnnPaths(
    main: main,
    wallet: Directory(path.join(main.path, 'wallet')),
    cache: Directory(path.join(main.path, 'syrius')),
  );
}

ZnnPaths get znnDefaultPaths => _znnPaths ??= _getDefaultPaths();

set znnDefaultPaths(ZnnPaths paths) {
  configureZnnPaths(paths);
}

Directory get znnDefaultDirectory => znnDefaultPaths.main;

set znnDefaultDirectory(Directory directory) {
  znnDefaultPaths.main = directory;
}

Directory get znnDefaultWalletDirectory => znnDefaultPaths.wallet;

set znnDefaultWalletDirectory(Directory directory) {
  znnDefaultPaths.wallet = directory;
}

Directory get znnDefaultCacheDirectory => znnDefaultPaths.cache;

set znnDefaultCacheDirectory(Directory directory) {
  znnDefaultPaths.cache = directory;
}

void ensureDirectoriesExist() {
  if (!znnDefaultDirectory.existsSync()) {
    znnDefaultDirectory.createSync(recursive: true);
  }
  if (!znnDefaultWalletDirectory.existsSync()) {
    znnDefaultWalletDirectory.createSync(recursive: true);
  }
  if (!znnDefaultCacheDirectory.existsSync()) {
    znnDefaultCacheDirectory.createSync(recursive: true);
  }
}

/// Returns the Dart pub cache directory path, or an empty string when the
/// required environment variables are unavailable (or on Android/iOS without
/// an explicit `PUB_CACHE`).
///
/// Returning `''` ensures callers such as
/// `Directory(getPubCachePath()).existsSync()` safely evaluate to `false`
/// without throwing.
String getPubCachePath() {
  final os = _operatingSystemProvider();
  final env = _environmentProvider();

  final pubCache = env['PUB_CACHE'];
  if (pubCache != null && pubCache.isNotEmpty) {
    return Directory(pubCache).path;
  }

  if (os == 'android' || os == 'ios') {
    return '';
  }

  if (os == 'windows') {
    final appData = env['APPDATA'] ?? env['AppData'];
    if (appData != null && appData.isNotEmpty) {
      final pubCacheDirectory = Directory(path.join(appData, 'Pub', 'Cache'));
      if (pubCacheDirectory.existsSync()) {
        return pubCacheDirectory.path;
      }
    }
    final localAppData = env['LOCALAPPDATA'] ?? env['LocalAppData'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return Directory(path.join(localAppData, 'Pub', 'Cache')).path;
    }
    return '';
  }

  final home = env['HOME'];
  if (home == null || home.isEmpty) {
    return '';
  }
  return Directory(path.join(home, '.pub-cache')).path;
}

int chainId = 1; // Alphanet

void setChainIdentifier({int chainIdentifier = 1}) {
  chainId = chainIdentifier;
}

int getChainIdentifier() {
  return chainId;
}

final logger = Logger('ZNN-SDK');

class ZnnSdkException implements Exception {
  final String? message;

  ZnnSdkException([this.message]);

  @override
  String toString() {
    Object? message = this.message;
    if (message == null) return 'Zenon SDK Exception';
    return 'Zenon SDK Exception: $message';
  }
}
