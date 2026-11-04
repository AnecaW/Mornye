import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/local_upload_playlist.dart';

void main() {
  test('M3U preserves local files and confines folder grants', () async {
    final directory = await Directory.systemTemp.createTemp('upload-m3u-');
    addTearDown(() => directory.delete(recursive: true));
    final root = await Directory(p.join(directory.path, 'Music')).create();
    final album = await Directory(p.join(root.path, 'Album')).create();
    final first = await File(
      p.join(album.path, '日本語 1.flac'),
    ).writeAsBytes([1, 2]);
    final second = await File(
      p.join(root.path, 'Two.mp3'),
    ).writeAsBytes([3, 4]);
    final outside = await File(
      p.join(directory.path, 'Outside.flac'),
    ).writeAsBytes([5]);
    final playlist = await File(p.join(root.path, 'Selected.m3u8')).writeAsString(
      '\uFEFF#EXTM3U\nAlbum\\日本語 1.flac\n${second.uri}\nAlbum/日本語 1.flac\n../Outside.flac\nhttps://example.com/song.flac\nmissing.flac\n',
    );
    expect(await readLocalUploadPlaylist(playlist.path, root: root.path), [
      p.normalize(first.path),
      p.normalize(second.path),
    ]);
    expect(
      await readLocalUploadPlaylist(playlist.path),
      contains(p.normalize(outside.path)),
    );
    expect(await first.readAsBytes(), [1, 2]);
  });
}
