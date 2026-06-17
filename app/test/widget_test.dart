import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink_app/main.dart';

void main() {
  testWidgets('App renders with title', (WidgetTester tester) async {
    await tester.pumpWidget(const CrossLinkApp());
    // HomeScreen shows "CrossLink" as the AppBar title
    expect(find.text('CrossLink'), findsOneWidget);
  });
}
