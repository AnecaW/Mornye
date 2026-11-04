import 'package:flutter/material.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/widgets/settings_group.dart';

class NetworkAudioCacheSettings extends StatefulWidget {
  const NetworkAudioCacheSettings({super.key});
  @override
  State<NetworkAudioCacheSettings> createState() =>
      _NetworkAudioCacheSettingsState();
}

class _NetworkAudioCacheSettingsState extends State<NetworkAudioCacheSettings> {
  final cache = NetworkStorageService.instance.audioCache!;
  int? bytes;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await cache.initialize();
    final value = await cache.size();
    if (mounted) {
      setState(() {
        bytes = value;
        busy = false;
      });
    }
  }

  Future<void> _change(void Function() update) async {
    setState(() {
      busy = true;
      update();
    });
    try {
      await cache.saveSettings();
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() => busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update the music cache.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: settingsGroupColor(context),
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        SwitchListTile(
          title: const Text('Automatic music cache'),
          subtitle: Text(
            bytes == null
                ? 'Reading storage…'
                : '${(bytes! / 1048576).toStringAsFixed(1)} MB cached · permanent downloads are kept separately',
          ),
          value: cache.enabled,
          onChanged: busy ? null : (v) => _change(() => cache.enabled = v),
        ),
        SwitchListTile(
          title: const Text('Cache only on Wi-Fi or Ethernet'),
          value: cache.wifiOnly,
          onChanged: busy ? null : (v) => _change(() => cache.wifiOnly = v),
        ),
        SwitchListTile(
          title: const Text('Prefer cached music for offline playback'),
          value: cache.preferOffline,
          onChanged: busy
              ? null
              : (v) => _change(() => cache.preferOffline = v),
        ),
        ListTile(
          title: const Text('Upcoming tracks to cache'),
          trailing: DropdownButton<int>(
            value: cache.upcoming,
            items: List.generate(
              11,
              (i) => DropdownMenuItem(value: i, child: Text('$i')),
            ),
            onChanged: busy ? null : (v) => _change(() => cache.upcoming = v!),
          ),
        ),
        ListTile(
          title: const Text('Maximum cache size'),
          trailing: DropdownButton<int>(
            value: cache.maxBytes,
            items: [128, 256, 512, 1024, 2048, 4096, 8192, 16384]
                .map(
                  (mb) => DropdownMenuItem(
                    value: mb * 1048576,
                    child: Text(mb < 1024 ? '$mb MB' : '${mb ~/ 1024} GB'),
                  ),
                )
                .toList(),
            onChanged: busy ? null : (v) => _change(() => cache.maxBytes = v!),
          ),
        ),
        ListTile(
          title: const Text('Clear temporary music cache'),
          leading: const Icon(Icons.delete_outline),
          onTap: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await cache.clear();
                    await _load();
                  } catch (_) {
                    if (mounted) setState(() => busy = false);
                  }
                },
        ),
      ],
    ),
  );
}
