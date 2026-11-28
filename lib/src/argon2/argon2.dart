import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:argon2_ffi_base/argon2_ffi_base.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:znn_sdk_dart/src/global.dart';

const _argon2SymbolName = 'hp_argon2_hash';
const _androidLibraryName = 'libargon2_ffi.so';
const _iosFrameworkPath = 'argon2_ffi.framework/argon2_ffi';

var invalidArgon2LibPathException =
    ZnnSdkException('Library libargon2 could not be found');

typedef Argon2LibraryLoader = DynamicLibrary Function();

typedef _Argon2HashNative = Pointer<Utf8> Function(
  Pointer<Uint8> key,
  Uint32 keyLen,
  Pointer<Uint8> salt,
  Uint32 saltLen,
  Uint32 mCost,
  Uint32 tCost,
  Uint32 parallelism,
  IntPtr hashLen,
  Uint8 type,
  Uint32 version,
);

typedef _Argon2Hash = Pointer<Utf8> Function(
  Pointer<Uint8> key,
  int keyLen,
  Pointer<Uint8> salt,
  int saltLen,
  int mCost,
  int tCost,
  int parallelism,
  int hashLen,
  int type,
  int version,
);

Argon2LibraryLoader? _customArgon2LibraryLoader;

/// Configures an optional custom loader for the native Argon2 library.
///
/// Pass `null` to restore default platform library resolution.
void configureArgon2LibraryLoader(Argon2LibraryLoader? loader) {
  _customArgon2LibraryLoader = loader;
}

Argon2 initArgon2() {
  final customLoader = _customArgon2LibraryLoader;
  if (customLoader != null) {
    final library = customLoader();
    return _FfiArgon2(_lookupArgon2Hash(library));
  }

  final hashFn = _resolveArgon2Symbol<DynamicLibrary, _Argon2Hash>(
    operatingSystem: Platform.operatingSystem,
    openLibrary: DynamicLibrary.open,
    openProcess: DynamicLibrary.process,
    openExecutable: DynamicLibrary.executable,
    lookupSymbol: _lookupArgon2Hash,
    currentDirectoryPath: Directory.current.path,
    resolvedExecutablePath: Platform.resolvedExecutable,
    pubCachePathProvider: getPubCachePath,
    fileExists: (candidate) => File(candidate).existsSync(),
    findPubCacheLibDirs: _findPubCacheArgon2LibDirs,
  );
  return _FfiArgon2(hashFn);
}

/// Resolves the native Argon2 symbol using injectable platform and loader
/// callbacks. Intended for unit testing platform-specific resolution paths.
S resolveArgon2SymbolForTesting<L, S>({
  required String operatingSystem,
  required L Function(String path) openLibrary,
  required L Function() openProcess,
  required L Function() openExecutable,
  required S Function(L library) lookupSymbol,
  String? currentDirectoryPath,
  String? resolvedExecutablePath,
  String? Function()? pubCachePathProvider,
  bool Function(String path)? fileExists,
  Iterable<String> Function(String pubCachePath)? findPubCacheLibDirs,
}) {
  return _resolveArgon2Symbol<L, S>(
    operatingSystem: operatingSystem,
    openLibrary: openLibrary,
    openProcess: openProcess,
    openExecutable: openExecutable,
    lookupSymbol: lookupSymbol,
    currentDirectoryPath: currentDirectoryPath ?? Directory.current.path,
    resolvedExecutablePath:
        resolvedExecutablePath ?? Platform.resolvedExecutable,
    pubCachePathProvider: pubCachePathProvider ?? getPubCachePath,
    fileExists: fileExists ?? (candidate) => File(candidate).existsSync(),
    findPubCacheLibDirs: findPubCacheLibDirs ?? _findPubCacheArgon2LibDirs,
  );
}

_Argon2Hash _lookupArgon2Hash(DynamicLibrary library) {
  return library
      .lookup<NativeFunction<_Argon2HashNative>>(_argon2SymbolName)
      .asFunction<_Argon2Hash>();
}

S _resolveArgon2Symbol<L, S>({
  required String operatingSystem,
  required L Function(String path) openLibrary,
  required L Function() openProcess,
  required L Function() openExecutable,
  required S Function(L library) lookupSymbol,
  required String currentDirectoryPath,
  required String resolvedExecutablePath,
  required String? Function() pubCachePathProvider,
  required bool Function(String path) fileExists,
  required Iterable<String> Function(String pubCachePath) findPubCacheLibDirs,
}) {
  if (operatingSystem == 'android') {
    logger.info('Loading $_androidLibraryName on Android');
    return lookupSymbol(openLibrary(_androidLibraryName));
  }

  if (operatingSystem == 'ios') {
    final candidates = <({String label, L Function() load})>[
      (
        label: _iosFrameworkPath,
        load: () => openLibrary(_iosFrameworkPath),
      ),
      (
        label: 'DynamicLibrary.process()',
        load: openProcess,
      ),
      (
        label: 'DynamicLibrary.executable()',
        load: openExecutable,
      ),
    ];

    for (final candidate in candidates) {
      try {
        final library = candidate.load();
        final symbol = lookupSymbol(library);
        logger.info('Loaded $_argon2SymbolName on iOS via ${candidate.label}');
        return symbol;
      } on ArgumentError catch (e) {
        logger.fine(
            'Unable to load $_argon2SymbolName on iOS via ${candidate.label}: $e');
      }
    }

    throw invalidArgon2LibPathException;
  }

  final libraryNames = _desktopLibraryNames(operatingSystem);
  if (libraryNames == null) {
    throw UnsupportedError(
        'Unsupported operating system for Argon2: $operatingSystem');
  }

  final candidatePath = _findDesktopLibraryPath(
    libraryNames: libraryNames,
    currentDirectoryPath: currentDirectoryPath,
    resolvedExecutablePath: resolvedExecutablePath,
    pubCachePathProvider: pubCachePathProvider,
    fileExists: fileExists,
    findPubCacheLibDirs: findPubCacheLibDirs,
  );
  if (candidatePath == null) {
    throw invalidArgon2LibPathException;
  }

  logger.info('Loading Argon2 library from path $candidatePath');
  return lookupSymbol(openLibrary(candidatePath));
}

