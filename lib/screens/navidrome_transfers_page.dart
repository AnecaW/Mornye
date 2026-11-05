import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/navidrome_transfers.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/local_upload_playlist.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/utils/nav_bar_inset.dart';

class NavidromeTransfersPage extends ConsumerStatefulWidget {
  const NavidromeTransfersPage({super.key, required this.server});
  final NetworkConnection server;
  @override
  ConsumerState<NavidromeTransfersPage> createState() =>
      _NavidromeTransfersPageState();
}

class _NavidromeTransfersPageState
    extends ConsumerState<NavidromeTransfersPage> {
  final manager = NavidromeTransfers.instance;
  final directory = TextEditingController();
  List<NetworkConnection> shares = [];
  String? selected;
  bool loading = true, selecting = false;
  String get _key => 'navidrome_smb_${widget.server.id}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    directory.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await manager.initialize();
      final connections = await manager.storage.connections();
      final prefs = await SharedPreferences.getInstance();
      shares = connections
          .where((c) => c.protocol == NetworkProtocol.smb)
          .toList();
      selected = prefs.getString(_key);
      if (!shares.any((c) => c.id == selected)) {
        selected = shares.firstOrNull?.id;
      }
      directory.text = prefs.getString('${_key}_directory') ?? '';
    } catch (_) {
      _error('Could not load transfers or SMB settings.');
    }
    if (mounted) setState(() => loading = false);
  }

  void _error(String message) {
    if (mounted) {
      showAppSnackBar(context, content: Text(message));
    }
  }

  bool _audio(String name) => NetworkEntry('', name).audio;
  Future<List<({String path, String relativeDir})>?> _chooseOriginalTracks(
    List<({String path, String relativeDir})> files,
  ) {
    final chosen = {for (var i = 0; i < files.length; i++) i};
    return showAppDialog<List<({String path, String relativeDir})>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AppAlertDialog(
          title: const Text('Select original tracks'),
          content: SizedBox(
            width: 500,
            height: 400,
            child: ListView.builder(
              itemCount: files.length,
              itemBuilder: (_, i) => CheckboxListTile(
                title: Text(p.basename(files[i].path)),
                subtitle: Text(files[i].relativeDir),
                value: chosen.contains(i),
                onChanged: (value) => update(() {
                  if (value == true) {
                    chosen.add(i);
                  } else {
                    chosen.remove(i);
                  }
                }),
              ),
            ),
          ),
          actions: [
            AppDialogAction(
              onPressed: () => update(() {
                if (chosen.length == files.length) {
                  chosen.clear();
                } else {
                  chosen.addAll(List.generate(files.length, (i) => i));
                }
              }),
              child: Text(
                chosen.length == files.length
                    ? 'Clear selection'
                    : 'Select all',
              ),
            ),
            AppDialogAction(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            AppDialogAction(
              filled: true,
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(context, [
                      for (var i = 0; i < files.length; i++)
                        if (chosen.contains(i)) files[i],
                    ]),
              child: Text('Continue (${chosen.length})'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _select({bool folder = false}) async {
    if (selected == null || selecting) return;
    setState(() => selecting = true);
    IosSecurityScopedAccess? scope;
    String? bookmark, scopeRoot;
    try {
      final relative = networkPath(directory.text.trim());
      final destination = NetworkStorageService.source(
        selected!,
        relative.isEmpty || relative.endsWith('/') ? relative : '$relative/',
      );
      await manager.storage.checkUploadAccess(destination);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, selected!);
      await prefs.setString('${_key}_directory', relative);
      final files = <({String path, String relativeDir})>[];
      if (folder) {
        String? root;
        if (Platform.isIOS) {
          final picked = await PlatformBridge.pickIosDirectory();
          if (picked == null) return;
          bookmark = picked.bookmark;
          scope = await PlatformBridge.startAccessingIosBookmark(bookmark);
          if (scope == null) throw StateError('Folder access was not granted');
          root = scope.path;
          scopeRoot = root;
        } else {
          root = await FilePicker.getDirectoryPath();
        }
        if (root == null) return;
        final playlists = <String>[];
        await for (final entry in Directory(
          root,
        ).list(recursive: true, followLinks: false)) {
          if (entry is File && _audio(entry.path)) {
            files.add((
              path: entry.path,
              relativeDir: p
                  .relative(p.dirname(entry.path), from: p.dirname(root))
                  .replaceAll(p.separator, '/'),
            ));
          } else if (entry is File &&
              [
                '.m3u',
                '.m3u8',
              ].contains(p.extension(entry.path).toLowerCase())) {
            playlists.add(entry.path);
          }
        }
        if (playlists.isNotEmpty && mounted) {
          final choice = await showAppDialog<int>(
            context: context,
            builder: (context) => AppAlertDialog(
              title: const Text('Choose music to upload'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        onTap: () => Navigator.pop(context, -1),
                        title: const Text('All audio in this folder'),
                      ),
                      for (var i = 0; i < playlists.length; i++)
                        ListTile(
                          onTap: () => Navigator.pop(context, i),
                          title: Text(
                            'Playlist: ${p.relative(playlists[i], from: root)}',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
          if (choice == null) return;
          if (choice >= 0) {
            final paths = (await readLocalUploadPlaylist(
              playlists[choice],
              root: root,
            )).toSet();
            files.retainWhere((file) => paths.contains(p.normalize(file.path)));
          }
        }
      } else {
        final result = await FilePicker.pickFiles();
        if (result.isEmpty) return;
        for (final entry in result) {
          final path = entry.path;
          if (path == null) continue;
          if (_audio(path)) {
            files.add((path: path, relativeDir: ''));
          } else if ([
            '.m3u',
            '.m3u8',
          ].contains(p.extension(path).toLowerCase())) {
            for (final song in await readLocalUploadPlaylist(path)) {
              files.add((
                path: song,
                relativeDir: p.isWithin(p.dirname(path), song)
                    ? p
                          .relative(p.dirname(song), from: p.dirname(path))
                          .replaceAll(p.separator, '/')
                    : '',
              ));
            }
          }
        }
      }
      if (files.isEmpty) {
        _error('No readable audio files were selected.');
        return;
      }
      if (!mounted) return;
      if (bookmark != null && files.length > 1) {
        final picked = await _chooseOriginalTracks(files);
        if (picked == null || !mounted) return;
        files
          ..clear()
          ..addAll(picked);
      }
      final canRemoveOriginals =
          bookmark != null ||
          (!Platform.isIOS && (!Platform.isAndroid || folder));
      final remove = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
          title: Text('Upload ${files.length} tracks?'),
          content: Text(
            !canRemoveOriginals
                ? 'Files are uploaded unchanged. Choose an original folder to enable verified removal of originals on mobile.'
                : 'Files are uploaded unchanged. You can keep the originals, or permanently remove them only after the server files pass content verification.',
          ),
          actions: [
            AppDialogAction(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            if (canRemoveOriginals)
              AppDialogAction(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Upload and remove originals'),
              ),
            AppDialogAction(
              filled: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Upload and keep originals'),
            ),
          ],
        ),
      );
      if (remove == null) return;
      await manager.enqueue(
        files,
        folder: destination,
        server: widget.server.id,
        deleteOriginal: remove,
        bookmark: bookmark,
        scopeRoot: scopeRoot,
      );
    } catch (_) {
      _error(
        'Could not prepare the upload. Check SMB access and the selected files.',
      );
    } finally {
      if (scope != null) await PlatformBridge.stopAccessingIosBookmark(scope);
      if (mounted) setState(() => selecting = false);
    }
  }

  Future<void> _scan() async {
    await manager.synchronize(widget.server.id);
  }

  Future<void> _useForDownloads() async {
    if (selected == null) return;
    try {
      final relative = networkPath(directory.text.trim());
      final folder = NetworkStorageService.source(
        selected!,
        relative.isEmpty || relative.endsWith('/') ? relative : '$relative/',
      );
      await manager.storage.checkUploadAccess(folder);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, selected!);
      await prefs.setString('${_key}_directory', relative);
      await ref
          .read(settingsProvider.notifier)
          .setNetworkDownloadFolder(folder, '${widget.server.name} / SMB');
      if (mounted) {
        _error(
          'Downloads will use this server folder. Choose “both” in Files settings to keep a local copy too.',
        );
      }
    } catch (_) {
      _error(
        'Could not save the download destination. Check SMB write access.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final jobs = manager.jobs
            .where((j) => j.server == widget.server.id)
            .toList()
            .reversed
            .toList();
        return CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: 'Music transfers'),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Upload unchanged music to Navidrome’s SMB music folder. Use a private network or VPN; avoid exposing SMB to the public internet.',
                    ),
                    const SizedBox(height: 16),
                    if (loading)
                      const AppProgressIndicator.linear()
                    else if (shares.isEmpty)
                      const Text(
                        'Add an SMB connection in Network storage first. Include the share name in its address, for example smb://host/Music.',
                      ),
                    if (shares.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        initialValue: selected,
                        decoration: const InputDecoration(
                          labelText: 'Music folder SMB connection',
                        ),
                        items: shares
                            .map(
                              (c) => DropdownMenuItem(
                                value: c.id,
                                child: Text(c.name),
                              ),
                            )
                            .toList(),
                        onChanged: selecting
                            ? null
                            : (v) => setState(() => selected = v),
                      ),
                      TextField(
                        controller: directory,
                        decoration: const InputDecoration(
                          labelText:
                              'Music directory within the share (optional)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: selecting ? null : () => _select(),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Select tracks or an M3U playlist'),
                      ),
                      OutlinedButton.icon(
                        onPressed: selecting
                            ? null
                            : () => _select(folder: true),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Select album or folder'),
                      ),
                      OutlinedButton.icon(
                        onPressed: selecting ? null : _useForDownloads,
                        icon: const Icon(Icons.download_outlined),
                        label: const Text(
                          'Use this server folder for downloads',
                        ),
                      ),
                      if (selecting) const AppProgressIndicator.linear(),
                    ],
                    TextButton(
                      onPressed: _scan,
                      child: const Text('Request Navidrome library scan'),
                    ),
                    if (manager.scanMessages[widget.server.id]
                        case final message?)
                      Text(message),
                  ],
                ),
              ),
            ),
            SliverList.builder(
              itemCount: jobs.length,
              itemBuilder: (context, i) {
                final job = jobs[i];
                final active = [
                  'queued',
                  'uploading',
                  'verifying',
                ].contains(job.status);
                return Card(
                  color: settingsGroupColor(context),
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.basename(job.local),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          job.status == 'verifying'
                              ? 'Verifying server file…'
                              : job.status,
                        ),
                        if (active)
                          AppProgressIndicator.linear(
                            value: job.total > 0 ? job.sent / job.total : null,
                          ),
                        if (job.total > 0)
                          Text(
                            '${(job.sent / 1048576).toStringAsFixed(1)} / ${(job.total / 1048576).toStringAsFixed(1)} MB · ${(job.speed / 1048576).toStringAsFixed(1)} MB/s${job.remainingSeconds == null ? '' : ' · ${job.remainingSeconds}s remaining'}',
                          ),
                        if (job.error != null) Text(job.error!),
                        if (active)
                          TextButton(
                            onPressed: () => manager.cancel(job),
                            child: const Text('Cancel'),
                          ),
                        if (['failed', 'cancelled'].contains(job.status))
                          TextButton(
                            onPressed: () => manager.retry(job),
                            child: const Text('Retry'),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const NavBarSliverSpacer(),
          ],
        );
      },
    ),
  );
}
