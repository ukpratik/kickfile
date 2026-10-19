// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/sas.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';

/// "DEVICES", "RECENT" with an optional trailing action.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, KfSpace.s5, 0, KfSpace.s2),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Grouped list card with hairline dividers between children.
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children, this.padding = EdgeInsets.zero});
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) items.add(const Divider(indent: 64));
      items.add(children[i]);
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: Column(mainAxisSize: MainAxisSize.min, children: items)),
    );
  }
}

enum RingMode { none, progress, countdown, paused, done }

/// The 40 px device tile with the B-direction progress ring around it (48 px box).
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.icon,
    this.ring = RingMode.none,
    this.value = 0,
    this.dimmed = false,
    this.dashed = false,
  });

  final IconData icon;
  final RingMode ring;

  /// 0..1 progress, or the remaining fraction for a countdown.
  final double value;
  final bool dimmed;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kf = KfColors.of(context);
    final ringColor = switch (ring) {
      RingMode.paused => kf.warning,
      RingMode.done => kf.success,
      _ => cs.primary,
    };
    return SizedBox.square(
      dimension: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: dimmed ? cs.surfaceContainerHigh : cs.secondaryContainer,
              borderRadius: BorderRadius.circular(KfRadius.sm),
              border: dashed ? Border.all(color: cs.primary, width: 1.5) : null,
            ),
            child: Icon(
              ring == RingMode.done ? LucideIcons.check : icon,
              size: 22,
              color: dimmed ? cs.outline : cs.onSecondaryContainer,
            ),
          ),
          if (ring != RingMode.none)
            TweenAnimationBuilder<double>(
              tween: Tween(end: ring == RingMode.done ? 1 : value.clamp(0, 1)),
              duration: KfMotion.reduced(context) ? Duration.zero : const Duration(milliseconds: 500),
              builder: (context, v, _) => CustomPaint(
                size: const Size.square(48),
                painter: _RingPainter(v, ringColor, cs.secondaryContainer),
              ),
            ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track);
  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(1.5);
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(14));
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(rr, trackPaint);
    if (value <= 0) return;
    final path = Path()..addRRect(rr);
    final metric = path.computeMetrics().first;
    // Start at 12 o'clock: the RRect path starts at the left of the top edge.
    final start = metric.length * 0.0 + (r.width / 2 - 14);
    final len = metric.length * value;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final end = start + len;
    if (end <= metric.length) {
      canvas.drawPath(metric.extractPath(start, end), paint);
    } else {
      canvas.drawPath(metric.extractPath(start, metric.length), paint);
      canvas.drawPath(metric.extractPath(0, end - metric.length), paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.color != color || old.track != track;
}

enum BannerTone { info, warning, danger, success, neutral }

class KfBanner extends StatelessWidget {
  const KfBanner({super.key, required this.text, this.tone = BannerTone.info, this.icon, this.action, this.title});
  final String text;
  final String? title;
  final BannerTone tone;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kf = KfColors.of(context);
    final (bg, fg, ic) = switch (tone) {
      BannerTone.info => (cs.secondaryContainer, cs.onSecondaryContainer, LucideIcons.info),
      BannerTone.warning => (kf.warningSoft, kf.warning, LucideIcons.triangleAlert),
      BannerTone.danger => (cs.errorContainer, cs.error, LucideIcons.octagonAlert),
      BannerTone.success => (kf.successSoft, kf.success, LucideIcons.circleCheck),
      BannerTone.neutral => (cs.surfaceContainerLow, cs.onSurfaceVariant, LucideIcons.info),
    };
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(KfSpace.s3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(KfRadius.md)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? ic, size: 20, color: fg),
          const SizedBox(width: KfSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) Text(title!, style: tt.labelLarge!.copyWith(color: cs.onSurface)),
                Text(text, style: tt.bodyMedium!.copyWith(color: cs.onSurface)),
                if (action != null) Padding(padding: const EdgeInsets.only(top: KfSpace.s2), child: action),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `482 913`, read digit by digit by screen readers.
class CodeDisplay extends StatelessWidget {
  const CodeDisplay(this.code, {super.key, this.size = 36});
  final String code;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Code ${code.split('').join(' ')}',
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: KfSpace.s4, vertical: KfSpace.s2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(KfRadius.md),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(code.length == 6 ? formatCode(code) : code, style: codeStyle(context, size: size)),
      ),
    ),
  );
}

