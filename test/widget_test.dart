// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:girlfriend_call_app/main.dart';

void main() {
  testWidgets('Call scheduler UI renders expected defaults',
      (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify the main scaffolding and default field text.
    expect(find.text('📞 Call Reminder + Location'), findsOneWidget);
    expect(find.text('Phone Number'), findsOneWidget);
    expect(find.text('No time selected'), findsOneWidget);
    expect(find.text('📍 Location not fetched'), findsOneWidget);
    expect(find.text('Schedule Call'), findsOneWidget);
  });
}
