import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/transfers.dart';
import 'package:privet_app/widgets/transfer_tile.dart';

/// The failed tile must explain *why* the transfer failed, not show a bare
/// error code. Trust-related codes (peer forgot/revoked us) guide the user to
/// re-pair instead of retrying a send that can never succeed.
void main() {
  Widget wrap(ActiveTransfer t) => ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: TransferTile(transfer: t)),
        ),
      );

  ActiveTransfer failed({String? errorCode, String? peerName}) =>
      ActiveTransfer(
        transferId: 't1',
        direction: 'send',
        state: TransferState.failed,
        errorCode: errorCode,
        peerName: peerName,
      );

  testWidgets('rejected shows "peer no longer trusts you" guidance',
      (tester) async {
    await tester.pumpWidget(wrap(failed(errorCode: 'rejected')));
    expect(find.text('Transfer failed'), findsOneWidget);
    expect(
        find.text('Peer no longer trusts you — pair again to send'),
        findsOneWidget);
  });

  testWidgets('revoked shows "pair again" guidance', (tester) async {
    await tester.pumpWidget(wrap(failed(errorCode: 'revoked')));
    expect(
        find.text('Peer revoked you — pair again'), findsOneWidget);
  });

  testWidgets('not_paired shows "pair first" guidance', (tester) async {
    await tester.pumpWidget(wrap(failed(errorCode: 'not_paired')));
    expect(
        find.text('Not paired with this device — pair first'), findsOneWidget);
  });

  testWidgets('transport_lost points the user at the peer being offline',
      (tester) async {
    await tester.pumpWidget(wrap(failed(errorCode: 'transport_lost')));
    expect(
        find.text('Connection lost — is the other device online?'),
        findsOneWidget);
  });

  testWidgets('missing code falls back to the peer name', (tester) async {
    await tester.pumpWidget(wrap(failed(peerName: 'Thinkpad')));
    expect(find.text('Thinkpad'), findsOneWidget);
  });
}
