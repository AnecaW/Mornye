import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:mornye/services/network_storage_service.dart';

/// Resolve local M3U entries without fetching URLs or escaping a granted folder.
Future<List<String>> readLocalUploadPlaylist(
  String playlist, {
  String? root,
}) async {
  final result = <String>{};
  final boundary = root == null
      ? null
      : await Directory(root).resolveSymbolicLinks();
  for (final raw in await File(playlist).readAsLines()) {
    final line = raw.replaceFirst('\uFEFF', '').trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final uri = Uri.tryParse(line);
    if (uri != null &&
        uri.hasScheme &&
        uri.scheme != 'file' &&
        !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(line)) {
      continue;
    }
    try {
      final path = p.normalize(
        uri?.scheme == 'file'
            ? uri!.toFilePath()
            : p.join(p.dirname(playlist), line.replaceAll('\\', '/')),
      );
      if (!NetworkEntry('', path).audio || !await File(path).exists()) continue;
      if (boundary != null &&
          !p.isWithin(boundary, await File(path).resolveSymbolicLinks())) {
        continue;
      }
      result.add(path);
    } on FileSystemException {
      // Unavailable entries do not block other readable playlist tracks.
    } on UnsupportedError {
      // A file URI for another operating system cannot name a local original.
    } on FormatException {
      // Ignore malformed file URIs.
    }
  }
  return result.toList();
}
