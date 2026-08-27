import 'package:flutter_test/flutter_test.dart';
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

void main() {
  test('history provider lists, deletes, details and resends', () async {
    final entries = <Map<String, dynamic>>[_entry('t-1', 'phone')];

    final daemon = await bootTestDaemon(scriptFromHandlers({
      'list_history': (id, params) => okResponse(id, 'history', List.of(entries)),
      'delete_history': (id, params) {
        entries.removeWhere((e) => e['transfer_id'] == params['transfer_id']);
        return okResponse(id, 'ack', null);
      },
      'get_history_detail': (id, params) => okResponse(id, 'history_detail', {
            'transfer_id': 't-1',
            'direction': 'send',
            'peer_device_fingerprint': 'peer-t-1',
            'peer_name': 'phone',
            'root_name': 't-1-root',
            'status': 'completed',
            'started_ts': 1,
            'finished_ts': 2,
            'files': [
              {
                'relative_path': 'photo.jpg',
                'absolute_path': 'C:/photos/photo.jpg',
                'size': 100,
                'status': 'complete',
              },
            ],
          }),
      'resend_transfer': (id, params) =>
          okResponse(id, 'transfer_queued', {'transfer_id': 'new-transfer'}),
    }));
    addTearDown(daemon.dispose);

    final n = daemon.container.read(transferHistoryProvider.notifier);
    await n.refresh();
    expect(n.state, hasLength(1));
    expect(n.state.single.peerName, 'phone');

    final detail = await n.detail('t-1');
    expect(detail.files.single.relativePath, 'photo.jpg');
    expect(detail.files.single.absolutePath, 'C:/photos/photo.jpg');

    final newId = await n.resend('t-1');
    expect(newId, 'new-transfer');

    await n.delete('t-1');
    expect(daemon.container.read(transferHistoryProvider), isEmpty);
  });

  test('terminal events trigger a history refresh', () async {
    var historyCalls = 0;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'list_history': (id, params) {
        historyCalls++;
        return okResponse(id, 'history', const <Object>[]);
      },
    }));
    addTearDown(daemon.dispose);

    final n = daemon.container.read(transferHistoryProvider.notifier);
    await n.refresh();
    expect(historyCalls, 1);

    daemon.transport.inject(serverMessage('event', {
      'sequence': 1,
      'event': {
        'name': 'transfer_completed',
        'data': {'transfer_id': 't-1'},
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(historyCalls, greaterThanOrEqualTo(2));
  });
}
