import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/services/platform_bridge.dart';

class NavidromeTransfer {
  NavidromeTransfer({
    required this.id,
    required this.local,
    required this.folder,
    required this.relativeDir,
    required this.server,
    this.deleteOriginal = false,
    this.target,
    this.status = 'queued',
    this.scopeId,
    this.scopedRelativePath,
  });
  final String id, local, folder, relativeDir, server;
  final bool deleteOriginal;
  final String? scopeId, scopedRelativePath;
  String? target, error;
  String status;
  int sent = 0, total = 0;
  bool cancelled = false;
  final clock = Stopwatch();
  double get speed => clock.elapsedMilliseconds > 0
      ? sent * 1000 / clock.elapsedMilliseconds
      : 0;
  int? get remainingSeconds =>
      speed > 0 ? ((total - sent) / speed).ceil() : null;
  Map<String, dynamic> toJson() => {
    'id': id,
    'local': local,
    'folder': folder,
    'relativeDir': relativeDir,
    'server': server,
    'deleteOriginal': deleteOriginal,
    'target': target,
    'status': status,
    'error': error,
    'scopeId': scopeId,
    'scopedRelativePath': scopedRelativePath,
  };
  factory NavidromeTransfer.fromJson(Map<String, dynamic> row) {
    final status = row['status'] as String;
    return NavidromeTransfer(
        id: row['id'] as String,
        local: row['local'] as String,
        folder: row['folder'] as String,
        relativeDir: row['relativeDir'] as String,
        server: row['server'] as String,
        target: row['target'] as String?,
        deleteOriginal: row['deleteOriginal'] == true,
        scopeId: row['scopeId'] as String?,
        scopedRelativePath: row['scopedRelativePath'] as String?,
        status: ['completed', 'cancelled', 'failed'].contains(status)
            ? status
            : 'failed',
      )
      ..error = ['completed', 'cancelled', 'failed'].contains(status)
          ? row['error'] as String?
          : 'Interrupted. Retry to verify or finish the upload.';
  }
}

/// Process-owned queue: navigation never owns or cancels transfers. A durable
/// journal retains destinations across retries and stores no server credentials.
class NavidromeTransferTransport {
  NavidromeTransferTransport(this.storage);
  final NetworkStorageService storage;
  Future<String> prepare(
    NavidromeTransfer job,
    File file,
    void Function() check,
  ) => storage.prepareUpload(
    job.folder,
    job.relativeDir,
    p.basename(job.local),
    matchingFile: file,
    checkpoint: check,
  );
  Future<void> publish(
    NavidromeTransfer job,
    File file,
    void Function() check,
    void Function(int, int) progress,
  ) => storage.publishUpload(
    job.target!,
    file,
    job.id,
    checkpoint: check,
    progress: progress,
  );
}

class NavidromeTransfers extends ChangeNotifier {
  NavidromeTransfers({
    NetworkStorageService? storage,
    NavidromeTransferTransport? transport,
    Future<Directory> Function()? directory,
    Future<Future<void> Function()> Function(String id, String name)? beginWork,
    Future<String?> Function(String)? readScope,
    Future<void> Function(String, String)? writeScope,
    Future<IosSecurityScopedAccess?> Function(String)? openScope,
    Future<void> Function(IosSecurityScopedAccess)? closeScope,
    bool? isIOS,
  }) : storage = storage ?? NetworkStorageService.instance,
       _transport =
           transport ??
           NavidromeTransferTransport(
             storage ?? NetworkStorageService.instance,
           ),
       _directory = directory ?? getApplicationSupportDirectory,
       _beginWork = beginWork ?? _beginBackgroundWork,
       _readScope =
           readScope ??
           ((id) => _secure.read(key: 'navidrome_upload_scope_$id')),
       _writeScope =
           writeScope ??
           ((id, value) =>
               _secure.write(key: 'navidrome_upload_scope_$id', value: value)),
       _openScope = openScope ?? PlatformBridge.startAccessingIosBookmark,
       _closeScope = closeScope ?? PlatformBridge.stopAccessingIosBookmark,
       _isIOS = isIOS ?? Platform.isIOS;
  static final instance = NavidromeTransfers();
  final NetworkStorageService storage;
  final NavidromeTransferTransport _transport;
  final Future<Directory> Function() _directory;
  static const _secure = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  final Future<String?> Function(String) _readScope;
  final Future<void> Function(String, String) _writeScope;
  final Future<IosSecurityScopedAccess?> Function(String) _openScope;
  final Future<void> Function(IosSecurityScopedAccess) _closeScope;
  final bool _isIOS;
  final Future<Future<void> Function()> Function(String id, String name)
  _beginWork;
  static Future<Future<void> Function()> _beginBackgroundWork(
    String id,
    String name,
  ) async {
    final notifications = NotificationService();
    final kind = 'navidrome_transfer_$id';
    await notifications.beginBackgroundWork(kind, title: 'Uploading $name');
    return () => notifications.endBackgroundWork(kind);
  }

