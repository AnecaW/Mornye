import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/navidrome_transfers.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'support/subsonic_fixture.dart';

class TransferStorage extends NavidromeTransferTransport {
  TransferStorage() : super(NetworkStorageService());
  bool failVerification = false;
  final uploaded = <int>[];
  @override
  Future<String> prepare(
    NavidromeTransfer job,
    File file,
    void Function() checkpoint,
  ) async => '${job.folder}${job.relativeDir}/${file.uri.pathSegments.last}';
  @override
  Future<void> publish(
    NavidromeTransfer job,
    File file,
    void Function() checkpoint,
    void Function(int, int) progress,
  ) async {
    checkpoint();
    uploaded
      ..clear()
      ..addAll(await file.readAsBytes());
    progress(uploaded.length, uploaded.length);
    if (failVerification) throw StateError('Verification failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory directory;
  late TransferStorage storage;
  late NavidromeTransfers manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navidrome-transfer-');
    storage = TransferStorage();
    manager = NavidromeTransfers(
      transport: storage,
      directory: () async => directory,
    );
  });
  tearDown(() async {
    manager.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> settled() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (manager.jobs.any(
      (j) => ['queued', 'uploading', 'verifying'].contains(j.status),
    )) {
      if (DateTime.now().isAfter(deadline)) fail('Transfer did not finish');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Restart only after the terminal state is durably published. A fixed
    // sleep races fsync/rename on a loaded CI worker.
    final journal = File('${directory.path}/navidrome_transfers.json');
    final expected = jsonEncode(
      manager.jobs.map((job) => job.toJson()).toList(),
    );
    while (!await journal.exists() ||
        await journal.readAsString() != expected) {
      if (DateTime.now().isAfter(deadline))
        fail('Terminal transfer state was not persisted');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'failed verification preserves original; retry verifies before deletion',
    () async {
      final file = await File(
        '${directory.path}/song.flac',
      ).writeAsBytes([1, 2, 3]);
      storage.failVerification = true;
      await manager.enqueue(
        [(path: file.path, relativeDir: 'Artist/Album')],
        folder: 'network://nas/',
        server: 'navidrome',
        deleteOriginal: true,
      );
      await settled();
      expect(manager.jobs.single.status, 'failed');
      expect(await file.exists(), isTrue);
      storage.failVerification = false;
      await manager.retry(manager.jobs.single);
      await settled();
      expect(manager.jobs.single.status, 'completed');
      expect(storage.uploaded, [1, 2, 3]);
      expect(await file.exists(), isFalse);
    },
  );
  test(
    'iOS original-folder lease permits verified deletion and is always released',
    () async {
      final bookmarks = <String, String>{};
      var workLeases = 0, closedScopes = 0;
      manager.dispose();
      manager = NavidromeTransfers(
        transport: storage,
        directory: () async => directory,
        isIOS: true,
        readScope: (id) async => bookmarks[id],
        writeScope: (id, value) async {
          bookmarks[id] = value;
        },
        openScope: (_) async =>
            IosSecurityScopedAccess(path: directory.path, token: 'owned-lease'),
        closeScope: (_) async {
          closedScopes++;
        },
        beginWork: (_, _) async {
          workLeases++;
          return () async {
            workLeases--;
          };
        },
      );
      final file = await File(
        '${directory.path}/original.flac',
      ).writeAsBytes([4, 5, 6]);
      await manager.enqueue(
        [(path: file.path, relativeDir: 'Artist/Album')],
        folder: 'network://nas/',
        server: 'navidrome',
        deleteOriginal: true,
        bookmark: 'private-access-bookmark',
        scopeRoot: directory.path,
      );
      await settled();
      expect(manager.jobs.single.status, 'completed');
      expect(await file.exists(), isFalse);
      expect(closedScopes, 1);
      expect(workLeases, 0);
      expect(
        await File('${directory.path}/navidrome_transfers.json').readAsString(),
        isNot(contains('private-access-bookmark')),
      );
    },
  );

  test(
    'expired original-folder access preserves the original and releases background work',
    () async {
      var workLeases = 0;
      manager.dispose();
      manager = NavidromeTransfers(
        transport: storage,
        directory: () async => directory,
        isIOS: true,
        readScope: (_) async => 'bookmark',
        writeScope: (_, _) async {},
        openScope: (_) async => null,
        beginWork: (_, _) async {
          workLeases++;
          return () async {
            workLeases--;
          };
        },
      );
      final file = await File(
        '${directory.path}/original.flac',
      ).writeAsBytes([4, 5, 6]);
      await manager.enqueue(
        [(path: file.path, relativeDir: '')],
        folder: 'network://nas/',
        server: 'navidrome',
        deleteOriginal: true,
        bookmark: 'bookmark',
        scopeRoot: directory.path,
      );
      await settled();
      expect(manager.jobs.single.status, 'failed');
      expect(await file.exists(), isTrue);
      expect(workLeases, 0);
      expect(storage.uploaded, isEmpty);
    },
  );

  test('Navidrome scan completion emits a library refresh event', () async {
    final server = await SubsonicFixture.start();
    final network = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
      ensureAccess: (_) async {},
    );
    addTearDown(() async {
      await network.dispose();
      await server.close();
    });
    await network.save(server.connection());
    manager.dispose();
    manager = NavidromeTransfers(
      storage: network,
      transport: storage,
      directory: () async => directory,
    );
    final refreshed = manager.libraryChanges.first;
    await manager.synchronize('fixture');
    expect(await refreshed, 'fixture');
    expect(server.requests.map((r) => r.pathSegments.last), [
      'startScan.view',
      'getScanStatus.view',
    ]);
  });

  test(
    'ordinary upload preserves bytes and local file across restart',
    () async {
      final file = await File(
        '${directory.path}/song.flac',
      ).writeAsBytes([0, 255, 4]);
      await manager.enqueue(
        [(path: file.path, relativeDir: 'Artist/Album')],
        folder: 'network://nas/',
        server: 'navidrome',
      );
      await settled();
      expect(await file.readAsBytes(), storage.uploaded);
      final restarted = NavidromeTransfers(
        transport: storage,
        directory: () async => directory,
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.jobs.single.status, 'completed');
      expect(restarted.jobs.single.target, manager.jobs.single.target);
    },
  );
}
