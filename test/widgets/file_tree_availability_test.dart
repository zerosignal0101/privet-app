import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/models/file_tree.dart';
import 'package:privet_app/services/file_availability.dart';
import 'package:privet_app/widgets/file_tree_view.dart';

/// Rendering-level guard for WP-R6: the literal string "File not accessible"
/// must only ever appear for a file that is genuinely unreachable. A cleaned
/// staging copy must read as the honest, non-accusing note instead.
void main() {
  FileTreeNode fileNode(String path, {int size = 2048}) => FileTreeNode(
        name: path.split('/').last,
        relativePath: path.split('/').last,
        fullPath: path,
        size: size,
      );

  Future<void> pumpTree(
    WidgetTester tester, {
    required FileTreeNode node,
    Map<String, FileAvailability>? availabilityByPath,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileTreeView(
          nodes: [node],
          availabilityByPath: availabilityByPath,
        ),
      ),
    ));
  }

  testWidgets('a reachable file shows its recorded size', (tester) async {
    await pumpTree(
      tester,
      node: fileNode('/cache/staged/report.pdf'),
      availabilityByPath: const {
        '/cache/staged/report.pdf': FileAvailability.accessible,
      },
    );

    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('File not accessible'), findsNothing);
    // A reachable file is not greyed out.
    expect(
      tester.widget<Icon>(find.byIcon(Icons.insert_drive_file)).color,
      isNull,
    );
  });

  testWidgets('a cleaned staging copy never says "File not accessible"',
      (tester) async {
    await pumpTree(
      tester,
      node: fileNode('/cache/staged/legacy.bin'),
      availabilityByPath: const {
        '/cache/staged/legacy.bin': FileAvailability.stagedCopyCleaned,
      },
    );

    expect(find.text('File not accessible'), findsNothing);
    expect(find.text(stagedCopyCleanedMessage), findsOneWidget);
    // Still styled as a normal row, not as an error.
    expect(
      tester.widget<Text>(find.text(stagedCopyCleanedMessage)).style?.color,
      isNot(Colors.orange),
    );
  });

  testWidgets('a genuinely missing file keeps the old warning',
      (tester) async {
    await pumpTree(
      tester,
      node: fileNode('/storage/emulated/0/Download/really-gone.bin'),
      availabilityByPath: const {
        '/storage/emulated/0/Download/really-gone.bin':
            FileAvailability.inaccessible,
      },
    );

    expect(find.text('File not accessible'), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.file_present)).color,
      Colors.grey,
    );
  });

  testWidgets('with no availability map the widget keeps its previous behaviour',
      (tester) async {
    // Send preparation passes no map; a missing path must still warn.
    await pumpTree(tester, node: fileNode('/does/not/exist.bin'));

    expect(find.text('File not accessible'), findsOneWidget);
  });

  testWidgets('nested files inside a directory node are labelled too',
      (tester) async {
    const staged = '/cache/staged/dir/inner.bin';
    final tree = FileTreeNode(
      name: 'dir',
      relativePath: 'dir',
      isDir: true,
      children: [fileNode(staged)],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileTreeView(
          nodes: [tree],
          availabilityByPath: const {staged: FileAvailability.stagedCopyCleaned},
        ),
      ),
    ));

    // Expand the directory before asserting on its children.
    await tester.tap(find.text('dir'));
    await tester.pumpAndSettle();

    expect(find.text('File not accessible'), findsNothing);
    expect(find.text(stagedCopyCleanedMessage), findsOneWidget);
  });
}