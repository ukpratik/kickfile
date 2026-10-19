// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/core/errors.dart';
import 'package:kickfile/core/names.dart';
import 'package:kickfile/core/protocol.dart';

Matcher invalid() => throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.invalidOffer));

void main() {
  group('validateRelPath', () {
    test('accepts normal relative paths', () {
      expect(validateRelPath('Trip/IMG_1.HEIC'), ['Trip', 'IMG_1.HEIC']);
      expect(validateRelPath('.bashrc'), ['.bashrc']);
    });
    for (final bad in ['', '/etc/passwd', '../x', 'a/../b', 'a//b', 'a/./b', r'a\b', 'C:/x', 'c:x', 'a\u0000b']) {
      test('rejects ${bad.replaceAll('\u0000', r'\0')}', () => expect(() => validateRelPath(bad), invalid()));
    }
  });

  group('sanitizeSegment', () {
    test('replaces characters Windows refuses and trims dots and spaces', () {
      expect(sanitizeSegment('a:b?.txt'), 'a_b_.txt');
      expect(sanitizeSegment('report. '), 'report');
      expect(sanitizeSegment('...'), '_');
    });
    test('prefixes reserved Windows names', () {
      expect(sanitizeSegment('CON'), '_CON');
      expect(sanitizeSegment('nul.txt'), '_nul.txt');
      expect(sanitizeSegment('console.txt'), 'console.txt');
    });
    test('keeps unicode and caps length at 200 bytes, keeping the extension', () {
      expect(sanitizeSegment('Fotos Ühlenbrück.jpg'), 'Fotos Ühlenbrück.jpg');
      final long = '${'é' * 300}.jpeg';
      final s = sanitizeSegment(long);
      expect(s.endsWith('.jpeg'), isTrue);
      expect(s.codeUnits.length < long.length, isTrue);
    });
  });

  test('collisionName', () {
    expect(collisionName('photo.jpg', 1), 'photo (1).jpg');
    expect(collisionName('.bashrc', 2), '.bashrc (2)');
    expect(collisionName('notes', 3), 'notes (3)');
  });

  group('TransferOffer.validate', () {
    TransferOffer offer(List<OfferItem> items, {String id = 'abcdef12-0000-4000-8000-000000000000'}) =>
        TransferOffer(id: id, senderName: 'A', senderPlatform: DevicePlatform.macos, items: items);
    const file = OfferItem(id: 'i0', kind: ItemKind.file, path: 'a.txt', size: 1);

    test('accepts a normal offer and round-trips JSON', () {
      final o = offer([file, const OfferItem(id: 'i1', kind: ItemKind.text, path: 'Text', size: 0, text: 'hi')]);
      o.validate();
      final back = TransferOffer.fromJson(o.toJson());
      expect(back.items.length, 2);
      expect(back.totalBytes, 1);
    });
    test('rejects duplicates, bad ids, empty, oversized text, dirs with size', () {
      expect(() => offer([file, file]).validate(), invalid());
      expect(() => offer([file], id: 'short').validate(), invalid());
      expect(() => offer([]).validate(), invalid());
      expect(
        () => offer([OfferItem(id: 'i0', kind: ItemKind.text, path: 'T', size: 0, text: 'x' * (kMaxTextChars + 1))]).validate(),
        invalid(),
      );
      expect(() => offer([const OfferItem(id: 'i0', kind: ItemKind.dir, path: 'd', size: 5)]).validate(), invalid());
      expect(() => offer([const OfferItem(id: 'i0', kind: ItemKind.file, path: 'a', size: -1)]).validate(), invalid());
    });
  });

  test('device names are cleaned', () {
    expect(cleanDeviceName('  Riya\'s iPhone\n'), "Riya's iPhone");
    expect(cleanDeviceName('\u0000'), 'Unnamed device');
    expect(cleanDeviceName('x' * 100).length, kMaxNameChars);
  });
}
