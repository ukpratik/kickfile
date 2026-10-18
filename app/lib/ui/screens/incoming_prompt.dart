import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/protocol.dart';
import '../../transfer/receiver.dart';
import '../format.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'device_actions.dart';

/// Shows the prompt for [req] (dialog on desktop, sheet on mobile) until it's answered or expires.
Future<void> showIncomingPrompt(BuildContext context, IncomingRequest req) async {
  final body = IncomingPrompt(request: req);
  if (isDesktop) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(KfSpace.s4),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: body),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      builder: (_) => SafeArea(child: body),
    );
  }
}

class IncomingPrompt extends StatefulWidget {
  const IncomingPrompt({super.key, required this.request});
  final IncomingRequest request;

  @override
  State<IncomingPrompt> createState() => _IncomingPromptState();
}

class _IncomingPromptState extends State<IncomingPrompt> {
  Timer? _tick;
  bool _checkCode = false;

  IncomingRequest get r => widget.request;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (r.answered || DateTime.now().isAfter(r.expiresAt)) {
        _close();
      } else {
        setState(() {});
      }
    });
    unawaited(r.decision.then((_) => _close()));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _close() {
    _tick?.cancel();
    if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop();
  }

  void _answer(Decision d) => r.answer(d);

  Future<void> _block() async {
    if (await confirmBlock(context, r.senderName)) _answer(Decision.block);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final kf = KfColors.of(context);
    final offer = r.offer;
    final name = r.senderName;
    final files = offer.items.where((i) => i.kind == ItemKind.file).toList();
    final text = offer.items.where((i) => i.kind == ItemKind.text).firstOrNull;
    final what = files.isEmpty
        ? 'text'
        : files.length == 1
        ? files.first.name
        : countFiles(files.length, names: files.map((f) => f.path));
    final left = r.expiresAt.difference(DateTime.now());
    final changed = r.identityChangedFrom != null && !_checkCode;
    final trust = r.firstContact && !changed;

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DeviceTile(icon: platformIcon(offer.senderPlatform), ring: RingMode.countdown, value: clamp01(left.inMilliseconds / kOfferTimeout.inMilliseconds)),
        const SizedBox(width: KfSpace.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                changed ? "$name's identity changed" : (trust ? 'Trust $name?' : '$name wants to send ${files.isEmpty ? 'text' : countFiles(files.length)}'),
                style: tt.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                trust || changed
                    ? 'Wants to send $what · ${formatBytes(offer.totalBytes)}${trust ? ' · first time' : ''}'
                    : [
                        offer.senderPlatform.label,
                        if (r.peer?.trusted ?? false) 'Trusted',
                        if (files.isNotEmpty) '${formatBytes(offer.totalBytes)} in total',
                        if (r.recentDeclines >= 2) '${_ordinal(r.recentDeclines + 1)} request in 10 min',
                      ].join(' · '),
                style: tt.bodySmall,
              ),
            ],
          ),
        ),
        Text(formatCountdown(left), style: tt.labelLarge!.copyWith(color: kf.textTertiary)),
      ],
    );

    final fileList = Column(
      children: [
        for (final f in files.take(3))
          Padding(
            padding: const EdgeInsets.only(top: KfSpace.s2),
            child: Row(
              children: [
                Icon(fileIcon(f.name), size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: KfSpace.s2),
                Expanded(child: Text(f.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyMedium!.copyWith(color: cs.onSurface))),
                Text(formatBytes(f.size), style: tt.bodySmall),
              ],
            ),
          ),
        if (files.length > 3)
          Padding(
            padding: const EdgeInsets.only(top: KfSpace.s2),
            child: Align(alignment: Alignment.centerLeft, child: Text('and ${files.length - 3} more', style: tt.bodySmall)),
          ),
        if (text != null)
          Padding(
            padding: const EdgeInsets.only(top: KfSpace.s2),
            child: Row(
              children: [
                Icon(LucideIcons.messageSquareText, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: KfSpace.s2),
                Expanded(child: Text(text.text ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: tt.bodyMedium)),
              ],
            ),
          ),
      ],
    );

    final List<Widget> content;
    if (changed) {
      content = [
        KfBanner(
          tone: BannerTone.danger,
          text: "If you didn't reinstall kickFile on it, don't accept. Someone else may be using its name. Auto-accept is off until you trust it again.",
        ),
        const SizedBox(height: KfSpace.s4),
        FilledButton(onPressed: () => _answer(Decision.decline), child: const Text('Decline')),
        const SizedBox(height: KfSpace.s2),
        OutlinedButton(onPressed: () => setState(() => _checkCode = true), child: const Text('I reinstalled it · check the code')),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: cs.error),
          onPressed: _block,
          child: const Text('Block this device…'),
        ),
      ];
    } else if (trust || _checkCode) {
      content = [
        fileList,
        const SizedBox(height: KfSpace.s4),
        Text('Check $name shows', style: tt.bodySmall),
        const SizedBox(height: KfSpace.s2),
        CodeDisplay(r.code),
        const SizedBox(height: KfSpace.s4),
        FilledButton(autofocus: true, onPressed: () => _answer(Decision.trustAuto), child: const Text('Trust & auto-accept')),
        const SizedBox(height: KfSpace.s2),
        FilledButton.tonal(onPressed: () => _answer(Decision.trust), child: const Text('Trust')),
        const SizedBox(height: KfSpace.s2),
        OutlinedButton(onPressed: () => _answer(Decision.accept), child: const Text('Just this once')),
        TextButton(onPressed: () => _answer(Decision.decline), child: const Text('Decline')),
        if (r.recentDeclines >= 2)
          TextButton(style: TextButton.styleFrom(foregroundColor: cs.error), onPressed: _block, child: const Text('Block this device')),
        const SizedBox(height: KfSpace.s2),
        Text(
          'Only trust devices you recognise. Change it any time in Settings › Trusted devices.',
          style: tt.bodySmall,
          textAlign: TextAlign.center,
        ),
      ];
    } else {
      content = [
        fileList,
        const SizedBox(height: KfSpace.s4),
        Row(
          children: [
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(LucideIcons.ellipsis),
              onSelected: (_) => _block(),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'block', child: Text('Block $name…', style: TextStyle(color: cs.error))),
              ],
            ),
            const Spacer(),
            OutlinedButton(onPressed: () => _answer(Decision.decline), child: const Text('Decline')),
            const SizedBox(width: KfSpace.s2),
            FilledButton(autofocus: true, onPressed: () => _answer(Decision.accept), child: const Text('Accept')),
          ],
        ),
        if (r.recentDeclines >= 2)
          Padding(
            padding: const EdgeInsets.only(top: KfSpace.s2),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: cs.error, side: BorderSide(color: cs.error)),
              onPressed: _block,
              child: const Text('Block this device'),
            ),
          ),
      ];
    }

    return Semantics(
      liveRegion: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(KfSpace.s5, KfSpace.s5, KfSpace.s5, KfSpace.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, const SizedBox(height: KfSpace.s2), ...content],
        ),
      ),
    );
  }
}

String _ordinal(int n) => switch (n % 10) {
  1 when n % 100 != 11 => '${n}st',
  2 when n % 100 != 12 => '${n}nd',
  3 when n % 100 != 13 => '${n}rd',
  _ => '${n}th',
};
