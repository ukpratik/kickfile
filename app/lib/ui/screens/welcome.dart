import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/protocol.dart';
import '../scope.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

/// One welcome screen, device name editable inline, no account (US-001, M-01).
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  late final TextEditingController _name;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _name = TextEditingController(text: context.services.node.settings.value.deviceName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final s = context.services;
    final name = _name.text.trim().isEmpty ? s.node.settings.value.deviceName : cleanDeviceName(_name.text);
    await s.node.settings.update((x) => x.copyWith(deviceName: name, onboarded: true));
    await s.discovery.updateBroadcast();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(KfSpace.s6),
              children: [
                const Center(child: KfMark(size: 64)),
                const SizedBox(height: KfSpace.s5),
                Text('Move files between your phone and laptop', style: tt.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: KfSpace.s2),
                Text(
                  'Over your Wi-Fi or a hotspot. Full quality, encrypted. No account, no internet.',
                  style: tt.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KfSpace.s6),
                TextField(
                  controller: _name,
                  autofocus: Platform.isIOS,
                  maxLength: kMaxNameChars,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _start(),
                  decoration: const InputDecoration(
                    labelText: 'This device’s name',
                    helperText: 'Name it so your other devices recognise it',
                  ),
                ),
                const SizedBox(height: KfSpace.s4),
                FilledButton(onPressed: _start, child: const Text('Get started')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
