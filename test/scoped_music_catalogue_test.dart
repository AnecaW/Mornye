import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/scoped_music_catalogue.dart';
import 'package:mornye/services/playable_media.dart';

PlayableMedia media(String source) => PlayableMedia(
  id: 'same-id',
  source: source,
  title: 'Same title',
  artist: 'Same artist',
);
void main() {
  test(
    'combined library preserves identities on different servers and bounds source concurrency',
    () async {
      var active = 0, peak = 0;
      final catalogue = ScopedMusicCatalogue([
        for (var n = 0; n < 9; n++)
          CatalogueSource(
            id: '$n',
            name: 'Server $n',
            fetch: (offset, query) async {
              active++;
              if (active > peak) peak = active;
              await Future<void>.delayed(const Duration(milliseconds: 5));
              active--;
              return [media('network://server-$n/song')];
            },
          ),
      ]);
      await catalogue.load(reset: true);
      expect(catalogue.tracks, hasLength(9));
      expect(peak, 4);
      expect(catalogue.more, isFalse);
      expect(catalogue.errors, isEmpty);
    },
  );
  test(
    'successful sources publish while another source is delayed and retry keeps its offset',
    () async {
      final slow = Completer<List<PlayableMedia>>();
      var fail = true;
      final offsets = <int>[];
      final catalogue = ScopedMusicCatalogue([
        CatalogueSource(
          id: 'slow',
          name: 'Slow',
          fetch: (offset, query) => slow.future,
        ),
        CatalogueSource(
          id: 'working',
          name: 'Working',
          fetch: (offset, query) async => [media('network://working/song')],
        ),
        CatalogueSource(
          id: 'offline',
          name: 'Offline',
          fetch: (offset, query) async {
            offsets.add(offset);
            if (fail) throw const SocketException('offline');
            return [media('network://offline/song')];
          },
        ),
      ]);
      final ready = Completer<void>();
      final pending = catalogue.load(
        reset: true,
        changed: () {
          if (catalogue.tracks.isNotEmpty && !ready.isCompleted) {
            ready.complete();
          }
        },
      );
      await ready.future;
      expect(catalogue.tracks.single.media.source, 'network://working/song');
      slow.complete([media('network://slow/song')]);
      await pending;
      expect(catalogue.errors.keys, ['Offline']);
      fail = false;
      await catalogue.load(retryFailed: true);
      expect(offsets, [0, 0]);
      expect(catalogue.tracks, hasLength(3));
      expect(catalogue.errors, isEmpty);
    },
  );
  test(
    'new searches discard delayed responses from the old selection',
    () async {
      final slow = Completer<List<PlayableMedia>>();
      final catalogue = ScopedMusicCatalogue([
        CatalogueSource(
          id: 'one',
          name: 'One',
          fetch: (offset, query) => query == 'old'
              ? slow.future
              : Future.value([media('network://one/new')]),
        ),
      ]);
      final old = catalogue.load(reset: true, query: 'old');
      await Future<void>.delayed(Duration.zero);
      await catalogue.load(reset: true, query: 'new');
      slow.complete([media('network://one/old')]);
      await old;
      expect(catalogue.tracks.single.media.source, 'network://one/new');
    },
  );
}
