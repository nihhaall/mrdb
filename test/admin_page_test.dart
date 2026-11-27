import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/home/navs/owner/admin_page.dart';
import 'package:mrdb/home/navs/owner/bot_manager_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('AdminPage renders Manage Clients and Bot Manager tiles', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AdminPage(),
      ),
    );

    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Manage Clients'), findsOneWidget);
    expect(find.text('Bot Manager'), findsOneWidget);
  });

  testWidgets(
    'BotManagerPage Broadcast tab supports markdown toolbar, button positioning, and live preview',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const MaterialApp(
          home: BotManagerPage(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('Broadcast'));
      await tester.pumpAndSettle();

      expect(find.text('Live Preview'), findsOneWidget);
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(find.byType(RichText), findsWidgets);

      await tester.tap(find.text('Add Button'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Button'));
      await tester.pumpAndSettle();

      expect(find.text('Row 1'), findsOneWidget);
      expect(find.text('Row 2'), findsOneWidget);

      await tester.ensureVisible(find.text('New Row'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Row'));
      await tester.pumpAndSettle();
      expect(find.text('Same Row'), findsOneWidget);
      expect(find.text('Row 1'), findsNWidgets(2));

      await tester.ensureVisible(find.byTooltip('Remove button').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove button').first);
      await tester.pumpAndSettle();
      expect(find.text('Row 1'), findsOneWidget);
    },
  );
}
