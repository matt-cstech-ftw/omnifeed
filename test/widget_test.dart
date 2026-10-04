import 'package:flutter_test/flutter_test.dart';
import 'package:omnifeed_mobile/main.dart';

void main() {
  testWidgets('OmniFeed HUD smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const OmniFeedApp());
    expect(find.text('OMNI'), findsOneWidget);
  });
}
