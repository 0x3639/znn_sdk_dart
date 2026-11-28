import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:argon2_ffi_base/argon2_ffi_base.dart';
import 'package:hex/hex.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:znn_sdk_dart/znn_sdk_dart.dart';

class _FakeLibrary {
  const _FakeLibrary(this.name, {this.hasSymbol = true});

  final String name;
  final bool hasSymbol;
}

String _resolveLocalDesktopBlobPath() {
  final blobsDir =
      path.join(Directory.current.path, 'lib', 'src', 'argon2', 'blobs');
  if (Platform.isMacOS) {
    return path.join(blobsDir, 'libargon2_ffi.dylib');
  }
  if (Platform.isLinux) {
    final plugin = path.join(blobsDir, 'libargon2_ffi_plugin.so');
    if (File(plugin).existsSync()) {
      return plugin;
    }
    return path.join(blobsDir, 'libargon2_ffi.so');
  }
  if (Platform.isWindows) {
    return path.join(blobsDir, 'argon2_ffi_plugin.dll');
  }
  throw UnsupportedError(
      'No local desktop Argon2 blob for ${Platform.operatingSystem}');
}

String _resolveUnrelatedDesktopLibPath() {
  final powBlobsDir =
      path.join(Directory.current.path, 'lib', 'src', 'pow', 'blobs');
  if (Platform.isMacOS) {
    return path.join(powBlobsDir, 'libpow_links.dylib');
  }
  if (Platform.isLinux) {
    return path.join(powBlobsDir, 'libpow_links.so');
  }
  if (Platform.isWindows) {
    return path.join(powBlobsDir, 'libpow_links.dll');
  }
  throw UnsupportedError(
      'No unrelated desktop blob for ${Platform.operatingSystem}');
}

