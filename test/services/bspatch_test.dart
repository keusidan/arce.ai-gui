import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arce_ai/services/bspatch.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bsdiff_fixture.dart';

void main() {
  test('a patch made by bsdiff gives back the new file, byte for byte', () {
    final patched = BsPatch.apply(bsdiffOld, bsdiffPatch);
    expect(patched.length, 6077);
    expect(sha256.convert(patched).toString(), bsdiffNewSha256);
  });

  test('a different base file gives a different result, which the checksum then refuses', () {
    final other = Uint8List.fromList(bsdiffOld)..[10] ^= 0xff;
    expect(sha256.convert(BsPatch.apply(other, bsdiffPatch)).toString(), isNot(bsdiffNewSha256));
  });

  test('damaged patches are refused with a FormatException', () {
    expect(() => BsPatch.apply(bsdiffOld, Uint8List(10)), throwsFormatException);
    expect(() => BsPatch.apply(bsdiffOld, Uint8List.fromList(utf8.encode('NOTAPATCH' * 8))), throwsFormatException);
    final cut = Uint8List.fromList(bsdiffPatch.sublist(0, 60));
    expect(() => BsPatch.apply(bsdiffOld, cut), throwsA(anything));
    final headerOnly = Uint8List.fromList(bsdiffPatch.sublist(0, 32));
    expect(() => BsPatch.apply(bsdiffOld, headerOnly), throwsA(anything));
  });

  test('files are patched in another isolate', () async {
    final dir = await Directory.systemTemp.createTemp('arce_bspatch');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/old.bin').writeAsBytesSync(bsdiffOld);
    File('${dir.path}/p.patch').writeAsBytesSync(bsdiffPatch);

    await BsPatch.applyFiles('${dir.path}/old.bin', '${dir.path}/p.patch', '${dir.path}/new.bin');
    expect(sha256.convert(File('${dir.path}/new.bin').readAsBytesSync()).toString(), bsdiffNewSha256);
  });
}
