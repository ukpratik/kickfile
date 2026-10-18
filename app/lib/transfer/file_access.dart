import '../core/protocol.dart';

/// Something the user chose to send.
class SendSource {
  const SendSource({
    required this.kind,
    required this.relPath,
    this.ref = '',
    this.size = 0,
    this.mtime = 0,
    this.text,
    this.mime,
  });

  const SendSource.text(String this.text)
    : kind = ItemKind.text,
      relPath = 'Text',
      ref = '',
      size = 0,
      mtime = 0,
      mime = 'text/plain';

  final ItemKind kind;

  /// Path the receiver recreates, `/`-separated (`Trip/IMG_1.HEIC`).
  final String relPath;

  /// Where to read it: a file path (desktop) or a content URI (Android).
  final String ref;
  final int size;
  final int mtime;
  final String? text;
  final String? mime;

  String get name => relPath.split('/').last;
}

class SourceStat {
  const SourceStat(this.size, this.mtime);
  final int size;
  final int mtime;
}

/// Append-only writer into a partial file.
abstract class PartialWriter {
  Future<void> add(List<int> chunk);
  Future<void> close();
}

/// Platform file I/O used by the transfer engine (LLD §3.2).
/// Partial refs and final locations are opaque strings owned by the implementation.
abstract class FileAccess {
  // ---- sending ----
  Stream<List<int>> openRead(SendSource source, {int offset = 0});
  Future<SourceStat?> stat(SendSource source);

  // ---- receiving ----
  /// Creates (or truncates) the partial for one item. Returns its ref.
  Future<String> createPartial(String transferId, String itemId, String relPath, int size);
  Future<int> partialLength(String partialRef);
  Stream<List<int>> readPartial(String partialRef);

  /// Opens the partial for writing at [offset], truncating anything after it.
  Future<PartialWriter> openPartial(String partialRef, int offset);

  /// Moves a complete partial to its final, collision-free place. Returns the location.
  Future<String> finalize(String partialRef, String relPath, {int mtime = 0});
  Future<void> discard(String partialRef);
  Future<void> createDir(String relPath);

  /// Deletes whatever is left of a transfer's partials (finished, cancelled, expired).
  Future<void> removeTransferPartials(String transferId);

  /// Free space where received files go; null if unknown.
  Future<int?> freeBytes();
}