List<String>? _desktopLibraryNames(String operatingSystem) {
  switch (operatingSystem) {
    case 'macos':
      return const ['libargon2_ffi.dylib'];
    case 'linux':
      return const ['libargon2_ffi_plugin.so', 'libargon2_ffi.so'];
    case 'windows':
      return const ['argon2_ffi_plugin.dll'];
    default:
      return null;
  }
}

String? _findDesktopLibraryPath({
  required List<String> libraryNames,
  required String currentDirectoryPath,
  required String resolvedExecutablePath,
  required String? Function() pubCachePathProvider,
  required bool Function(String path) fileExists,
  required Iterable<String> Function(String pubCachePath) findPubCacheLibDirs,
}) {
  final insideSdk = path.join('znn_sdk_dart', 'lib', 'src', 'argon2', 'blobs');
  final executableDir = path.dirname(resolvedExecutablePath);
  final executableParentDir = path.dirname(executableDir);
  final currentParentDir = path.dirname(currentDirectoryPath);

  final localSearchDirs = <String>{
    currentDirectoryPath,
    executableDir,
    path.join(executableParentDir, 'Resources'),
    path.join(executableDir, 'lib'),
    path.join(currentDirectoryPath, 'lib', 'src', 'argon2', 'blobs'),
    path.join(currentParentDir, insideSdk),
  };

  final localMatch =
      _firstExistingLibrary(localSearchDirs, libraryNames, fileExists);
  if (localMatch != null) {
    return localMatch;
  }

  String? pubCachePath;
  try {
    final resolved = pubCachePathProvider();
    if (resolved != null && resolved.isNotEmpty) {
      pubCachePath = resolved;
    }
  } catch (e) {
    logger.fine('Unable to resolve pub cache path: $e');
  }

  if (pubCachePath != null) {
    final pubCacheDirs = <String>{};
    try {
      pubCacheDirs.addAll(findPubCacheLibDirs(pubCachePath));
    } catch (e) {
      logger.fine('Unable to scan pub cache at $pubCachePath: $e');
    }
    final pubCacheMatch =
        _firstExistingLibrary(pubCacheDirs, libraryNames, fileExists);
    if (pubCacheMatch != null) {
      return pubCacheMatch;
    }
  }

  return null;
}

String? _firstExistingLibrary(
  Iterable<String> searchDirs,
  List<String> libraryNames,
  bool Function(String path) fileExists,
) {
  for (final dir in searchDirs) {
    if (dir.isEmpty) continue;
    for (final libraryName in libraryNames) {
      final candidate = path.join(dir, libraryName);
      if (fileExists(candidate)) {
        return candidate;
      }
    }
  }
  return null;
}

Iterable<String> _findPubCacheArgon2LibDirs(String pubCachePath) {
  final pubCacheDir = Directory(pubCachePath);
  if (!pubCacheDir.existsSync()) {
    return const [];
  }

  final dirs = <String>{};
  try {
    for (final entity
        in pubCacheDir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final filePath = entity.absolute.path;
      final ext = path.extension(filePath);
      if (filePath.contains('argon2_ffi') &&
          (ext == '.so' || ext == '.dylib' || ext == '.dll')) {
        dirs.add(path.dirname(filePath));
      }
    }
  } on FileSystemException catch (e) {
    logger.fine('Failed to scan pub cache directory $pubCachePath: $e');
  }
  return dirs;
}

class _FfiArgon2 extends Argon2 {
  const _FfiArgon2(this._argon2Hash);

  final _Argon2Hash _argon2Hash;

  @override
  bool get isFfi => true;

  @override
  bool get isImplemented => true;

  @override
  Uint8List argon2(Argon2Arguments args) {
    Pointer<Uint8>? keyPtr;
    Pointer<Uint8>? saltPtr;
    try {
      keyPtr = _toNativeBytes(args.key);
      saltPtr = _toNativeBytes(args.salt);
      final result = _argon2Hash(
        keyPtr,
        args.key.length,
        saltPtr,
        args.salt.length,
        args.memory,
        args.iterations,
        args.parallelism,
        args.length,
        args.type,
        args.version,
      );
      if (result == nullptr) {
        throw ZnnSdkException(
            'Argon2 hashing failed: native library returned null');
      }
      return base64.decode(result.toDartString());
    } finally {
      if (keyPtr != null) {
        if (args.key.isNotEmpty) {
          keyPtr.asTypedList(args.key.length).fillRange(0, args.key.length, 0);
        }
        calloc.free(keyPtr);
      }
      if (saltPtr != null) {
        calloc.free(saltPtr);
      }
    }
  }

  @override
  Future<Uint8List> argon2Async(Argon2Arguments args) async {
    return argon2(args);
  }
}

Pointer<Uint8> _toNativeBytes(Uint8List bytes) {
  final ptr = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  if (bytes.isNotEmpty) {
    ptr.asTypedList(bytes.length).setAll(0, bytes);
  }
  return ptr;
}