/// Online / offline dot plus the word: status never by colour alone.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    final c = online ? KfColors.of(context).success : Theme.of(context).colorScheme.outline;
    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: online ? c : Colors.transparent,
        border: Border.all(color: c, width: 1.5),
      ),
    );
  }
}

/// The "Looking for more" shimmer bar (static under reduce motion).
class SearchingShimmer extends StatefulWidget {
  const SearchingShimmer({super.key});
  @override
  State<SearchingShimmer> createState() => _SearchingShimmerState();
}

class _SearchingShimmerState extends State<SearchingShimmer> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduced = KfMotion.reduced(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 44,
          height: 3,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              painter: _ShimmerPainter(reduced ? 0.5 : _c.value, cs.primary, cs.secondaryContainer),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('Looking for more', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter(this.t, this.color, this.track);
  final double t;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size s) {
    final r = RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(2));
    canvas.drawRRect(r, Paint()..color = track);
    final x = (s.width + 20) * t - 20;
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(Rect.fromLTWH(x, 0, 20, s.height), Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => old.t != t;
}

/// Title + text + actions for empty and full-screen states.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.text, this.actions = const []});
  final IconData icon;
  final String title;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KfSpace.s6, horizontal: KfSpace.s4),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: cs.secondaryContainer, shape: BoxShape.circle),
            child: Icon(icon, color: cs.onSecondaryContainer),
          ),
          const SizedBox(height: KfSpace.s3),
          Text(title, style: tt.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: KfSpace.s1),
          Text(text, style: tt.bodyMedium, textAlign: TextAlign.center),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: KfSpace.s4),
            Wrap(spacing: KfSpace.s2, runSpacing: KfSpace.s2, alignment: WrapAlignment.center, children: actions),
          ],
        ],
      ),
    );
  }
}

/// The kickFile "Beam" mark: a file sending a local signal. Brand colours in every theme (tool/icons/build_icons.py).
class KfMark extends StatelessWidget {
  const KfMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'kickFile',
    child: CustomPaint(size: Size.square(size), painter: const _MarkPainter()),
  );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 1024;
    canvas.scale(s);
    const tile = Rect.fromLTWH(0, 0, 1024, 1024);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tile, const Radius.circular(230)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment(-0.3, 1),
          colors: [Color(0xFF7C5CF2), Color(0xFF5130C2)],
        ).createShader(tile),
    );
    final doc = Path()
      ..moveTo(248, 440)
      ..lineTo(432, 440)
      ..lineTo(512, 520)
      ..lineTo(512, 800)
      ..quadraticBezierTo(512, 840, 472, 840)
      ..lineTo(248, 840)
      ..quadraticBezierTo(208, 840, 208, 800)
      ..lineTo(208, 480)
      ..quadraticBezierTo(208, 440, 248, 440)
      ..close();
    canvas.drawPath(doc, Paint()..color = Colors.white);
    final arc = Paint()
      ..color = const Color(0xFFFF7A59)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 60
      ..strokeCap = StrokeCap.round;
    for (final r in [140.0, 270.0]) {
      canvas.drawArc(Rect.fromCircle(center: const Offset(540, 460), radius: r), -math.pi / 2, math.pi / 2, false, arc);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}

Future<void> copyText(BuildContext context, String text, {String done = 'Copied'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done), duration: const Duration(seconds: 2)));
  }
}

double clamp01(num v) => math.max(0, math.min(1, v.toDouble()));
