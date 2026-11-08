import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Applies a `bsdiff` patch (the BSDIFF40 format, made by `bsdiff` or Python's `bsdiff4`) to a file.
///
/// An update then needs only the difference between the build that is installed and the new one,
/// not the whole file. The result is checked against the SHA-256 the release publishes, so a wrong
/// base file (a build that was changed, or another one) can only lead to the full download.
///
/// Format (Colin Percival, "Naive differences of executable code"): a 32-byte header — the text
/// `BSDIFF40`, then the byte lengths of the control block and of the diff block and the size of the
/// new file, each as 8 bytes (little endian, the top bit is the sign) — followed by three
/// bzip2 streams: control (triples of add length, copy length, seek), diff and extra.
abstract final class BsPatch {
  static const _magic = 'BSDIFF40';
  static const _header = 32;

  /// Patches [basePath] with [patchPath] into [outPath], in another isolate so the screen stays
  /// responsive while a large file is put together.
  static Future<void> applyFiles(String basePath, String patchPath, String outPath) =>
      Isolate.run(() {
        final patched = apply(File(basePath).readAsBytesSync(), File(patchPath).readAsBytesSync());
        File(outPath).writeAsBytesSync(patched, flush: true);
      });

  /// The new file made from [base] and [patch]. Throws a [FormatException] for a patch that is
  /// damaged or does not fit [base].
  static Uint8List apply(Uint8List base, Uint8List patch) {
    if (patch.length < _header || String.fromCharCodes(patch.sublist(0, 8)) != _magic) {
      throw const FormatException('not a BSDIFF40 patch');
    }
    final controlLength = _offset(patch, 8);
    final diffLength = _offset(patch, 16);
    final newSize = _offset(patch, 24);
    if (controlLength < 0 || diffLength < 0 || newSize < 0 || _header + controlLength + diffLength > patch.length) {
      throw const FormatException('the patch header is damaged');
    }

    final bzip = BZip2Decoder();
    final control = bzip.decodeBytes(patch.sublist(_header, _header + controlLength));
    final diff = bzip.decodeBytes(patch.sublist(_header + controlLength, _header + controlLength + diffLength));
    final extra = bzip.decodeBytes(patch.sublist(_header + controlLength + diffLength));

    final out = Uint8List(newSize);
    var newPos = 0, oldPos = 0, diffPos = 0, extraPos = 0, controlPos = 0;
    while (newPos < newSize) {
      if (controlPos + 24 > control.length) throw const FormatException('the control block ends early');
      final add = _offset(control, controlPos);
      final copy = _offset(control, controlPos + 8);
      final seek = _offset(control, controlPos + 16);
      controlPos += 24;

      if (add < 0 || copy < 0 || newPos + add > newSize || diffPos + add > diff.length) {
        throw const FormatException('the patch does not fit');
      }
      for (var i = 0; i < add; i++) {
        final at = oldPos + i;
        out[newPos + i] = (diff[diffPos + i] + (at >= 0 && at < base.length ? base[at] : 0)) & 0xff;
      }
      newPos += add;
      diffPos += add;
      oldPos += add;

      if (newPos + copy > newSize || extraPos + copy > extra.length) {
        throw const FormatException('the patch does not fit');
      }
      out.setRange(newPos, newPos + copy, extra, extraPos);
      newPos += copy;
      extraPos += copy;
      oldPos += seek;
    }
    return out;
  }

  /// bsdiff's own integer: 8 bytes little endian, the top bit of the last byte is the sign.
  static int _offset(Uint8List bytes, int at) {
    var magnitude = bytes[at + 7] & 0x7f;
    for (var i = 6; i >= 0; i--) {
      magnitude = magnitude * 256 + bytes[at + i];
    }
    return bytes[at + 7] & 0x80 != 0 ? -magnitude : magnitude;
  }
}