void main() {
  tearDown(() {
    configureArgon2LibraryLoader(null);
  });

  group('Android library resolution', () {
    test('opens libargon2_ffi.so directly without scanning filesystem', () {
      final calls = <String>[];
      var fileExistsCalled = false;
      var pubCacheCalled = false;
      var findPubCacheCalled = false;

      final symbol = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'android',
        openLibrary: (libPath) {
          calls.add('open:$libPath');
          return _FakeLibrary(libPath);
        },
        openProcess: () {
          calls.add('process');
          return const _FakeLibrary('process');
        },
        openExecutable: () {
          calls.add('executable');
          return const _FakeLibrary('executable');
        },
        lookupSymbol: (lib) {
          calls.add('lookup:${lib.name}');
          return 'symbol:${lib.name}';
        },
        fileExists: (_) {
          fileExistsCalled = true;
          return false;
        },
        pubCachePathProvider: () {
          pubCacheCalled = true;
          return '/should-not-be-used';
        },
        findPubCacheLibDirs: (_) {
          findPubCacheCalled = true;
          return const [];
        },
      );

      expect(symbol, 'symbol:libargon2_ffi.so');
      expect(calls, ['open:libargon2_ffi.so', 'lookup:libargon2_ffi.so']);
      expect(fileExistsCalled, isFalse);
      expect(pubCacheCalled, isFalse);
      expect(findPubCacheCalled, isFalse);
    });

    test('propagates ArgumentError when libargon2_ffi.so cannot be opened', () {
      expect(
        () => resolveArgon2SymbolForTesting<_FakeLibrary, String>(
          operatingSystem: 'android',
          openLibrary: (libPath) =>
              throw ArgumentError('dlopen failed: $libPath not found'),
          openProcess: () => const _FakeLibrary('process'),
          openExecutable: () => const _FakeLibrary('executable'),
          lookupSymbol: (lib) => lib.name,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('iOS library resolution', () {
    test('uses dynamic argon2_ffi.framework first when available', () {
      final calls = <String>[];
      var fileExistsCalled = false;
      var pubCacheCalled = false;

      final symbol = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'ios',
        openLibrary: (libPath) {
          calls.add('open:$libPath');
          return _FakeLibrary(libPath);
        },
        openProcess: () {
          calls.add('process');
          return const _FakeLibrary('process');
        },
        openExecutable: () {
          calls.add('executable');
          return const _FakeLibrary('executable');
        },
        lookupSymbol: (lib) {
          calls.add('lookup:${lib.name}');
          if (!lib.hasSymbol) {
            throw ArgumentError('Symbol hp_argon2_hash not found');
          }
          return 'symbol:${lib.name}';
        },
        fileExists: (_) {
          fileExistsCalled = true;
          return false;
        },
        pubCachePathProvider: () {
          pubCacheCalled = true;
          return '/should-not-be-used';
        },
      );

      expect(symbol, 'symbol:argon2_ffi.framework/argon2_ffi');
      expect(calls, [
        'open:argon2_ffi.framework/argon2_ffi',
        'lookup:argon2_ffi.framework/argon2_ffi',
      ]);
      expect(fileExistsCalled, isFalse);
      expect(pubCacheCalled, isFalse);
    });

    test('falls back from framework open failure to DynamicLibrary.process()',
        () {
      final calls = <String>[];

      final symbol = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'ios',
        openLibrary: (libPath) {
          calls.add('open:$libPath');
          throw ArgumentError('framework not embedded');
        },
        openProcess: () {
          calls.add('process');
          return const _FakeLibrary('process');
        },
        openExecutable: () {
          calls.add('executable');
          return const _FakeLibrary('executable');
        },
        lookupSymbol: (lib) {
          calls.add('lookup:${lib.name}');
          return 'symbol:${lib.name}';
        },
      );

      expect(symbol, 'symbol:process');
      expect(calls, [
        'open:argon2_ffi.framework/argon2_ffi',
        'process',
        'lookup:process',
      ]);
    });

    test(
        'falls back through framework -> process -> executable when symbol is missing',
        () {
      final calls = <String>[];

      final symbol = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'ios',
        openLibrary: (libPath) {
          calls.add('open:$libPath');
          return _FakeLibrary(libPath, hasSymbol: false);
        },
        openProcess: () {
          calls.add('process');
          return const _FakeLibrary('process', hasSymbol: false);
        },
        openExecutable: () {
          calls.add('executable');
          return const _FakeLibrary('executable', hasSymbol: true);
        },
        lookupSymbol: (lib) {
          calls.add('lookup:${lib.name}');
          if (!lib.hasSymbol) {
            throw ArgumentError('Symbol hp_argon2_hash not found');
          }
          return 'symbol:${lib.name}';
        },
      );

      expect(symbol, 'symbol:executable');
      expect(calls, [
        'open:argon2_ffi.framework/argon2_ffi',
        'lookup:argon2_ffi.framework/argon2_ffi',
        'process',
        'lookup:process',
        'executable',
        'lookup:executable',
      ]);
    });

    test('throws invalidArgon2LibPathException when all iOS fallbacks fail',
        () {
      final calls = <String>[];

      expect(
        () => resolveArgon2SymbolForTesting<_FakeLibrary, String>(
          operatingSystem: 'ios',
          openLibrary: (libPath) {
            calls.add('open:$libPath');
            throw ArgumentError('framework missing');
          },
          openProcess: () {
            calls.add('process');
            return const _FakeLibrary('process', hasSymbol: false);
          },
          openExecutable: () {
            calls.add('executable');
            return const _FakeLibrary('executable', hasSymbol: false);
          },
          lookupSymbol: (lib) {
            calls.add('lookup:${lib.name}');
            throw ArgumentError('symbol missing');
          },
        ),
        throwsA(same(invalidArgon2LibPathException)),
      );

      expect(calls, [
        'open:argon2_ffi.framework/argon2_ffi',
        'process',
        'lookup:process',
        'executable',
        'lookup:executable',
      ]);
    });
  });

  group('Desktop library resolution', () {
    test('macOS resolves libargon2_ffi.dylib from bundle Resources directory',
        () {
      final expectedPath =
          path.join('/Applications/Syrius.app/Contents', 'Resources', 'libargon2_ffi.dylib');
      var pubCacheCalled = false;

      final symbol = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'macos',
        currentDirectoryPath: '/work/app',
        resolvedExecutablePath:
            '/Applications/Syrius.app/Contents/MacOS/syrius',
        openLibrary: (libPath) => _FakeLibrary(libPath),
        openProcess: () => const _FakeLibrary('process'),
        openExecutable: () => const _FakeLibrary('executable'),
        lookupSymbol: (lib) => lib.name,
        fileExists: (candidate) => candidate == expectedPath,
        pubCachePathProvider: () {
          pubCacheCalled = true;
          return '/unused';
        },
      );

      expect(symbol, expectedPath);
      expect(pubCacheCalled, isFalse);
    });

    test(
        'Linux prefers libargon2_ffi_plugin.so and falls back to libargon2_ffi.so',
        () {
      final pluginPath = path.join('/opt/syrius/lib', 'libargon2_ffi_plugin.so');
      final fallbackPath = path.join('/opt/syrius/lib', 'libargon2_ffi.so');

      final preferred = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'linux',
        currentDirectoryPath: '/work/app',
        resolvedExecutablePath: '/opt/syrius/syrius',
        openLibrary: (libPath) => _FakeLibrary(libPath),
        openProcess: () => const _FakeLibrary('process'),
        openExecutable: () => const _FakeLibrary('executable'),
        lookupSymbol: (lib) => lib.name,
        fileExists: (candidate) =>
            candidate == pluginPath || candidate == fallbackPath,
        pubCachePathProvider: () => '',
      );
      expect(preferred, pluginPath);

      final fallback = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'linux',
        currentDirectoryPath: '/work/app',
        resolvedExecutablePath: '/opt/syrius/syrius',
        openLibrary: (libPath) => _FakeLibrary(libPath),
        openProcess: () => const _FakeLibrary('process'),
        openExecutable: () => const _FakeLibrary('executable'),
        lookupSymbol: (lib) => lib.name,
        fileExists: (candidate) => candidate == fallbackPath,
        pubCachePathProvider: () => '',
      );
      expect(fallback, fallbackPath);
    });

    test('Windows resolves argon2_ffi_plugin.dll', () {
      final expectedPath = path.join('/app/bin', 'argon2_ffi_plugin.dll');

      final symbol = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'windows',
        currentDirectoryPath: '/work/app',
        resolvedExecutablePath: '/app/bin/syrius.exe',
        openLibrary: (libPath) => _FakeLibrary(libPath),
        openProcess: () => const _FakeLibrary('process'),
        openExecutable: () => const _FakeLibrary('executable'),
        lookupSymbol: (lib) => lib.name,
        fileExists: (candidate) => candidate == expectedPath,
        pubCachePathProvider: () => '',
      );

      expect(symbol, expectedPath);
    });

    test('falls back to pub cache directory when not found locally', () {
      final pubCacheBlobDir = '/home/user/.pub-cache/git/znn_sdk_dart/blobs';
      final expectedPath = path.join(pubCacheBlobDir, 'libargon2_ffi.dylib');

      final symbol = resolveArgon2SymbolForTesting<_FakeLibrary, String>(
        operatingSystem: 'macos',
        currentDirectoryPath: '/work/app',
        resolvedExecutablePath: '/usr/local/bin/dart',
        openLibrary: (libPath) => _FakeLibrary(libPath),
        openProcess: () => const _FakeLibrary('process'),
        openExecutable: () => const _FakeLibrary('executable'),
        lookupSymbol: (lib) => lib.name,
        fileExists: (candidate) => candidate == expectedPath,
        pubCachePathProvider: () => '/home/user/.pub-cache',
        findPubCacheLibDirs: (_) => [pubCacheBlobDir],
      );

      expect(symbol, expectedPath);
    });

    test('safely guards throwing or empty getPubCachePath()', () {
      for (final provider in <String? Function()>[
        () => '',
        () => null,
        () => throw StateError('HOME not set'),
      ]) {
        expect(
          () => resolveArgon2SymbolForTesting<_FakeLibrary, String>(
            operatingSystem: 'macos',
            currentDirectoryPath: '/nonexistent/app',
            resolvedExecutablePath: '/nonexistent/bin/dart',
            openLibrary: (libPath) => _FakeLibrary(libPath),
            openProcess: () => const _FakeLibrary('process'),
            openExecutable: () => const _FakeLibrary('executable'),
            lookupSymbol: (lib) => lib.name,
            fileExists: (_) => false,
            pubCachePathProvider: provider,
          ),
          throwsA(same(invalidArgon2LibPathException)),
        );
      }
    });

    test('throws UnsupportedError for unsupported operating system', () {
      expect(
        () => resolveArgon2SymbolForTesting<_FakeLibrary, String>(
          operatingSystem: 'fuchsia',
          openLibrary: (libPath) => _FakeLibrary(libPath),
          openProcess: () => const _FakeLibrary('process'),
          openExecutable: () => const _FakeLibrary('executable'),
          lookupSymbol: (lib) => lib.name,
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('Custom loader hook and real desktop FFI', () {
    const knownPassword = 'correct-horse-battery-staple';
    const knownSaltHex = '5b85100f186953332faddeaf2b6d68de';
    // Reference hash produced by znn_sdk_dart v1.1.0 (Argon2FfiFlutter)
    const knownArgon2IdHashHex =
        '849184e08bc3dea57a38086243c16ff7f1c95bc998b4221a298a758818709907';
    // Known EncryptedFile JSON fixture produced by znn_sdk_dart v1.1.0
    const knownEncryptedFileJson =
        '{"baseAddress":"z1qqjnwjjpnue8xmmpanz6csze6tcmtzzdtfsww7",'
        '"walletType":"keystore",'
        '"crypto":{"argon2Params":{"salt":"0x684deedff58851a86c5c0922436dd0ba"},'
        '"cipherData":"0xd30adc119dd3874ce1a72de669d9a4264aa6249222e66fccceacbcef303f8f0d34fcec1e950848526c70c7",'
        '"cipherName":"aes-256-gcm","kdf":"argon2.IDKey",'
        '"nonce":"0x2e78a5c179b25c0a07d3349f"},'
        '"timestamp":1795900210,"version":1}';

    test('configureArgon2LibraryLoader injects custom loader and resets cleanly',
        () {
      final blobPath = _resolveLocalDesktopBlobPath();
      var loaderCalls = 0;

      configureArgon2LibraryLoader(() {
        loaderCalls++;
        return DynamicLibrary.open(blobPath);
      });

      final customArgon2 = initArgon2();
      expect(loaderCalls, 1);
      expect(customArgon2.isFfi, isTrue);
      expect(customArgon2.isImplemented, isTrue);

      final derived = customArgon2.argon2(Argon2Arguments(
        Uint8List.fromList(utf8.encode(knownPassword)),
        Uint8List.fromList(HEX.decode(knownSaltHex)),
        64 * 1024,
        1,
        32,
        4,
        2,
        13,
      ));
      expect(HEX.encode(derived), knownArgon2IdHashHex);

      // Reset to default platform loader and verify custom loader is no longer used.
      configureArgon2LibraryLoader(null);
      final defaultArgon2 = initArgon2();
      expect(loaderCalls, 1);

      final defaultDerived = defaultArgon2.argon2(Argon2Arguments(
        Uint8List.fromList(utf8.encode(knownPassword)),
        Uint8List.fromList(HEX.decode(knownSaltHex)),
        64 * 1024,
        1,
        32,
        4,
        2,
        13,
      ));
      expect(HEX.encode(defaultDerived), knownArgon2IdHashHex);
    });

    test('custom loader missing hp_argon2_hash throws ArgumentError', () {
      final unrelatedLibPath = _resolveUnrelatedDesktopLibPath();
      configureArgon2LibraryLoader(() => DynamicLibrary.open(unrelatedLibPath));
      expect(initArgon2, throwsA(isA<ArgumentError>()));
    });

    test('initArgon2().argon2 matches Argon2FfiFlutter bit-for-bit', () async {
      final blobPath = _resolveLocalDesktopBlobPath();
      final previousForceDynamic = Argon2.resolveLibraryForceDynamic;
      addTearDown(() {
        Argon2.resolveLibraryForceDynamic = previousForceDynamic;
      });
      if (Platform.isMacOS) {
        Argon2.resolveLibraryForceDynamic = true;
      }

      final reference = Argon2FfiFlutter(resolveLibrary: (_) => blobPath);
      final direct = initArgon2();
      final salt = Uint8List.fromList(HEX.decode(knownSaltHex));

      for (final type in [0, 1, 2]) {
        final args = Argon2Arguments(
          Uint8List.fromList(utf8.encode(knownPassword)),
          salt,
          64 * 1024,
          1,
          32,
          4,
          type,
          13,
        );
        final expected = reference.argon2(args);
        final actual = direct.argon2(args);
        final actualAsync = await direct.argon2Async(args);

        expect(actual, expected);
        expect(actualAsync, expected);
        if (type == 2) {
          expect(HEX.encode(actual), knownArgon2IdHashHex);
        }
      }

      // Verify empty key edge case frees buffers safely and matches reference.
      final emptyKeyArgs = Argon2Arguments(
        Uint8List(0),
        salt,
        1024,
        1,
        32,
        1,
        2,
        13,
      );
      expect(direct.argon2(emptyKeyArgs), reference.argon2(emptyKeyArgs));
    });

    test(
        'EncryptedFile encrypt/decrypt round-trip and IncorrectPasswordException',
        () async {
      final plaintext = utf8.encode('znn-wallet-secret-seed-payload');
      final encrypted = await EncryptedFile.encrypt(
        plaintext,
        'super-secret-passphrase',
        metadata: {'walletType': 'keystore'},
      );

      final roundTripped = EncryptedFile.fromJson(
        jsonDecode(jsonEncode(encrypted.toJson())) as Map<String, dynamic>,
      );

      final decrypted = await roundTripped.decrypt('super-secret-passphrase');
      expect(decrypted, plaintext);
      expect(roundTripped.metadata, {'walletType': 'keystore'});

      await expectLater(
        () => roundTripped.decrypt('wrong-passphrase'),
        throwsA(isA<IncorrectPasswordException>()),
      );
    });

    test('decrypts known v1.1.0 EncryptedFile JSON fixture', () async {
      final fixture = EncryptedFile.fromJson(
        jsonDecode(knownEncryptedFileJson) as Map<String, dynamic>,
      );

      final decrypted = await fixture.decrypt(knownPassword);
      expect(utf8.decode(decrypted), 'zenon-mobile-argon2-fixture');
      expect(fixture.metadata, {
        'baseAddress': 'z1qqjnwjjpnue8xmmpanz6csze6tcmtzzdtfsww7',
        'walletType': 'keystore',
      });

      await expectLater(
        () => fixture.decrypt('not-the-right-password'),
        throwsA(isA<IncorrectPasswordException>()),
      );
    });
  });
}
