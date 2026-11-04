import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/navidrome_library.dart';

final serverLibraryChangesProvider = StreamProvider<String>(
  (ref) => NavidromeLibrary.changes,
);
final serverFavouriteProvider = FutureProvider.autoDispose
    .family<bool?, String>((ref, source) async {
      ref.watch(serverLibraryChangesProvider);
      final target = await NavidromeLibrary.forSource(source);
      if (target == null) return null;
      final song = subsonicObject(
        (await target.library.read('getSong', {'id': target.id}))['song'],
      );
      return song['starred'] != null;
    });
