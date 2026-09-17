import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/schema/catalog.dart';
import 'package:onevtu_admin/ui/widgets/row_thumbnail.dart';

/// Deciding what to draw for a link column.
///
/// The guess is an extension sniff, because the column is plain text and there is
/// no content type until the request has been made — so the interesting cases are
/// the ones where the extension is not simply the tail of the string: a query
/// parameter after it, a `.jpg` that lives only in the query, an uppercase name
/// off a desktop.
///
/// Getting it wrong the other way is the expensive direction: a broken-image
/// square down a column of syllabus PDFs would tell the admin nothing and undo the
/// point of putting a picture on the row at all.
void main() {
  group('what counts as a picture', () {
    test('a real store listing URL does', () {
      // The exact shape `StoreRepository.uploadImage` returns.
      expect(
        looksLikeImage(
          'https://kzwykhjalncwyrmcmwsc.supabase.co/storage/v1/object/public/'
          'store_images/8f1c/1756621000000.jpg',
        ),
        isTrue,
      );
    });

    test('every extension the phone camera and the web use does', () {
      for (final extension in ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp',
          'heic']) {
        expect(looksLikeImage('https://example.com/a.$extension'), isTrue,
            reason: '.$extension should draw');
      }
    });

    test('a name typed off a desktop does, whatever its case', () {
      expect(looksLikeImage('https://example.com/Scan.JPG'), isTrue);
      expect(looksLikeImage('https://example.com/Scan.PnG'), isTrue);
    });

    test('a transform or cache-buster after the name does not hide it', () {
      expect(
        looksLikeImage('https://example.com/a.jpg?width=200&t=99'),
        isTrue,
      );
      expect(looksLikeImage('https://example.com/a.png#top'), isTrue);
    });

    test('surrounding whitespace does not hide it either', () {
      // Pasted links arrive with a trailing space more often than not.
      expect(looksLikeImage('  https://example.com/a.jpg  '), isTrue);
    });

    test('a document does not', () {
      expect(looksLikeImage('https://example.com/1BMATC101_syllabus.pdf'),
          isFalse);
      expect(looksLikeImage('https://example.com/notes.docx'), isFalse);
    });

    test('a folder or an extensionless object does not', () {
      expect(looksLikeImage('https://example.com/vtu/scheme-2025/'), isFalse);
      expect(looksLikeImage('https://example.com/some-object'), isFalse);
    });

    test('a .jpg that lives only in the query does not', () {
      // Why this reads `Uri.path` rather than the whole string: the thing being
      // served here is a download endpoint, not a picture.
      expect(
        looksLikeImage('https://example.com/download?file=a.jpg'),
        isFalse,
      );
    });

    test('nothing, and prose, do not', () {
      expect(looksLikeImage(''), isFalse);
      expect(looksLikeImage('   '), isFalse);
      expect(looksLikeImage('photo of a bike'), isFalse);
    });
  });

  group('the row', () {
    Future<void> pump(WidgetTester tester, String url) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(body: RowThumbnail(url: url, title: 'Tables')),
      ));
    }

    testWidgets('a listing with no photo says so', (tester) async {
      await pump(tester, '');

      // Not an empty square, which reads as "still loading" — a listing with no
      // photo is a thing the admin acts on.
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a link that is not a picture shows a link', (tester) async {
      await pump(tester, 'https://example.com/syllabus.pdf');

      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('the slot is the same width either way', (tester) async {
      await pump(tester, '');
      final empty = tester.getSize(find.byType(RowThumbnail));

      await pump(tester, 'https://example.com/syllabus.pdf');
      expect(tester.getSize(find.byType(RowThumbnail)), empty);
    });
  });

  group('the field preview', () {
    Future<void> pump(WidgetTester tester, String url) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ImagePreview(url: url, title: 'Image')),
      ));
    }

    testWidgets('a document field looks exactly as it always has',
        (tester) async {
      await pump(tester, 'https://example.com/syllabus.pdf');

      expect(find.byType(Image), findsNothing);
      expect(tester.getSize(find.byType(ImagePreview)).height, 0);
    });

    testWidgets('an empty field takes no space', (tester) async {
      await pump(tester, '');

      expect(tester.getSize(find.byType(ImagePreview)).height, 0);
    });
  });

  group('which tables show a picture', () {
    test('the store queue does', () {
      expect(specForTable('store')!.thumbnailColumn, 'image_url');
    });

    test('subjects do not', () {
      // A row of broken-image squares beside syllabus PDFs would say nothing,
      // and the column is a document rather than a picture of the subject.
      expect(specForTable('subjects')!.thumbnailColumn, isNull);
    });
  });
}
