import 'package:mornye/models/library_database_models.dart';

void appendLibrarySourceScope(
  List<String> where,
  List<Object?> args,
  QueueLibraryDbQuery? request,
  String path, {
  bool indexed = false,
}) {
  if (request == null) return;
  if (indexed && !request.includeIndexedDevice) {
    where.add("$path LIKE 'network://%'");
  }
  if (request.networkScope case final ids?) {
    final choices = <String>[];
    if (request.includeDevice) {
      choices.add(
        "($path NOT LIKE 'network://%' AND $path NOT LIKE 'http://%' AND $path NOT LIKE 'https://%')",
      );
    }
    for (final id in ids) {
      choices.add("$path LIKE ? ESCAPE '\\'");
      final escaped = id
          .replaceAll('\\', '\\\\')
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      args.add('network://$escaped/%');
    }
    where.add(choices.isEmpty ? '0' : '(${choices.join(' OR ')})');
  }
  if (request.deviceOnly) {
    for (final scheme in ['network://%', 'http://%', 'https://%']) {
      where.add('$path NOT LIKE ?');
      args.add(scheme);
    }
  }
}

String sourceAlbumKeySql(String alias) =>
    "(CASE WHEN $alias.file_path LIKE 'network://%' THEN substr($alias.file_path, 1, instr(substr($alias.file_path, 11), '/') + 10) ELSE '' END || $alias.album_key)";
String sourceAlbumKey(String key, String path) {
  final uri = Uri.tryParse(path);
  return uri?.scheme == 'network' ? 'network://${uri!.host}/$key' : key;
}

/// In-memory equivalent of the SQL boundary, also used before pruning History.
bool libraryScopeAllowsPath(
  QueueLibraryDbQuery? scope,
  String path, {
  bool indexed = false,
}) {
  if (scope == null) return true;
  final uri = Uri.tryParse(path);
  if (uri?.scheme == 'network') {
    return !scope.deviceOnly &&
        (scope.networkScope?.contains(uri!.host) ?? true);
  }
  if (indexed && (!scope.includeLocal || !scope.includeIndexedDevice))
    return false;
  if (scope.networkScope != null && !scope.includeDevice) return false;
  if (scope.deviceOnly && (uri?.scheme == 'http' || uri?.scheme == 'https'))
    return false;
  return true;
}
