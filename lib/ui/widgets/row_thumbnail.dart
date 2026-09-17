/// Pictures: small on a row, fitted under a link field, full screen when tapped.
///
/// Built for the Store queue, where the photo *is* most of the decision — three
/// of the six refusal presets ("Photo needed", "Price looks wrong", "Not a real
/// listing") are judgments about it, and a queue of text rows makes those
/// judgments impossible without opening every listing in turn.
///
/// Driven by `TableSpec.thumbnailColumn` rather than hard-coded to `store`, so any
/// table with a picture column gets the same treatment by naming it.
library;

import 'package:flutter/material.dart';

/// Whether a URL is worth trying to draw.
///
/// An extension sniff, because that is all there is to go on: the column is a
/// plain text URL and there is no content type until the request has already been
/// made. Wrong guesses are cheap in both directions — a missed image shows the
/// link it always showed, and a false positive lands in [Image.network]'s error
/// builder.
bool looksLikeImage(String url) {
  final path = Uri.tryParse(url.trim())?.path.toLowerCase() ?? '';
  return path.endsWith('.jpg') ||
      path.endsWith('.jpeg') ||
      path.endsWith('.png') ||
      path.endsWith('.webp') ||
      path.endsWith('.gif') ||
      path.endsWith('.bmp') ||
      path.endsWith('.heic');
}

/// A row's picture, at [size] logical pixels square.
///
/// Shows a placeholder when the row has no picture and a broken-image mark when
/// one will not load — never nothing, so the slot does not change width and the
/// list keeps its rhythm.
class RowThumbnail extends StatelessWidget {
  const RowThumbnail({
    super.key,
    required this.url,
    this.title,
    this.size = 52,
  });

  /// The column's value. Empty, or something that is not an image, draws the
  /// placeholder.
  final String url;

  /// Named in the viewer's title bar, so a full-screen photo is still attached to
  /// the row it came from.
  final String? title;

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trimmed = url.trim();
    final radius = BorderRadius.circular(8);

    if (trimmed.isEmpty || !looksLikeImage(trimmed)) {
      return _Frame(
        size: size,
        radius: radius,
        child: Icon(
          // A listing with no photo is a thing an admin acts on, so it says so
          // rather than leaving an empty square that reads as "still loading".
          trimmed.isEmpty ? Icons.image_not_supported_outlined : Icons.link,
          size: size * 0.42,
          color: theme.disabledColor,
        ),
      );
    }

    // Decoded to the size it is drawn at, not the size it was taken at. A queue
    // of phone photos at full resolution is tens of megabytes of bitmap for a
    // handful of 52-pixel squares.
    final cachePx =
        (size * MediaQuery.devicePixelRatioOf(context)).round().clamp(32, 512);

    return InkWell(
      borderRadius: radius,
      // Its own tap, distinct from the row's: the photo opens the photo, the row
      // opens the row.
      onTap: () => showFullImage(context, trimmed, title: title),
      child: _Frame(
        size: size,
        radius: radius,
        child: Image.network(
          trimmed,
          fit: BoxFit.cover,
          width: size,
          height: size,
          cacheWidth: cachePx,
          errorBuilder: (context, _, _) => Icon(
            Icons.broken_image_outlined,
            size: size * 0.42,
            color: theme.colorScheme.error,
          ),
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : Center(
                  child: SizedBox(
                    width: size * 0.3,
                    height: size * 0.3,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
        ),
      ),
    );
  }
}

/// The picture a link field points at, drawn under the field itself.
///
/// Fitted rather than cropped, and much larger than [RowThumbnail]: this is where
/// a listing is actually read, and a square crop can hide the very thing a listing
/// gets turned down for — a phone number written across a corner, a price tag that
/// disagrees with the price.
///
/// Draws nothing when the link is empty or is not a picture, so a syllabus PDF's
/// field looks exactly as it always has.
class ImagePreview extends StatelessWidget {
  const ImagePreview({
    super.key,
    required this.url,
    this.title,
    this.height = 170,
  });

  final String url;

  /// Named in the viewer's title bar. The field's own label, normally, since the
  /// editor has no better name for one column's picture.
  final String? title;

  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trimmed = url.trim();
    if (trimmed.isEmpty || !looksLikeImage(trimmed)) {
      return const SizedBox.shrink();
    }

    final radius = BorderRadius.circular(10);
    // Wide enough for the box at this screen's density, so a 12-megapixel phone
    // photo is not decoded at 12 megapixels to fill a strip 170 tall.
    final cachePx = (MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(320, 2048);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: () => showFullImage(context, trimmed, title: title),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: Image.network(
                trimmed,
                fit: BoxFit.contain,
                cacheWidth: cachePx,
                errorBuilder: (context, _, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined,
                            color: theme.colorScheme.error),
                        const SizedBox(height: 8),
                        Text(
                          'This photo could not be loaded. The link may be '
                          'broken, or the file may have been removed.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The square the picture sits in, so a photo, a placeholder and a failure all
/// occupy exactly the same space.
class _Frame extends StatelessWidget {
  const _Frame({required this.size, required this.radius, required this.child});

  final double size;
  final BorderRadius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: radius,
      child: Container(
        width: size,
        height: size,
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// Opens one picture full screen, zoomable.
///
/// Zoom is the point, not a flourish: deciding whether a photo is really of the
/// item, whether a price tag matches, or whether a phone number has been written
/// on it — all reasons a listing gets turned down — means reading detail a
/// thumbnail cannot carry.
Future<void> showFullImage(
  BuildContext context,
  String url, {
  String? title,
}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => _FullImageScreen(url: url, title: title),
  ));
}

class _FullImageScreen extends StatelessWidget {
  const _FullImageScreen({required this.url, this.title});

  final String url;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Its own dark ground rather than the app's surface: the photo is the
      // content here, and anything lighter competes with it.
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          title?.trim().isNotEmpty == true ? title!.trim() : 'Photo',
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Image.network(
            url,
            // No cacheWidth: this is the one place the full resolution is wanted.
            fit: BoxFit.contain,
            errorBuilder: (context, _, _) => const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'This photo could not be loaded. The link may be broken, or the '
                'file may have been removed from storage.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ),
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
          ),
        ),
      ),
    );
  }
}
