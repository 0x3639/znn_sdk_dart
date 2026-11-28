import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:znn_sdk_dart/src/global.dart';
import 'package:znn_sdk_dart/src/model/primitives/hash.dart';

enum PowStatus {
  generating,
  done,
}

var invalidPowLinksLibPathException =
    ZnnSdkException('Library libpow_links could not be found');

/// Callback that loads and returns the native `pow_links` [DynamicLibrary].
typedef PowLibraryLoader = DynamicLibrary Function();

typedef _GeneratePowFunc = Pointer<Utf8> Function(
    Pointer<Utf8> data, Pointer<Utf8> difficulty);
typedef _GeneratePoW = Pointer<Utf8> Function(
    Pointer<Utf8> data, Pointer<Utf8> difficulty);
typedef _BenchmarkPowFunc = Pointer<Utf8> Function(Pointer<Utf8> difficulty);
typedef _BenchmarkPoW = Pointer<Utf8> Function(Pointer<Utf8> difficulty);

PowLibraryLoader? _powLibraryLoader;
String? _powLibraryPath;
String? _resolvedLibraryPath;
_GeneratePoW? _generatePoWFunction;
_BenchmarkPoW? _benchmarkFunction;

/// Configures a custom [PowLibraryLoader] (and/or explicit [libraryPath]) for
/// loading the native `pow_links` library, and resets any cached FFI bindings.
///
/// Passing `null` for both [loader] and [libraryPath] restores default
/// platform resolution.
///
/// Note on [generatePoW]: [generatePoW] executes inside a freshly spawned
/// [Isolate], which does not inherit top-level closures like [loader] from the
/// main isolate. If [generatePoW] must load from a non-default file path inside
/// the worker isolate, provide [libraryPath] as well; otherwise the worker
/// isolate falls back to default platform resolution.
void configurePoWLibraryLoader(
  PowLibraryLoader? loader, {
  String? libraryPath,
}) {
  _powLibraryLoader = loader;
  _powLibraryPath = libraryPath;
  _resolvedLibraryPath = null;
  _generatePoWFunction = null;
  _benchmarkFunction = null;
}

bool _defaultHasRequiredSymbols(DynamicLibrary dylib) {
  return dylib.providesSymbol('generatePoW') &&
      dylib.providesSymbol('benchmark');
}

void _bindPoWFunctions(DynamicLibrary dylib) {
  // Look up both native functions before mutating cached state.
  final generatePoWPointer =
      dylib.lookup<NativeFunction<_GeneratePowFunc>>('generatePoW');
  final benchmarkPointer =
      dylib.lookup<NativeFunction<_BenchmarkPowFunc>>('benchmark');

  _generatePoWFunction = generatePoWPointer.asFunction<_GeneratePoW>();
  _benchmarkFunction = benchmarkPointer.asFunction<_BenchmarkPoW>();
}

void _initializePoWLinksFromPath(String libraryPath) {
  logger.info('Loading libpow_links from path $libraryPath');
  final DynamicLibrary dylib;
  try {
    dylib = DynamicLibrary.open(libraryPath);
  } catch (e) {
    throw ZnnSdkException(
      'Library libpow_links could not be opened from $libraryPath: $e',
    );
  }
  _bindPoWFunctions(dylib);
}

List<String> _desktopSearchDirectories({
  required String currentDirectoryPath,
  required String resolvedExecutablePath,
}) {
  final insideSdk = path.join('znn_sdk_dart', 'lib', 'src', 'pow', 'blobs');
  final currentPathListParts = path.split(currentDirectoryPath);
  if (currentPathListParts.isNotEmpty) {
    currentPathListParts.removeLast();
  }

  final executablePathListParts = path.split(resolvedExecutablePath);
  if (executablePathListParts.isNotEmpty) {
    executablePathListParts.removeLast();
  }

  final possiblePaths = <String>[];
  void addUnique(String dirPath) {
    if (dirPath.isNotEmpty && !possiblePaths.contains(dirPath)) {
      possiblePaths.add(dirPath);
    }
  }

  addUnique(currentDirectoryPath);
  if (executablePathListParts.isNotEmpty) {
    addUnique(path.joinAll(executablePathListParts));
    executablePathListParts.removeLast();
    if (executablePathListParts.isNotEmpty) {
      addUnique(path.join(path.joinAll(executablePathListParts), 'Resources'));
    }
  }
  if (currentPathListParts.isNotEmpty) {
    addUnique(path.join(path.joinAll(currentPathListParts), insideSdk));
  }
  if (currentDirectoryPath.isNotEmpty) {
    addUnique(path.join(currentDirectoryPath, 'lib', 'src', 'pow', 'blobs'));
  }

  return possiblePaths;
}

