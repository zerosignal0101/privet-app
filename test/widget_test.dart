import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/main.dart';

void main() {
  testWidgets('placeholder app builds', (tester) async {
    await tester.pumpWidget(const PrivetApp());
    expect(find.text('Privet'), findsOneWidget);
  });
}
