import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:znn_sdk_dart/znn_sdk_dart.dart';

class _FakeWalletManager implements WalletManager {
  @override
  Future<Iterable<WalletDefinition>> getWalletDefinitions() async => const [];

  @override
  Future<Wallet> getWallet(
    WalletDefinition walletDefinition, [
    WalletOptions? options,
  ]) {
    throw UnimplementedError();
  }

  @override
  Future<bool> supportsWallet(WalletDefinition walletDefinition) async => false;
}

void main() {
  tearDown(() {
    Zenon().resetKeyStoreManager();
    resetZnnPathsForTesting();
  });

  group('Zenon lazy initialization on mobile', () {
    // Keep this first so Zenon._internal() runs under simulated Android before
    // any desktop paths have been resolved.
    test(
      'Zenon() does not eagerly resolve paths on unconfigured Android',
      () {
        resetZnnPathsForTesting(
          operatingSystem: 'android',
          environment: const {},
        );

        final zenon = Zenon();
        expect(zenon, same(Zenon()));

        expect(
          () => zenon.keyStoreManager,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('android'), contains('configureZnnPaths')),
            ),
          ),
        );

        final tempDir = Directory.systemTemp.createTempSync('znn_mobile_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final walletDir = Directory(path.join(tempDir.path, 'wallet'));
        configureZnnPaths(
          ZnnPaths(
            main: Directory(path.join(tempDir.path, 'main')),
            wallet: walletDir,
            cache: Directory(path.join(tempDir.path, 'cache')),
          ),
        );

        final manager = zenon.keyStoreManager;
        expect(manager, isA<KeyStoreManager>());
        expect((manager as KeyStoreManager).walletPath.path, walletDir.path);
      },
    );
  });

  group('configureZnnPaths and ensureDirectoriesExist', () {
    test(
      'configureZnnPaths overrides all four getters and ensureDirectoriesExist creates them',
      () {
        final tempDir = Directory.systemTemp.createTempSync('znn_paths_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        // Use sibling directories so main is not an implicit ancestor of
        // wallet or cache.
        final mainDir = Directory(path.join(tempDir.path, 'main'));
        final walletDir = Directory(path.join(tempDir.path, 'wallet'));
        final cacheDir = Directory(path.join(tempDir.path, 'cache'));
        final configured = ZnnPaths(
          main: mainDir,
          wallet: walletDir,
          cache: cacheDir,
        );

        configureZnnPaths(configured);

        expect(znnDefaultPaths, same(configured));
        expect(znnDefaultDirectory.path, mainDir.path);
        expect(znnDefaultWalletDirectory.path, walletDir.path);
        expect(znnDefaultCacheDirectory.path, cacheDir.path);

        expect(mainDir.existsSync(), isFalse);
        expect(walletDir.existsSync(), isFalse);
        expect(cacheDir.existsSync(), isFalse);

        ensureDirectoriesExist();

        expect(mainDir.existsSync(), isTrue);
        expect(walletDir.existsSync(), isTrue);
        expect(cacheDir.existsSync(), isTrue);

        // Idempotent on repeat calls.
        expect(ensureDirectoriesExist, returnsNormally);
      },
    );
  });

  group('Individual path setters and Syrius compatibility', () {
    test(
      'matches Syrius desktop _configureZnnDataDirectories() mutation pattern',
      () {
        final tempHome = Directory.systemTemp.createTempSync('znn_syrius_');
        addTearDown(() => tempHome.deleteSync(recursive: true));

        resetZnnPathsForTesting(
          operatingSystem: 'macos',
          environment: {'HOME': tempHome.path},
        );

        final customRoot = Directory(
          path.join(znnDefaultDirectory.parent.path, 'znn-custom'),
        );
        znnDefaultPaths = ZnnPaths(
          main: customRoot,
          wallet: Directory(path.join(customRoot.path, 'wallet')),
          cache: Directory(path.join(customRoot.path, 'syrius')),
        );
        znnDefaultDirectory = znnDefaultPaths.main;
        znnDefaultWalletDirectory = znnDefaultPaths.wallet;
        znnDefaultCacheDirectory = znnDefaultPaths.cache;

        expect(znnDefaultPaths.main.path, customRoot.path);
        expect(znnDefaultDirectory.path, customRoot.path);
        expect(
          znnDefaultWalletDirectory.path,
          path.join(customRoot.path, 'wallet'),
        );
        expect(
          znnDefaultCacheDirectory.path,
          path.join(customRoot.path, 'syrius'),
        );

        ensureDirectoriesExist();
        expect(znnDefaultDirectory.existsSync(), isTrue);
        expect(znnDefaultWalletDirectory.existsSync(), isTrue);
        expect(znnDefaultCacheDirectory.existsSync(), isTrue);
      },
    );

    test(
      'mutating individual setters keeps znnDefaultPaths and getters in sync',
      () {
        final tempDir = Directory.systemTemp.createTempSync('znn_setters_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        resetZnnPathsForTesting(
          operatingSystem: 'linux',
          environment: {'HOME': tempDir.path},
        );

        final customMain = Directory(path.join(tempDir.path, 'custom_main'));
        final customWallet = Directory(
          path.join(tempDir.path, 'custom_wallet'),
        );
        final customCache = Directory(path.join(tempDir.path, 'custom_cache'));

        znnDefaultDirectory = customMain;
        expect(znnDefaultDirectory.path, customMain.path);
        expect(znnDefaultPaths.main.path, customMain.path);
        expect(
          znnDefaultWalletDirectory.path,
          path.join(tempDir.path, '.znn', 'wallet'),
        );
        expect(
          znnDefaultCacheDirectory.path,
          path.join(tempDir.path, '.znn', 'syrius'),
        );

        znnDefaultWalletDirectory = customWallet;
        expect(znnDefaultWalletDirectory.path, customWallet.path);
        expect(znnDefaultPaths.wallet.path, customWallet.path);

        znnDefaultCacheDirectory = customCache;
        expect(znnDefaultCacheDirectory.path, customCache.path);
        expect(znnDefaultPaths.cache.path, customCache.path);
      },
    );
  });

  group('Platform default path resolution', () {
    test('resolves Linux default paths (~/.znn)', () {
      resetZnnPathsForTesting(
        operatingSystem: 'linux',
        environment: const {'HOME': '/home/alice'},
      );

      final expectedMain = path.join('/home/alice', '.znn');
      expect(znnDefaultDirectory.path, expectedMain);
      expect(znnDefaultWalletDirectory.path, path.join(expectedMain, 'wallet'));
      expect(znnDefaultCacheDirectory.path, path.join(expectedMain, 'syrius'));
    });

    test('resolves macOS default paths (~/Library/znn)', () {
      resetZnnPathsForTesting(
        operatingSystem: 'macos',
        environment: const {'HOME': '/Users/alice'},
      );

      final expectedMain = path.join('/Users/alice', 'Library', 'znn');
      expect(znnDefaultDirectory.path, expectedMain);
      expect(znnDefaultWalletDirectory.path, path.join(expectedMain, 'wallet'));
      expect(znnDefaultCacheDirectory.path, path.join(expectedMain, 'syrius'));
    });

    test('resolves Windows default paths (%AppData%/znn)', () {
      const appData = r'C:\Users\alice\AppData\Roaming';
      resetZnnPathsForTesting(
        operatingSystem: 'windows',
        environment: const {'AppData': appData},
      );

      final expectedMain = path.join(appData, 'znn');
      expect(znnDefaultDirectory.path, expectedMain);
      expect(znnDefaultWalletDirectory.path, path.join(expectedMain, 'wallet'));
      expect(znnDefaultCacheDirectory.path, path.join(expectedMain, 'syrius'));
    });

    test('throws descriptive StateError when desktop HOME/AppData is unset', () {
      resetZnnPathsForTesting(
        operatingSystem: 'linux',
        environment: const {},
      );
      expect(
        () => znnDefaultPaths,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('HOME'), contains('configureZnnPaths')),
          ),
        ),
      );

      resetZnnPathsForTesting(
        operatingSystem: 'windows',
        environment: const {},
      );
      expect(
        () => znnDefaultDirectory,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('AppData'), contains('configureZnnPaths')),
          ),
        ),
      );
    });

    for (final mobileOs in ['android', 'ios']) {
      test(
        'throws descriptive StateError on unconfigured $mobileOs and succeeds once configured',
        () {
          // Even if HOME is populated in the sandbox environment, mobile
          // must still require explicit configuration.
          resetZnnPathsForTesting(
            operatingSystem: mobileOs,
            environment: const {'HOME': '/sandbox/home'},
          );

          final matcher = throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains(mobileOs), contains('configureZnnPaths')),
            ),
          );

          expect(() => znnDefaultPaths, matcher);
          expect(() => znnDefaultDirectory, matcher);
          expect(() => znnDefaultWalletDirectory, matcher);
          expect(() => znnDefaultCacheDirectory, matcher);
          expect(ensureDirectoriesExist, matcher);

          final tempDir = Directory.systemTemp.createTempSync('znn_$mobileOs');
          addTearDown(() => tempDir.deleteSync(recursive: true));

          final paths = ZnnPaths(
            main: Directory(path.join(tempDir.path, 'znn')),
            wallet: Directory(path.join(tempDir.path, 'znn', 'wallet')),
            cache: Directory(path.join(tempDir.path, 'cache', 'syrius')),
          );
          configureZnnPaths(paths);

          expect(znnDefaultPaths, same(paths));
          expect(znnDefaultDirectory.path, paths.main.path);
          expect(znnDefaultWalletDirectory.path, paths.wallet.path);
          expect(znnDefaultCacheDirectory.path, paths.cache.path);

          ensureDirectoriesExist();
          expect(paths.main.existsSync(), isTrue);
          expect(paths.wallet.existsSync(), isTrue);
          expect(paths.cache.existsSync(), isTrue);
        },
      );
    }
  });

  group('getPubCachePath', () {
    test('uses PUB_CACHE when set and non-empty', () {
      resetZnnPathsForTesting(
        operatingSystem: 'android',
        environment: const {'PUB_CACHE': '/custom/pub-cache'},
      );
      expect(getPubCachePath(), Directory('/custom/pub-cache').path);
    });

    test('returns empty string safely when HOME is missing on desktop', () {
      resetZnnPathsForTesting(
        operatingSystem: 'linux',
        environment: const {},
      );
      final pubCachePath = getPubCachePath();
      expect(pubCachePath, isEmpty);
      expect(Directory(pubCachePath).existsSync(), isFalse);
    });

    test('returns empty string safely on Android and iOS without PUB_CACHE', () {
      for (final mobileOs in ['android', 'ios']) {
        resetZnnPathsForTesting(
          operatingSystem: mobileOs,
          environment: const {'HOME': '/sandbox/home'},
        );
        final pubCachePath = getPubCachePath();
        expect(pubCachePath, isEmpty);
        expect(Directory(pubCachePath).existsSync(), isFalse);
      }
    });

    test('returns HOME/.pub-cache on macOS and Linux when HOME is set', () {
      resetZnnPathsForTesting(
        operatingSystem: 'macos',
        environment: const {'HOME': '/Users/alice'},
      );
      expect(
        getPubCachePath(),
        Directory(path.join('/Users/alice', '.pub-cache')).path,
      );
    });

    test('handles Windows APPDATA/LOCALAPPDATA safely including missing env', () {
      final tempDir = Directory.systemTemp.createTempSync('znn_win_pub_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final existingAppDataCache = Directory(
        path.join(tempDir.path, 'Pub', 'Cache'),
      )..createSync(recursive: true);

      resetZnnPathsForTesting(
        operatingSystem: 'windows',
        environment: {
          'APPDATA': tempDir.path,
          'LOCALAPPDATA': '/local/appdata',
        },
      );
      expect(getPubCachePath(), existingAppDataCache.path);

      resetZnnPathsForTesting(
        operatingSystem: 'windows',
        environment: {
          'APPDATA': path.join(tempDir.path, 'missing'),
          'LOCALAPPDATA': '/local/appdata',
        },
      );
      expect(
        getPubCachePath(),
        Directory(path.join('/local/appdata', 'Pub', 'Cache')).path,
      );

      resetZnnPathsForTesting(
        operatingSystem: 'windows',
        environment: const {},
      );
      expect(getPubCachePath(), isEmpty);
      expect(Directory(getPubCachePath()).existsSync(), isFalse);
    });
  });

  group('Zenon().keyStoreManager', () {
    test(
      'reflects configured walletPath, caches instance, and refreshes on path changes',
      () {
        final tempDir = Directory.systemTemp.createTempSync('znn_ksm_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final walletA = Directory(path.join(tempDir.path, 'wallet_a'));
        final walletB = Directory(path.join(tempDir.path, 'wallet_b'));
        final walletC = Directory(path.join(tempDir.path, 'wallet_c'));

        configureZnnPaths(
          ZnnPaths(
            main: tempDir,
            wallet: walletA,
            cache: Directory(path.join(tempDir.path, 'cache')),
          ),
        );

        final first = Zenon().keyStoreManager;
        final second = Zenon().keyStoreManager;
        expect(first, isA<KeyStoreManager>());
        expect(second, same(first));
        expect((first as KeyStoreManager).walletPath.path, walletA.path);

        configureZnnPaths(
          ZnnPaths(
            main: tempDir,
            wallet: walletB,
            cache: Directory(path.join(tempDir.path, 'cache')),
          ),
        );

        final refreshed = Zenon().keyStoreManager;
        expect(refreshed, isA<KeyStoreManager>());
        expect(refreshed, isNot(same(first)));
        expect((refreshed as KeyStoreManager).walletPath.path, walletB.path);

        znnDefaultWalletDirectory = walletC;

        final afterSetter = Zenon().keyStoreManager;
        expect(afterSetter, isA<KeyStoreManager>());
        expect(afterSetter, isNot(same(refreshed)));
        expect((afterSetter as KeyStoreManager).walletPath.path, walletC.path);
      },
    );

    test(
      'supports custom WalletManager override without being clobbered by configureZnnPaths',
      () {
        final tempDir = Directory.systemTemp.createTempSync('znn_custom_wm_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        resetZnnPathsForTesting(
          operatingSystem: 'ios',
          environment: const {},
        );

        final customManager = _FakeWalletManager();
        Zenon().keyStoreManager = customManager;

        // Custom override works even when mobile paths are unconfigured.
        expect(Zenon().keyStoreManager, same(customManager));

        final walletDir = Directory(path.join(tempDir.path, 'wallet'));
        configureZnnPaths(
          ZnnPaths(
            main: tempDir,
            wallet: walletDir,
            cache: Directory(path.join(tempDir.path, 'cache')),
          ),
        );

        // configureZnnPaths must not overwrite an explicit custom WalletManager.
        expect(Zenon().keyStoreManager, same(customManager));

        // Resetting restores the default lazy KeyStoreManager.
        Zenon().resetKeyStoreManager();
        final restored = Zenon().keyStoreManager;
        expect(restored, isA<KeyStoreManager>());
        expect((restored as KeyStoreManager).walletPath.path, walletDir.path);
      },
    );
  });
}
