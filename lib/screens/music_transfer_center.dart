import 'package:flutter/material.dart';
import 'package:mornye/screens/navidrome_transfers_page.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/network_storage_service.dart';

/// A single entry point for the existing upload and download job managers.
/// Both managers retain their own durable queues, retry and cancellation rules.
class MusicTransferCenter extends StatelessWidget {
  const MusicTransferCenter({super.key, required this.server});
  final NetworkConnection server;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Uploads'),
            Tab(text: 'Downloads'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          NavidromeTransfersPage(server: server),
          const QueueTab(librarySection: 'downloads', manageLibraries: false),
        ],
      ),
    ),
  );
}
