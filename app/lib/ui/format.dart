import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../core/protocol.dart';

String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1000;
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} ${units[u]}';
}

/// Only real web links get an "Open link" button (BUG-019): "Note: buy milk" is not one.
bool isWebLink(String text) => RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(text.trim());

String formatSpeed(double bytesPerSecond) => '${(bytesPerSecond / 1e6).toStringAsFixed(1)} MB/s';

/// `1 min 52 s`, `48 s`, `2 h 5 min`.
String formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return 'under 1 s';
  if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
  if (d.inMinutes > 0) return '${d.inMinutes} min ${d.inSeconds % 60} s';
  return '${d.inSeconds < 1 ? 1 : d.inSeconds} s';
}

String formatEta(Duration? d) {
  if (d == null) return 'working out time left…';
  if (d.inSeconds < 5) return 'a few seconds left';
  if (d.inMinutes < 1) return 'about ${(d.inSeconds / 5).round() * 5} s left';
  if (d.inHours < 1) return 'about ${d.inMinutes + (d.inSeconds % 60 >= 30 ? 1 : 0)} min left';
  return 'about ${d.inHours} h ${d.inMinutes % 60} min left';
}

/// `0:48`
String formatCountdown(Duration d) {
  final s = d.inSeconds.clamp(0, 3600);
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String formatWhen(int ms, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  final diff = n.difference(t);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60 && t.day == n.day) return '${diff.inMinutes} min ago';
  String hm() => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == n.year && t.month == n.month && t.day == n.day) return hm();
  final y = n.subtract(const Duration(days: 1));
  if (t.year == y.year && t.month == y.month && t.day == y.day) return 'Yesterday';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]}';
}

/// `3 files`, `1 file`, `128 photos` when every file is an image.
String countFiles(int n, {Iterable<String> names = const []}) {
  final photos = names.isNotEmpty && names.every(isImageName);
  final noun = photos ? (n == 1 ? 'photo' : 'photos') : (n == 1 ? 'file' : 'files');
  return '$n $noun';
}

bool isImageName(String n) =>
    const {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.gif', '.webp', '.dng', '.raw', '.bmp', '.tif', '.tiff'}
        .contains(p.extension(n).toLowerCase());

bool isVideoName(String n) =>
    const {'.mov', '.mp4', '.m4v', '.mkv', '.avi', '.webm', '.3gp'}.contains(p.extension(n).toLowerCase());

IconData fileIcon(String name) {
  if (isImageName(name)) return LucideIcons.image;
  if (isVideoName(name)) return LucideIcons.fileVideo;
  final e = p.extension(name).toLowerCase();
  if (const {'.pdf', '.doc', '.docx', '.txt', '.md', '.rtf', '.odt', '.pages'}.contains(e)) return LucideIcons.fileText;
  if (const {'.zip', '.rar', '.7z', '.tar', '.gz'}.contains(e)) return LucideIcons.fileArchive;
  if (const {'.mp3', '.m4a', '.wav', '.flac', '.aac', '.ogg'}.contains(e)) return LucideIcons.fileAudio;
  return LucideIcons.file;
}

IconData platformIcon(DevicePlatform p) => switch (p) {
  DevicePlatform.android || DevicePlatform.ios => LucideIcons.smartphone,
  DevicePlatform.macos || DevicePlatform.linux => LucideIcons.laptop,
  DevicePlatform.windows || DevicePlatform.unknown => LucideIcons.monitor,
};

/// Plain-language reasons (design copy; never jargon).
String errorText(KfErrorCode? code, {String device = 'The other device'}) => switch (code) {
  null => 'Something went wrong. Try again.',
  KfErrorCode.declined => '$device declined.',
  KfErrorCode.timeout => "$device didn't respond.",
  KfErrorCode.busy => '$device is busy. Try again in a moment.',
  KfErrorCode.noSpace => '$device is out of space.',
  KfErrorCode.rateLimited => 'Wait a few seconds before sending again.',
  KfErrorCode.cancelled => 'Stopped.',
  KfErrorCode.hashMismatch => "Didn't arrive intact. Try again.",
  KfErrorCode.sourceChanged => 'Changed while sending. Try again.',
  KfErrorCode.sourceMissing => 'Moved or deleted on this device.',
  KfErrorCode.unreachable => "Can't reach $device. Make sure both are on the same Wi-Fi or hotspot.",
  KfErrorCode.identityMismatch => "$device isn't who it says it is. Check it's the right device.",
  KfErrorCode.versionMismatch => 'Update kickFile on $device to send files.',
  KfErrorCode.badSecret => 'This code has expired. Show a new one.',
  KfErrorCode.invalidOffer => "These files can't be sent as they are.",
  KfErrorCode.unauthorized => "$device couldn't confirm this device. Check the date and time are right on both devices.",
  _ => 'Something went wrong. Try again.',
};
