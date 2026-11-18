// SPDX-License-Identifier: GPL-3.0-or-later
// 1.0.2: a kickfile:// link from another app pairs only after the user confirms.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kickfile/app/android_hooks.dart';
import 'package:kickfile/core/errors.dart';
import 'package:kickfile/core/protocol.dart';
import 'package:kickfile/core/qr.dart';
import 'package:kickfile/storage/peers.dart';
import 'package:kickfile/ui/screens/device_actions.dart';
import 'package:kickfile/ui/theme/theme.dart';

final _fp = 'a' * 64;
final _link = PairingCode(
  addresses: const ['192.168.1.23'],
  port: kDefaultPort,
  fingerprint: _fp,
  secret: '482913',
  name: "Arjun's MacBook",
).toUri();

PeerRecord _peer(PairingCode c) => PeerRecord(fingerprint: c.fingerprint, name: c.name, platform: DevicePlatform.macos, trusted: true);

void main() {
  group('pairFromLink', () {
    test('declined: never contacts the device', () async {
      var paired = 0;
      PairingCode? asked;
      final r = await pairFromLink(
        _link,
        confirm: (c) async {
          asked = c;
          return false;
        },
        pair: (c) async {
          paired++;
          return _peer(c);
        },
      );
      expect(r, isNull);
      expect(paired, 0);
      expect(asked!.name, "Arjun's MacBook");
      expect(asked!.fingerprint, _fp);
    });

    test('confirmed: pairs with exactly the code in the link', () async {
      PairingCode? used;
      final r = await pairFromLink(
        _link,
        confirm: (_) async => true,
        pair: (c) async {
          used = c;
          return _peer(c);
        },
      );
      expect(r!.fingerprint, _fp);
      expect(used!.secret, '482913');
      expect(used!.addresses, ['192.168.1.23']);
    });

    test('a bad link fails before asking the user', () async {
      var asked = 0;
      Future<bool> confirm(PairingCode _) async {
        asked++;
        return true;
      }

      Future<PeerRecord> pair(PairingCode c) async => _peer(c);
      await expectLater(pairFromLink('kickfile://c?v=1&fp=zz', confirm: confirm, pair: pair), throwsA(isA<KfError>()));
      await expectLater(
        pairFromLink(_link.replaceFirst('v=1', 'v=2'), confirm: confirm, pair: pair),
        throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.versionMismatch)),
      );
      expect(asked, 0);
    });

    test('pairing errors still reach the caller after a yes', () async {
      await expectLater(
        pairFromLink(_link, confirm: (_) async => true, pair: (_) async => throw KfError(KfErrorCode.badSecret)),
        throwsA(isA<KfError>().having((e) => e.code, 'code', KfErrorCode.badSecret)),
      );
    });
  });

  group('confirmLinkPair dialog', () {
    Future<Future<bool>> open(WidgetTester t) async {
      late Future<bool> result;
      await t.pumpWidget(
        MaterialApp(
          theme: kfTheme(Brightness.light),
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => result = confirmLinkPair(c, PairingCode.parse(_link)),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      return result;
    }

    testWidgets('names the device and warns; Connect says yes', (t) async {
      final r = await open(t);
      expect(find.text('Connect to “Arjun\'s MacBook”?'), findsOneWidget);
      expect(find.textContaining('Show QR on your own device'), findsOneWidget);
      await t.tap(find.text('Connect'));
      await t.pumpAndSettle();
      expect(await r, isTrue);
    });

    testWidgets('Cancel says no', (t) async {
      final r = await open(t);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(await r, isFalse);
    });

    testWidgets('tapping outside the dialog says no', (t) async {
      final r = await open(t);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(await r, isFalse);
    });
  });
}
