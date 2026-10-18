import 'package:flutter/material.dart';

import '../../core/protocol.dart';

/// Send → Text: type or paste up to 100,000 characters (US-004).
Future<String?> composeText(BuildContext context, String deviceName) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Send text to $deviceName'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: 4,
            maxLines: 10,
            maxLength: kMaxTextChars,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Type or paste a note or a link'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: c.text.trim().isEmpty ? null : () => Navigator.pop(context, c.text),
            child: const Text('Send'),
          ),
        ],
      ),
    ),
  );
}
