import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// An image the user added, kept as the bytes the provider will receive.
class ImageData {
  const ImageData(this.mimeType, this.bytes);

  /// `image/png`, `image/jpeg`, `image/gif` or `image/webp`: the formats vision models take.
  final String mimeType;
  final Uint8List bytes;

  /// A stable id from the content, so the same picture is one entry and an id kept in a saved
  /// conversation can never point at a different picture later.
  String get id => sha256.convert(bytes).toString().substring(0, 16);

  /// The form the OpenAI chat protocol takes an image in.
  String get dataUrl => 'data:$mimeType;base64,${base64Encode(bytes)}';
}

/// A file the user added to a message: decoded to text, or an image for a model that can see.
class Attachment {
  const Attachment(this.name, this.text, {this.image});

  final String name;

  /// The file's text; empty for an image.
  final String text;
  final ImageData? image;
}

/// A file that cannot be added; [message] can be shown as it is.
class AttachmentException implements Exception {
  const AttachmentException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// How much of the attached files is kept. The defaults are `AttachmentPolicy`'s; the user can
/// change them in the settings.
class AttachmentLimits {
  const AttachmentLimits({
    this.maxFiles = AttachmentPolicy.maxFiles,
    this.maxCharsPerFile = AttachmentPolicy.maxCharsPerFile,
    this.maxTotalChars = AttachmentPolicy.maxTotalChars,
    this.maxImageBytes = AttachmentReader.maxImageBytes,
  });

  final int maxFiles;
  final int maxCharsPerFile;
  final int maxTotalChars;
  final int maxImageBytes;
}

/// Decides how a file is read: as an image when the model can take one, otherwise as text.
abstract final class AttachmentReader {
  /// Under every provider's per-image limit (Anthropic's is the lowest, 5 MB).
  static const maxImageBytes = 4 * 1024 * 1024;

  /// The image type of [bytes], read from the file's first bytes rather than its name (a
  /// renamed file is still what it is), or null when it is not one a vision model takes.
  static String? imageType(Uint8List bytes) {
    bool starts(List<int> signature, [int offset = 0]) {
      if (bytes.length < offset + signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[offset + i] != signature[i]) return false;
      }
      return true;
    }

    if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'image/png';
    if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (starts(const [0x47, 0x49, 0x46, 0x38]) && (starts(const [0x37, 0x61], 4) || starts(const [0x39, 0x61], 4))) {
      return 'image/gif';
    }
    // RIFF....WEBP
    if (starts(const [0x52, 0x49, 0x46, 0x46]) && starts(const [0x57, 0x45, 0x42, 0x50], 8)) return 'image/webp';
    return null;
  }

  /// Reads one file. [acceptImages] is whether the model in use can take images.
  ///
  /// An image the model cannot take is refused with a reason instead of being read as text:
  /// its bytes are not text, and the model would be answering about garbage.
  static Attachment read(
    String name,
    Uint8List bytes, {
    required bool acceptImages,
    int maxImageBytes = AttachmentReader.maxImageBytes,
  }) {
    final type = imageType(bytes);
    if (type != null) {
      if (!acceptImages) {
        throw AttachmentException('$name は画像です。いまのモデルは画像に対応していません');
      }
      if (bytes.length > maxImageBytes) {
        final mb = (bytes.length / 1048576).toStringAsFixed(1);
        throw AttachmentException('$name は大きすぎます（$mb MB。上限は${maxImageBytes ~/ 1048576} MB。設定で変えられます）');
      }
      return Attachment(name, '', image: ImageData(type, bytes));
    }

    // text only: a file that is not valid UTF-8 would fill the context with garbage
    final String text;
    try {
      final body = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
          ? bytes.sublist(3)
          : bytes;
      text = const Utf8Decoder(allowMalformed: false).convert(body);
    } on FormatException {
      throw AttachmentException('$name はテキストでも対応する画像でもないため、読めませんでした');
    }
    // zero bytes are valid UTF-8 but never in a text file (an executable, an archive ...)
    if (text.contains('\u0000')) {
      throw AttachmentException('$name はテキストでも対応する画像でもないため、読めませんでした');
    }
    return Attachment(name, text);
  }
}

/// Where an image sits in a prompt. The prompt is one text, so a picture is marked in place and
/// the bytes travel beside it; whoever builds the provider's messages swaps the marker for the
/// picture (a model that can see) or for the file name (one that cannot).
abstract final class ImageMarker {
  static String of(String name, ImageData image) => '<image id="${image.id}" name="${_clean(name)}"/>';

  /// Matches [of]; group 1 is the id, group 2 the file name.
  static final pattern = RegExp(r'<image id="([0-9a-f]{16})" name="([^"<>]*)"/>');

  static String _clean(String name) => name.replaceAll(RegExp(r'["<>]'), "'");
}

/// Keeps attachments from swamping the context window (spec §18): caps the number of files
/// and the characters taken from each and in total, and says so when it cuts.
abstract final class AttachmentPolicy {
  static const maxFiles = 5;
  static const maxCharsPerFile = 8000;
  static const maxTotalChars = 16000;

  static String compose(
    String text,
    List<Attachment> attachments, {
    AttachmentLimits limits = const AttachmentLimits(),
  }) {
    if (attachments.isEmpty) return text;
    var budget = limits.maxTotalChars;
    final b = StringBuffer();
    for (final file in attachments.take(limits.maxFiles)) {
      final image = file.image;
      if (image != null) {
        // pictures cost no characters of the text budget
        b
          ..write(ImageMarker.of(file.name, image))
          ..write('\n');
        continue;
      }
      final limit = budget < limits.maxCharsPerFile ? budget : limits.maxCharsPerFile;
      final body = file.text.length > limit ? file.text.substring(0, limit) : file.text;
      budget -= body.length;
      b
        ..write('<file name="')
        ..write(file.name.replaceAll('"', "'"))
        ..write('">\n')
        ..write(body);
      if (body.length < file.text.length) {
        b.write('\n[… ${file.text.length - body.length} characters omitted …]');
      }
      b.write('\n</file>\n');
    }
    if (attachments.length > limits.maxFiles) {
      b.write('[${attachments.length - limits.maxFiles} more files not included]\n');
    }
    b.write(text);
    return b.toString();
  }
}
