import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playback_buffer_policy.dart';

void main() {
  test(
    'starts with a small progressive prefix and bounded native preferences',
    () {
      final profile = PlaybackNetworkProfile();
      expect(profile.probeBytes(1411), 4096);
      expect(profile.policy.minimumSeconds, 0.35);
      expect(profile.policy.forwardSeconds, 4);
    },
  );
  test(
    'slow first byte and stalls increase bounded buffering without downloading a song',
    () {
      final profile = PlaybackNetworkProfile();
      profile.observe(
        firstByte: const Duration(seconds: 4),
        bytes: 4096,
        transfer: const Duration(seconds: 1),
      );
      for (var i = 0; i < 100; i++) {
        profile.stalled();
      }
      expect(profile.stalls, 6);
      expect(profile.policy.minimumSeconds, 3);
      expect(profile.policy.forwardSeconds, 12);
      expect(profile.policy.prepareTimeoutSeconds, lessThanOrEqualTo(45));
      expect(profile.probeBytes(1411), 65536);
    },
  );
  test(
    'measured transfer capacity is evaluated against the actual bitrate',
    () {
      final profile = PlaybackNetworkProfile();
      for (var i = 0; i < 2; i++) {
        profile.observe(
          firstByte: const Duration(milliseconds: 10),
          bytes: 32000,
          transfer: const Duration(seconds: 1),
        );
      }
      expect(
        profile.policyFor(1411).minimumSeconds,
        greaterThan(profile.policyFor(64).minimumSeconds),
      );
    },
  );
}
