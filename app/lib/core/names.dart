// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'errors.dart';

const _maxSegmentBytes = 200;
const _maxSegments = 64;
const _windowsReserved = {
  'CON', 'PRN', 'AUX', 'NUL', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Splits a relative path from a peer into safe segments, or throws
/// [KfErrorCode.invalidOffer]. Rejects anything that could escape the save folder.
List<String> validateRelPath(String path) {
  KfError bad(String why) => KfError(KfErrorCode.invalidOffer, 'path $why');
  if (path.isEmpty) throw bad('empty');
  if (path.contains('\u0000')) throw bad('has NUL');
  if (path.contains('\\')) throw bad('has backslash');
  if (path.startsWith('/')) throw bad('is absolute');
  if (RegExp(r'^[A-Za-z]:').hasMatch(path)) throw bad('has a drive');
  final parts = path.split('/');
  if (parts.length > _maxSegments) throw bad('too deep');
  for (final p in parts) {
    if (p.isEmpty || p == '.' || p == '..') throw bad('has an empty or dot segment');
  }
  return parts;
}

/// Makes one path segment valid on every desktop OS we write to.
String sanitizeSegment(String segment) {
  var s = segment.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F/\\]'), '_');
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty) s = '_';
  final stem = s.split('.').first.toUpperCase();
  if (_windowsReserved.contains(stem)) s = '_$s';
  return _truncateUtf8(s, _maxSegmentBytes);
}

List<String> safeSegments(String relPath) => validateRelPath(relPath).map(sanitizeSegment).toList();

/// `photo.jpg` → `photo (1).jpg`; `.bashrc` → `.bashrc (1)`; `notes` → `notes (1)`.
String collisionName(String name, int n) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '$name ($n)';
  return '${name.substring(0, dot)} ($n)${name.substring(dot)}';
}

String _truncateUtf8(String s, int maxBytes) {
  if (utf8.encode(s).length <= maxBytes) return s;
  final dot = s.lastIndexOf('.');
  final ext = (dot > 0 && s.length - dot <= 16) ? s.substring(dot) : '';
  var stem = ext.isEmpty ? s : s.substring(0, dot);
  final budget = maxBytes - utf8.encode(ext).length;
  final runes = stem.runes.toList();
  while (runes.isNotEmpty && utf8.encode(String.fromCharCodes(runes)).length > budget) {
    runes.removeLast();
  }
  stem = String.fromCharCodes(runes);
  return '$stem$ext';
}
