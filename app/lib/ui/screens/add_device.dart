import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../theme/tokens.dart';
import '../widgets/common.dart';

/// Static download page (A-21). Created at release (launch checklist); no tracking.
const kDownloadUrl = 'https://ukpratik.github.io/kickfile/get';

/// "Get kickFile on the other device" (US-019, M-10).
class AddDeviceScreen extends StatelessWidget {
  const AddDeviceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Add a device')),
      body: ListView(
        padding: const EdgeInsets.all(KfSpace.gutter),
        children: [
          Text('Get kickFile on your other phone or laptop', style: tt.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: KfSpace.s1),
          Text(
            'Scan with the phone’s camera, or open the link on the other device. It picks the right download.',
            style: tt.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: KfSpace.s4),
          Center(
            child: Container(
              padding: const EdgeInsets.all(KfSpace.s3),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(KfRadius.md)),
              child: QrImageView(data: kDownloadUrl, size: 200, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: KfSpace.s4),
          Center(child: SelectableText(kDownloadUrl, style: tt.bodyLarge)),
          const SizedBox(height: KfSpace.s2),
          Center(
            child: TextButton(onPressed: () => copyText(context, kDownloadUrl, done: 'Link copied'), child: const Text('Copy link')),
          ),
          const SizedBox(height: KfSpace.s4),
          const KfBanner(
            text: 'Then open kickFile on both devices, on the same Wi-Fi. They find each other by themselves.',
          ),
        ],
      ),
    );
  }
}