String? _findLibraryInDirectories(
  Iterable<String> directories,
  String libraryFileName, {
  required bool Function(String path) fileExists,
}) {
  for (final currentPath in directories) {
    final libraryPath = path.join(currentPath, libraryFileName);
    if (fileExists(libraryPath)) {
      return libraryPath;
    }
  }
  return null;
}

List<String> _defaultListPubCacheFiles(String dirPath) {
  final pubCacheDir = Directory(dirPath);
  if (!pubCacheDir.existsSync()) {
    return const <String>[];
  }

  final files = <String>[];
  for (final entity
      in pubCacheDir.listSync(recursive: true, followLinks: false)) {
    try {
      if (entity.statSync().type == FileSystemEntityType.file) {
        files.add(entity.absolute.path);
      }
    } on FileSystemException {
      // Skip inaccessible entries or dangling symlinks.
    }
  }
  return files;
}

List<String> _findPubCacheLibraryDirectories({
  required String Function() resolvePubCachePath,
  required List<String> Function(String dirPath) listPubCacheFiles,
}) {
  final String pubCachePath;
  try {
    pubCachePath = resolvePubCachePath().trim();
  } catch (e) {
    logger.warning('Could not determine pub cache path: $e');
    return const <String>[];
  }

  if (pubCachePath.isEmpty) {
    return const <String>[];
  }

  final dirs = <String>[];
  try {
    for (final filePath in listPubCacheFiles(pubCachePath)) {
      final ext = path.extension(filePath);
      if (filePath.contains('libpow_links') &&
          (ext == '.so' || ext == '.dylib' || ext == '.dll')) {
        final dir = path.dirname(filePath);
        if (!dirs.contains(dir)) {
          dirs.add(dir);
        }
      }
    }
  } catch (e) {
    logger.warning('Failed to scan pub cache at $pubCachePath: $e');
  }
  return dirs;
}

DynamicLibrary _openDefaultPoWLibrary({
  required bool isAndroid,
  required bool isIOS,
  required bool isMacOS,
  required bool isWindows,
  required DynamicLibrary Function(String path) openLibrary,
  required DynamicLibrary Function() openProcess,
  required DynamicLibrary Function() openExecutable,
  required bool Function(String path) fileExists,
  required String Function() resolvePubCachePath,
  required List<String> Function(String dirPath) listPubCacheFiles,
  required bool Function(DynamicLibrary dylib) hasRequiredSymbols,
  required String currentDirectoryPath,
  required String resolvedExecutablePath,
  void Function(String resolvedPath)? onDesktopPathResolved,
}) {
  if (isAndroid) {
    const androidLibraryName = 'libpow_links.so';
    logger.info('Loading libpow_links on Android from $androidLibraryName');
    try {
      final dylib = openLibrary(androidLibraryName);
      if (!hasRequiredSymbols(dylib)) {
        throw ZnnSdkException(
          'Library $androidLibraryName loaded on Android is missing required '
          'symbols (generatePoW, benchmark)',
        );
      }
      return dylib;
    } on ZnnSdkException {
      rethrow;
    } catch (e) {
      throw ZnnSdkException(
        'Library libpow_links could not be found on Android '
        '(failed to open $androidLibraryName): $e',
      );
    }
  }

  if (isIOS) {
    const frameworkPath = 'pow_links.framework/pow_links';
    final attempts = <String>[];
    final candidates = <(String, DynamicLibrary Function())>[
      (frameworkPath, () => openLibrary(frameworkPath)),
      ('DynamicLibrary.process()', openProcess),
      ('DynamicLibrary.executable()', openExecutable),
    ];

    for (final (label, loader) in candidates) {
      try {
        final dylib = loader();
        if (hasRequiredSymbols(dylib)) {
          logger.info('Loading libpow_links on iOS via $label');
          return dylib;
        }
        attempts.add('$label: missing required symbols');
      } catch (e) {
        attempts.add('$label: $e');
      }
    }

    throw ZnnSdkException(
      'Library libpow_links could not be found on iOS '
      '(${attempts.join('; ')})',
    );
  }

  final libraryFileName = isMacOS
      ? 'libpow_links.dylib'
      : isWindows
          ? 'libpow_links.dll'
          : 'libpow_links.so';

  final localDirectories = _desktopSearchDirectories(
    currentDirectoryPath: currentDirectoryPath,
    resolvedExecutablePath: resolvedExecutablePath,
  );

  var resolvedPath = _findLibraryInDirectories(
    localDirectories,
    libraryFileName,
    fileExists: fileExists,
  );

  if (resolvedPath == null) {
    final pubCacheDirectories = _findPubCacheLibraryDirectories(
      resolvePubCachePath: resolvePubCachePath,
      listPubCacheFiles: listPubCacheFiles,
    );
    resolvedPath = _findLibraryInDirectories(
      pubCacheDirectories,
      libraryFileName,
      fileExists: fileExists,
    );
  }

  if (resolvedPath == null) {
    logger.info('Library $libraryFileName could not be found');
    throw invalidPowLinksLibPathException;
  }

  logger.info('Loading libpow_links from path $resolvedPath');
  onDesktopPathResolved?.call(resolvedPath);
  return openLibrary(resolvedPath);
}

