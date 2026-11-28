import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:znn_sdk_dart/znn_sdk_dart.dart';

void _crashingIsolate(SendPort _) {
  throw StateError('simulated uncaught isolate error');
}

void _silentExitIsolate(SendPort _) {
  // Exits immediately without sending any result.
}

void _bogusListMessageIsolate(SendPort sendPort) {
  sendPort.send(<Object?>['simulated error', 'stack trace']);
}

void _unexpectedMessageIsolate(SendPort sendPort) {
  sendPort.send('unwrapped string');
}

String _hostPowLibraryPath() {
  final fileName = Platform.isMacOS
      ? 'libpow_links.dylib'
      : Platform.isWindows
          ? 'libpow_links.dll'
          : 'libpow_links.so';
  return path.join(
    Directory.current.path,
    'lib',
    'src',
    'pow',
    'blobs',
    fileName,
  );
}

void main() {
  final realDylibPath = _hostPowLibraryPath();
  final hasRealDylib = File(realDylibPath).existsSync();
  late final DynamicLibrary realDylib;

  setUpAll(() {
    if (hasRealDylib) {
      realDylib = DynamicLibrary.open(realDylibPath);
    }
  });

  tearDown(() {
    configurePoWLibraryLoader(null);
  });

  group('Platform dynamic library resolution', () {
    test('Android opens libpow_links.so directly without filesystem scans', () {
      final openedPaths = <String>[];

      final loaded = resolveDefaultPoWLibraryForTesting(
        isAndroid: true,
        openLibrary: (libPath) {
          openedPaths.add(libPath);
          return realDylib;
        },
        openProcess: () => fail('Android must not call DynamicLibrary.process'),
        openExecutable: () =>
            fail('Android must not call DynamicLibrary.executable'),
        fileExists: (_) => fail('Android must not call File.existsSync'),
        resolvePubCachePath: () =>
            fail('Android must not inspect pub cache path'),
        listPubCacheFiles: (_) => fail('Android must not scan pub cache'),
        hasRequiredSymbols: (_) => true,
      );

      expect(loaded, same(realDylib));
      expect(openedPaths, equals(<String>['libpow_links.so']));
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);

    test('Android throws ZnnSdkException when libpow_links.so cannot be opened',
        () {
      expect(
        () => resolveDefaultPoWLibraryForTesting(
          isAndroid: true,
          openLibrary: (libPath) =>
              throw ArgumentError('Failed to load $libPath'),
          openProcess: () =>
              fail('Android must not call DynamicLibrary.process'),
          openExecutable: () =>
              fail('Android must not call DynamicLibrary.executable'),
          fileExists: (_) => fail('Android must not call File.existsSync'),
          resolvePubCachePath: () =>
              fail('Android must not inspect pub cache path'),
          listPubCacheFiles: (_) => fail('Android must not scan pub cache'),
        ),
        throwsA(
          isA<ZnnSdkException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Android'), contains('libpow_links.so')),
          ),
        ),
      );
    });

    test('Android throws ZnnSdkException when required symbols are missing',
        () {
      expect(
        () => resolveDefaultPoWLibraryForTesting(
          isAndroid: true,
          openLibrary: (_) => DynamicLibrary.process(),
          openProcess: () =>
              fail('Android must not call DynamicLibrary.process'),
          openExecutable: () =>
              fail('Android must not call DynamicLibrary.executable'),
          fileExists: (_) => fail('Android must not call File.existsSync'),
          resolvePubCachePath: () =>
              fail('Android must not inspect pub cache path'),
          listPubCacheFiles: (_) => fail('Android must not scan pub cache'),
          hasRequiredSymbols: (_) => false,
        ),
        throwsA(
          isA<ZnnSdkException>().having(
            (e) => e.message,
            'message',
            contains('missing required symbols'),
          ),
        ),
      );
    });

    test('iOS prefers pow_links.framework/pow_links without File.existsSync',
        () {
      final attempts = <String>[];

      final loaded = resolveDefaultPoWLibraryForTesting(
        isIOS: true,
        openLibrary: (libPath) {
          attempts.add('open:$libPath');
          return realDylib;
        },
        openProcess: () {
          attempts.add('process');
          return DynamicLibrary.process();
        },
        openExecutable: () {
          attempts.add('executable');
          return DynamicLibrary.executable();
        },
        fileExists: (_) => fail('iOS must not call File.existsSync'),
        resolvePubCachePath: () => fail('iOS must not inspect pub cache path'),
        listPubCacheFiles: (_) => fail('iOS must not scan pub cache'),
      );

      expect(loaded, same(realDylib));
      expect(attempts, equals(<String>['open:pow_links.framework/pow_links']));
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);

    test('iOS falls back from framework to process when framework is absent',
        () {
      final attempts = <String>[];

      final loaded = resolveDefaultPoWLibraryForTesting(
        isIOS: true,
        openLibrary: (libPath) {
          attempts.add('open:$libPath');
          throw ArgumentError('framework not found');
        },
        openProcess: () {
          attempts.add('process');
          return realDylib;
        },
        openExecutable: () {
          attempts.add('executable');
          return DynamicLibrary.executable();
        },
        fileExists: (_) => fail('iOS must not call File.existsSync'),
        resolvePubCachePath: () => fail('iOS must not inspect pub cache path'),
        listPubCacheFiles: (_) => fail('iOS must not scan pub cache'),
      );

      expect(loaded, same(realDylib));
      expect(
        attempts,
        equals(<String>['open:pow_links.framework/pow_links', 'process']),
      );
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);

    test(
        'iOS falls back from framework -> process -> executable when earlier '
        'handles lack symbols', () {
      final attempts = <String>[];
      final processWithoutSymbols = DynamicLibrary.process();

      final loaded = resolveDefaultPoWLibraryForTesting(
        isIOS: true,
        openLibrary: (libPath) {
          attempts.add('open:$libPath');
          throw ArgumentError('framework not found');
        },
        openProcess: () {
          attempts.add('process');
          return processWithoutSymbols;
        },
        openExecutable: () {
          attempts.add('executable');
          return realDylib;
        },
        fileExists: (_) => fail('iOS must not call File.existsSync'),
        resolvePubCachePath: () => fail('iOS must not inspect pub cache path'),
        listPubCacheFiles: (_) => fail('iOS must not scan pub cache'),
        hasRequiredSymbols: (dylib) => identical(dylib, realDylib),
      );

      expect(loaded, same(realDylib));
      expect(
        attempts,
        equals(<String>[
          'open:pow_links.framework/pow_links',
          'process',
          'executable',
        ]),
      );
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);

    test(
        'iOS throws ZnnSdkException only after framework, process, and '
        'executable all lack required symbols', () {
      final attempts = <String>[];

      expect(
        () => resolveDefaultPoWLibraryForTesting(
          isIOS: true,
          openLibrary: (libPath) {
            attempts.add('open:$libPath');
            throw ArgumentError('framework not found');
          },
          openProcess: () {
            attempts.add('process');
            return DynamicLibrary.process();
          },
          openExecutable: () {
            attempts.add('executable');
            return DynamicLibrary.executable();
          },
          fileExists: (_) => fail('iOS must not call File.existsSync'),
          resolvePubCachePath: () =>
              fail('iOS must not inspect pub cache path'),
          listPubCacheFiles: (_) => fail('iOS must not scan pub cache'),
          hasRequiredSymbols: (_) => false,
        ),
        throwsA(
          isA<ZnnSdkException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('iOS'),
              contains('pow_links.framework/pow_links'),
              contains('DynamicLibrary.process()'),
              contains('DynamicLibrary.executable()'),
            ),
          ),
        ),
      );

      expect(
        attempts,
        equals(<String>[
          'open:pow_links.framework/pow_links',
          'process',
          'executable',
        ]),
      );
    });

    test('Desktop resolves macOS Resources path without scanning pub cache',
        () {
      final checkedFiles = <String>[];
      final openedPaths = <String>[];
      const resourcesLib =
          '/Applications/Syrius.app/Contents/Resources/libpow_links.dylib';

      final loaded = resolveDefaultPoWLibraryForTesting(
        isMacOS: true,
        currentDirectoryPath: '/workspace/app',
        resolvedExecutablePath:
            '/Applications/Syrius.app/Contents/MacOS/syrius',
        fileExists: (candidate) {
          checkedFiles.add(candidate);
          return candidate == resourcesLib;
        },
        openLibrary: (libPath) {
          openedPaths.add(libPath);
          return realDylib;
        },
        openProcess: () => fail('macOS must not call process'),
        openExecutable: () => fail('macOS must not call executable'),
        resolvePubCachePath: () =>
            fail('pub cache should not be scanned when local lib exists'),
        listPubCacheFiles: (_) =>
            fail('pub cache should not be scanned when local lib exists'),
      );

      expect(loaded, same(realDylib));
      expect(openedPaths, equals(<String>[resourcesLib]));
      expect(checkedFiles, contains(resourcesLib));
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);

    test(
        'Desktop falls back to pub cache and guards empty/inaccessible '
        'pubCacheDir safely', () {
      // Empty pub cache path should not throw a path/FS error; throws standard exception.
      expect(
        () => resolveDefaultPoWLibraryForTesting(
          isMacOS: true,
          currentDirectoryPath: '/workspace/app',
          resolvedExecutablePath: '/usr/local/bin/dart',
          fileExists: (_) => false,
          openLibrary: (_) => fail('should not open missing library'),
          openProcess: () => fail('should not call process'),
          openExecutable: () => fail('should not call executable'),
          resolvePubCachePath: () => '',
          listPubCacheFiles: (_) =>
              fail('empty pubCachePath must not be listed'),
        ),
        throwsA(equals(invalidPowLinksLibPathException)),
      );

      // Throwing pubCachePath resolver / inaccessible directory is guarded safely.
      expect(
        () => resolveDefaultPoWLibraryForTesting(
          isMacOS: false,
          isWindows: false,
          currentDirectoryPath: '/workspace/app',
          resolvedExecutablePath: '/usr/local/bin/dart',
          fileExists: (_) => false,
          openLibrary: (_) => fail('should not open missing library'),
          openProcess: () => fail('should not call process'),
          openExecutable: () => fail('should not call executable'),
          resolvePubCachePath: () => '/unreadable/pub-cache',
          listPubCacheFiles: (_) =>
              throw const FileSystemException('Permission denied'),
        ),
        throwsA(equals(invalidPowLinksLibPathException)),
      );

      // Windows resolves .dll from pub cache when local paths miss.
      if (hasRealDylib) {
        const pubCacheDll =
            '/cache/hosted/znn_sdk_dart/lib/src/pow/blobs/libpow_links.dll';
        final openedPaths = <String>[];
        final loaded = resolveDefaultPoWLibraryForTesting(
          isWindows: true,
          currentDirectoryPath: '/workspace/app',
          resolvedExecutablePath: '/dart/bin/dart.exe',
          fileExists: (candidate) => candidate == pubCacheDll,
          openLibrary: (libPath) {
            openedPaths.add(libPath);
            return realDylib;
          },
          openProcess: () => fail('should not call process'),
          openExecutable: () => fail('should not call executable'),
          resolvePubCachePath: () => '/cache',
          listPubCacheFiles: (_) => <String>[pubCacheDll],
        );

        expect(loaded, same(realDylib));
        expect(openedPaths, equals(<String>[pubCacheDll]));
      }
    });
  });

  group('configurePoWLibraryLoader hook', () {
    test('overrides library loading and resets cached functions on reconfigure',
        () {
      var firstLoaderCalls = 0;
      var secondLoaderCalls = 0;

      configurePoWLibraryLoader(() {
        firstLoaderCalls++;
        return realDylib;
      });

      initializePoWLinks();
      expect(firstLoaderCalls, 1);

      // Reconfiguring must clear cached bindings so the next call uses the new loader.
      configurePoWLibraryLoader(() {
        secondLoaderCalls++;
        return realDylib;
      });

      final nonce = benchmarkPoW(100000);
      expect(secondLoaderCalls, 1);
      expect(nonce, isNotEmpty);

      // Resetting with null clears the custom loader and restores default resolution.
      configurePoWLibraryLoader(null);
      initializePoWLinks();
      expect(firstLoaderCalls, 1);
      expect(secondLoaderCalls, 1);
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);
    test('supports explicit libraryPath across main and worker isolates',
        () async {
      configurePoWLibraryLoader(null, libraryPath: realDylibPath);

      final nonce = await generatePoW(emptyHash, 100000);
      expect(nonce, matches(RegExp(r'^[0-9a-fA-F]{16}$')));
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);
  });

  group('Desktop native FFI execution', () {
    test('generatePoW returns a valid hex nonce for emptyHash at 100000',
        () async {
      final nonce = await generatePoW(emptyHash, 100000);

      expect(nonce, matches(RegExp(r'^[0-9a-fA-F]{16}$')));
      expect(nonce, isNot(equals('0000000000000000')));
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);

    test('benchmarkPoW returns a deterministic valid hex nonce without crashing',
        () {
      final first = benchmarkPoW(100000);
      final second = benchmarkPoW(100000);

      expect(first, matches(RegExp(r'^[0-9a-fA-F]{16}$')));
      expect(second, equals(first));
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);
  });

  group('Isolate and loader error handling', () {
    test('generatePoW rejects Future when configured loader throws', () async {
      configurePoWLibraryLoader(
        () => throw ZnnSdkException('custom loader failed'),
      );

      await expectLater(
        generatePoW(emptyHash, 100000),
        throwsA(
          isA<ZnnSdkException>().having(
            (e) => e.message,
            'message',
            'custom loader failed',
          ),
        ),
      );
    });

    test(
        'generatePoW rejects Future when worker isolate fails to open '
        'configured libraryPath', () async {
      configurePoWLibraryLoader(
        () => realDylib,
        libraryPath: '/nonexistent/path/to/libpow_links.dylib',
      );

      await expectLater(
        generatePoW(emptyHash, 100000),
        throwsA(
          isA<ZnnSdkException>().having(
            (e) => e.message,
            'message',
            contains('/nonexistent/path/to/libpow_links.dylib'),
          ),
        ),
      );
    }, skip: !hasRealDylib ? 'Host native libpow_links not available' : null);

    test(
        'isolate runner rejects Future on uncaught isolate crash instead of '
        'stringifying error list', () async {
      await expectLater(
        runPoWIsolateForTesting(_crashingIsolate),
        throwsA(
          isA<RemoteError>().having(
            (e) => e.toString(),
            'toString',
            contains('simulated uncaught isolate error'),
          ),
        ),
      );
    });

    test('isolate runner rejects Future on premature isolate exit without result',
        () async {
      await expectLater(
        runPoWIsolateForTesting(_silentExitIsolate),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('exited without returning a result'),
          ),
        ),
      );
    });

    test(
        'isolate runner rejects Future on error-list message instead of '
        'returning it as a nonce', () async {
      await expectLater(
        runPoWIsolateForTesting(_bogusListMessageIsolate),
        throwsA(
          isA<RemoteError>().having(
            (e) => e.toString(),
            'toString',
            contains('simulated error'),
          ),
        ),
      );
    });

    test('isolate runner rejects Future on unexpected untyped message',
        () async {
      await expectLater(
        runPoWIsolateForTesting(_unexpectedMessageIsolate),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Unexpected message from PoW isolate'),
          ),
        ),
      );
    });
  });
}