  final jobs = <NavidromeTransfer>[];
  Future<void>? _loaded;
  bool _running = false;
  bool _disposed = false;
  final _libraryChanges = StreamController<String>.broadcast();
  Stream<String> get libraryChanges => _libraryChanges.stream;
  final scanMessages = <String, String>{};
  final _scans = <String, Future<void>>{};
  final _scanAgain = <String>{};
  final _localChanges = StreamController<String>.broadcast();
  Stream<String> get localChanges => _localChanges.stream;
  Future<void> _writes = Future.value();
  Future<File> _journal() async =>
      File(p.join((await _directory()).path, 'navidrome_transfers.json'));
  Future<void> initialize() => _loaded ??= () async {
    final file = await _journal();
    if (await file.exists()) {
      final rows = jsonDecode(await file.readAsString()) as List;
      jobs.addAll(
        rows.map(
          (r) =>
              NavidromeTransfer.fromJson(Map<String, dynamic>.from(r as Map)),
        ),
      );
    }
    notifyListeners();
  }();
  Future<void> _save() {
    final snapshot = jsonEncode(jobs.map((j) => j.toJson()).toList());
    final result = _writes.then((_) async {
      final file = await _journal();
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(file.path);
    });
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<void> enqueue(
    List<({String path, String relativeDir})> files, {
    required String folder,
    required String server,
    bool deleteOriginal = false,
    String? bookmark,
    String? scopeRoot,
  }) async {
    await initialize();
    String? scopeId;
    if (bookmark != null) {
      if (scopeRoot == null ||
          files.any((file) => !p.isWithin(scopeRoot, file.path))) {
        throw ArgumentError(
          'Files must remain inside the selected original folder',
        );
      }
      scopeId = NetworkStorageService.newId();
      await _writeScope(scopeId, bookmark);
    }
    for (final file in files) {
      if (jobs.any(
        (j) =>
            j.local == file.path &&
            j.folder == folder &&
            ['queued', 'uploading', 'verifying'].contains(j.status),
      )) {
        continue;
      }
      jobs.add(
        NavidromeTransfer(
          id: NetworkStorageService.newId(),
          local: file.path,
          folder: folder,
          relativeDir: file.relativeDir,
          server: server,
          deleteOriginal: deleteOriginal,
          scopeId: scopeId,
          scopedRelativePath: scopeId == null
              ? null
              : p.relative(file.path, from: scopeRoot!),
        ),
      );
    }
    await _save();
    notifyListeners();
    unawaited(_run());
  }

  Future<void> retry(NavidromeTransfer job) async {
    if (!['failed', 'cancelled'].contains(job.status)) return;
    job.cancelled = false;
    job.error = null;
    job.status = 'queued';
    await _save();
    notifyListeners();
    unawaited(_run());
  }

  void cancel(NavidromeTransfer job) {
    if (job.status == 'completed') return;
    job.cancelled = true;
    if (job.status == 'queued') job.status = 'cancelled';
    unawaited(_save().catchError((Object _) {}));
    notifyListeners();
  }

  void _check(NavidromeTransfer job) {
    if (job.cancelled || _disposed) throw StateError('Transfer cancelled');
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    final changedServers = <String>{};
    try {
      while (jobs.any((j) => j.status == 'queued')) {
        final job = jobs.firstWhere((j) => j.status == 'queued');
        Future<void> Function()? releaseWork;
        IosSecurityScopedAccess? scope;
        try {
          _check(job);
          releaseWork = await _beginWork(job.id, p.basename(job.local));
          var file = File(job.local);
          if (job.scopeId case final id?) {
            if (!RegExp(r'^[a-f0-9]{48}$').hasMatch(id)) {
              throw StateError('Invalid folder access identifier');
            }
            final bookmark = await _readScope(id);
            if (bookmark == null) {
              throw StateError('Original folder access is unavailable');
            }
            scope = await _openScope(bookmark);
            if (scope == null || job.scopedRelativePath == null) {
              throw StateError('Original folder access expired');
            }
            final resolved = p.normalize(
              p.join(scope.path, job.scopedRelativePath!),
            );
            if (!p.isWithin(scope.path, resolved)) {
              throw StateError('Original file is outside its selected folder');
            }
            file = File(resolved);
          }
          // Do not remove through symbolic links, or delete an iOS picker
          // import while claiming the original in Files was removed.
          if (job.deleteOriginal &&
              ((_isIOS && scope == null) ||
                  await FileSystemEntity.type(file.path, followLinks: false) !=
                      FileSystemEntityType.file)) {
            throw StateError(
              'This platform cannot safely remove this original. Upload without removing it.',
            );
          }
          final original = await sha256.bind(file.openRead()).first;
          job.total = await file.length();
          job.sent = 0;
          job.status = 'uploading';
          job.clock
            ..reset()
            ..start();
          await _save();
          notifyListeners();
          job.target ??= await _transport.prepare(job, file, () => _check(job));
          await _save();
          await _transport.publish(job, file, () => _check(job), (sent, total) {
            job.sent = sent;
            job.total = total;
            job.status = sent == total ? 'verifying' : 'uploading';
            notifyListeners();
          });
          _check(job);
          if (await sha256.bind(file.openRead()).first != original) {
            throw StateError(
              'The local file changed during upload. The original was kept.',
            );
          }
          if (job.deleteOriginal) {
            // publishUpload verified the final server path by content. Recheck
            // cancellation and local identity immediately before deletion.
            _check(job);
            await file.delete();
            if (!_disposed) _localChanges.add(file.path);
          }
          job.status = 'completed';
          changedServers.add(job.server);
        } catch (_) {
          job.status = job.cancelled ? 'cancelled' : 'failed';
          job.error = job.cancelled
              ? 'Cancelled. The local original was kept.'
              : 'Upload or verification failed. The local original was kept. Check the connection and retry.';
        } finally {
          if (scope != null) await _closeScope(scope);
          await releaseWork?.call();
          job.clock.stop();
          await _save();
          notifyListeners();
        }
      }
      // A scan failure must not undo a verified upload or cause a second delete.
      for (final id in changedServers) {
        unawaited(synchronize(id));
      }
    } finally {
      _running = false;
      if (!_disposed && jobs.any((j) => j.status == 'queued')) {
        unawaited(_run());
      }
    }
  }

  Future<void> synchronize(String server) {
    final running = _scans[server];
    if (running != null) {
      _scanAgain.add(server);
      return running;
    }
    return _scans[server] = _synchronize(server).whenComplete(() {
      _scans.remove(server);
      if (_scanAgain.remove(server) && !_disposed) {
        unawaited(synchronize(server));
      }
    });
  }

  Future<void> synchronizeDestination(String destination) async {
    try {
      final host = Uri.parse(destination).host;
      final prefs = await SharedPreferences.getInstance();
      for (final c in await storage.connections()) {
        if (c.protocol == NetworkProtocol.subsonic &&
            prefs.getString('navidrome_smb_${c.id}') == host) {
          unawaited(synchronize(c.id));
        }
      }
    } catch (_) {
      /* File publication stays successful if scan discovery fails. */
    }
  }

  Future<void> _synchronize(String server) async {
    try {
      final client = storage.openSubsonic(await storage.connection(server));
      try {
        await client.request('startScan');
        scanMessages[server] = 'Navidrome is scanning uploaded music…';
        if (!_disposed) notifyListeners();
        for (var attempt = 0; attempt < 60 && !_disposed; attempt++) {
          final result = await client.request('getScanStatus');
          final scan = result['scanStatus'];
          if (scan is Map && scan['scanning'] == false) {
            scanMessages[server] =
                'Navidrome scan finished. Refreshing the library.';
            _libraryChanges.add(server);
            return;
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        scanMessages[server] =
            'The scan is still running. Refresh the library when Navidrome finishes.';
      } finally {
        client.close();
      }
    } catch (_) {
      scanMessages[server] =
          'Uploaded files are verified. Navidrome did not allow scan status checks; scan or refresh the library manually.';
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_libraryChanges.close());
    unawaited(_localChanges.close());
    super.dispose();
  }
}
