// Regression: History tiles must never show a detail fetched for a different
// record. The list refreshes after every terminal transfer event, and the
// tiles used to keep their State (and the cached per-record detail future) by
// list index — so once a NEW transfer pushed the old "first" record down, the
// tile at index 0 rendered the previous record's file list under the new
// record's title. Each tile is now keyed by transfer id and invalidates its
// cached detail when the record changes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/history_page.dart';
import 'package:privet_app/providers/history.dart';

import '../support/test_daemon.dart';

Map<String, dynamic> _entry(String id, String name) => {
      'transfer_id': id,
      'direction': 'send',
      'peer_device_fingerprint': 'peer-$id',
      'peer_name': name,
      'root_name': '$id-root',
      'file_count': 1,
      'total_bytes': 100,
      'status': 'completed',
      'started_ts': 1,
      'finished_ts': 2,
    };

Map<String, dynamic> _detail(String id) => {
      'transfer_id': id,
      'direction': 'send',
      'peer_device_fingerprint': 'peer-$id',
      'peer_name': 'x',
      'root_name': '$id-root',
      'status': 'completed',
      'started_ts': 1,
      'finished_ts': 2,
      'files': [
        {
          'relative_path': '$id-file.txt',
          'absolute_path': 'C:/files/$id-file.txt',
          'size': 100,
          'status': 'complete',
        },
      ],
    };

void main() {
  testWidgets('a refreshed tile shows its own record detail, not a stale one',
      (tester) async {
    final entries = <Map<String, dynamic>>[_entry('t-2', 'tablet')];
    final detailRequests = <String>[];
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'list_history': (id, params) =>
          okResponse(id, 'history', List.of(entries)),
      'get_history_detail': (id, params) {
        final tid = params['transfer_id'] as String;
        detailRequests.add(tid);
        return okResponse(id, 'history_detail', _detail(tid));
      },
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: const MaterialApp(home: HistoryPage()),
    ));
    await tester.pump(); // history provider's initial refresh microtask

    // Expand the only tile (t-2): it loads and shows t-2's files.
    await tester.tap(find.text('tablet'));
    await tester.pumpAndSettle();
    expect(find.text('t-2-file.txt'), findsOneWidget);

    // A new transfer completes: t-3 lands at the top and t-2 slides down.
    entries.insert(0, _entry('t-3', 'laptop'));
    await daemon.container.read(transferHistoryProvider.notifier).refresh();
    await tester.pumpAndSettle();

    // The tile now at index 0 is t-3. Without the per-record key it would have
    // kept t-2's cached detail and shown t-2-file.txt under "laptop". It must
    // instead fetch (and show) t-3's own files.
    await tester.tap(find.text('laptop'));
    await tester.pumpAndSettle();

    // t-3 must have fetched its OWN detail (without the per-record key the
    // refreshed index-0 tile would have kept t-2's cached future and never
    // re-fetched), and the tile must render t-3's files — not t-2's.
    expect(detailRequests, contains('t-3'), reason: 't-3 detail must be fetched');
    expect(find.text('t-3-file.txt'), findsOneWidget,
        reason: 'the first tile must show the current record\'s files');
    expect(find.text('t-2-file.txt'), findsNothing,
        reason: 'the first tile must not show the previous record\'s files');
  });
}