/// Resolves the default PoW [DynamicLibrary] using injectable platform and
/// filesystem callbacks.
///
/// Intended for unit testing platform-specific resolution logic.
DynamicLibrary resolveDefaultPoWLibraryForTesting({
  bool isAndroid = false,
  bool isIOS = false,
  bool isMacOS = false,
  bool isWindows = false,
  required DynamicLibrary Function(String path) openLibrary,
  required DynamicLibrary Function() openProcess,
  required DynamicLibrary Function() openExecutable,
  bool Function(String path)? fileExists,
  String Function()? resolvePubCachePath,
  List<String> Function(String dirPath)? listPubCacheFiles,
  bool Function(DynamicLibrary dylib)? hasRequiredSymbols,
  String currentDirectoryPath = '',
  String resolvedExecutablePath = '',
}) {
  return _openDefaultPoWLibrary(
    isAndroid: isAndroid,
    isIOS: isIOS,
    isMacOS: isMacOS,
    isWindows: isWindows,
    openLibrary: openLibrary,
    openProcess: openProcess,
    openExecutable: openExecutable,
    fileExists: fileExists ?? (_) => false,
    resolvePubCachePath: resolvePubCachePath ?? () => '',
    listPubCacheFiles: listPubCacheFiles ?? (_) => const <String>[],
    hasRequiredSymbols: hasRequiredSymbols ?? _defaultHasRequiredSymbols,
    currentDirectoryPath: currentDirectoryPath,
    resolvedExecutablePath: resolvedExecutablePath,
  );
}

// Loads the dynamic pow_links library and maps the required functions. Throws if fails.
// Called automatically from `generatePoW` and `benchmarkPoW` if not called in advance.
void initializePoWLinks() {
  if (_powLibraryLoader != null) {
    final dylib = _powLibraryLoader!();
    _bindPoWFunctions(dylib);
    return;
  }

  if (_powLibraryPath != null) {
    _initializePoWLinksFromPath(_powLibraryPath!);
    return;
  }

  String? desktopResolvedPath;
  final dylib = _openDefaultPoWLibrary(
    isAndroid: Platform.isAndroid,
    isIOS: Platform.isIOS,
    isMacOS: Platform.isMacOS,
    isWindows: Platform.isWindows,
    openLibrary: DynamicLibrary.open,
    openProcess: DynamicLibrary.process,
    openExecutable: DynamicLibrary.executable,
    fileExists: (filePath) => File(filePath).existsSync(),
    resolvePubCachePath: getPubCachePath,
    listPubCacheFiles: _defaultListPubCacheFiles,
    hasRequiredSymbols: _defaultHasRequiredSymbols,
    currentDirectoryPath: Directory.current.path,
    resolvedExecutablePath: Platform.resolvedExecutable,
    onDesktopPathResolved: (resolvedPath) {
      desktopResolvedPath = resolvedPath;
    },
  );

  _bindPoWFunctions(dylib);
  _resolvedLibraryPath = desktopResolvedPath;
}

sealed class _PowIsolateMessage {
  const _PowIsolateMessage();
}

final class _PowIsolateSuccess extends _PowIsolateMessage {
  final String nonce;

  const _PowIsolateSuccess(this.nonce);
}

final class _PowIsolateFailure extends _PowIsolateMessage {
  final Object error;
  final String stackTrace;

  const _PowIsolateFailure(this.error, this.stackTrace);
}

class _GeneratePowFunctionArguments {
  final Hash hash;
  final int? difficulty;
  final SendPort sendPort;
  final String? libraryPath;

  _GeneratePowFunctionArguments(
    this.hash,
    this.difficulty,
    this.sendPort, {
    this.libraryPath,
  });
}

void _generatePowFunction(_GeneratePowFunctionArguments args) {
  try {
    if (args.libraryPath != null) {
      _initializePoWLinksFromPath(args.libraryPath!);
    } else {
      initializePoWLinks();
    }

    final String nonce;
    Pointer<Utf8>? dataPtr;
    Pointer<Utf8>? difficultyPtr;
    try {
      dataPtr = args.hash.toString().toNativeUtf8(allocator: calloc);
      difficultyPtr =
          (args.difficulty ?? 0).toString().toNativeUtf8(allocator: calloc);
      final ret = _generatePoWFunction!(dataPtr, difficultyPtr);
      if (ret == nullptr) {
        throw ZnnSdkException('Native generatePoW returned null pointer');
      }
      nonce = ret.toDartString();
    } finally {
      if (dataPtr != null) {
        calloc.free(dataPtr);
      }
      if (difficultyPtr != null) {
        calloc.free(difficultyPtr);
      }
    }
    args.sendPort.send(_PowIsolateSuccess(nonce));
  } catch (error, stackTrace) {
    final stackString = stackTrace.toString();
    try {
      args.sendPort.send(_PowIsolateFailure(error, stackString));
    } catch (_) {
      args.sendPort.send(
        _PowIsolateFailure(
          ZnnSdkException(error.toString()),
          stackString,
        ),
      );
    }
  }
}

Future<String> _runPoWInIsolate<T>(
  void Function(T message) entryPoint,
  T Function(SendPort sendPort) buildMessage,
) async {
  // Using a single ReceivePort with a typed message protocol guarantees strict
  // FIFO ordering between worker results, VM onError lists, and onExit null
  // signals (per Isolate.addOnExitListener ordering guarantees).
  final port = ReceivePort();
  final completer = Completer<String>();
  StreamSubscription<dynamic>? sub;
  Isolate? isolate;

  try {
    sub = port.listen((Object? message) {
      if (completer.isCompleted) {
        return;
      }
      if (message is _PowIsolateSuccess) {
        completer.complete(message.nonce);
      } else if (message is _PowIsolateFailure) {
        completer.completeError(
          message.error,
          message.stackTrace.isNotEmpty
              ? StackTrace.fromString(message.stackTrace)
              : StackTrace.current,
        );
      } else if (message is List && message.length == 2) {
        final errorDescription =
            message[0]?.toString() ?? 'Unknown PoW isolate error';
        final stackDescription = message[1]?.toString() ?? '';
        completer.completeError(
          RemoteError(errorDescription, stackDescription),
          stackDescription.isNotEmpty
              ? StackTrace.fromString(stackDescription)
              : StackTrace.current,
        );
      } else if (message == null) {
        completer.completeError(
          StateError('PoW isolate exited without returning a result'),
        );
      } else {
        completer.completeError(
          StateError('Unexpected message from PoW isolate: $message'),
        );
      }
    });

    isolate = await Isolate.spawn<T>(
      entryPoint,
      buildMessage(port.sendPort),
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
    );

    return await completer.future;
  } finally {
    await sub?.cancel();
    port.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

/// Runs an isolate entry point through the PoW isolate error/exit lifecycle.
///
/// Intended for unit testing isolate crash, premature exit, and unexpected
/// message handling.
Future<String> runPoWIsolateForTesting(
  void Function(SendPort sendPort) entryPoint,
) {
  return _runPoWInIsolate<SendPort>(entryPoint, (sendPort) => sendPort);
}

// Returns a hex representation of nonce.
// Runs single threaded, with native c code.
Future<String> generatePoW(Hash hash, int? difficulty) async {
  if (_generatePoWFunction == null) {
    initializePoWLinks();
  }

  final isolateLibraryPath = _powLibraryPath ?? _resolvedLibraryPath;
  final ansHex = await _runPoWInIsolate<_GeneratePowFunctionArguments>(
    _generatePowFunction,
    (sendPort) => _GeneratePowFunctionArguments(
      hash,
      difficulty,
      sendPort,
      libraryPath: isolateLibraryPath,
    ),
  );

  logger.info(
    'Generated nonce $ansHex for hash ${hash.toString()} with difficulty $difficulty',
  );
  return ansHex;
}

// Generates a nonce for the empty hash. Does not use a random nonce.
//
// Expects
// - difficulty 10'000'000
// - runtime ~800 ms
String benchmarkPoW(int difficulty) {
  if (_benchmarkFunction == null) {
    initializePoWLinks();
  }

  final difficultyPtr = difficulty.toString().toNativeUtf8(allocator: calloc);
  try {
    final ret = _benchmarkFunction!(difficultyPtr);
    if (ret == nullptr) {
      throw ZnnSdkException('Native benchmarkPoW returned null pointer');
    }
    return ret.toDartString();
  } finally {
    calloc.free(difficultyPtr);
  }
}
