import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/protocol.dart';
import '../net/client.dart';
import '../storage/history.dart';
import 'file_access.dart';
import 'sender.dart';

/// Owns outgoing jobs and records them in history.
class TransferService extends ChangeNotifier {
  TransferService({
    required this.client,
    required this.files,
    required this.history,
    required this.me,
    this.autoRetryFor = const Duration(seconds: 30),
    this.retryEvery = const Duration(seconds: 3),
  });

  final Duration autoRetryFor;
  final Duration retryEvery;

  final KfClient client;
  final FileAccess files;
  final HistoryStore history;
  final DeviceInfo Function() me;
  final _jobs = <SendJob>[];

  /// Fires when any job's state changes (keep-awake, notifications).
  final _changes = StreamController<SendJob>.broadcast();
  Stream<SendJob> get jobChanges => _changes.stream;

  List<SendJob> get jobs => List.unmodifiable(_jobs);
  /// Jobs moving or about to move. A job waiting for the user's Resume isn't active:
  /// it releases the wake lock, the Android service and the tray status (BUG-005).
  Iterable<SendJob> get activeJobs => _jobs.where((j) => !j.isFinished && !j.waitingForResume);
  bool get hasActiveTransfer => activeJobs.isNotEmpty;

  SendJob send({
    required PeerEndpoint to,
    required String peerName,
    required DevicePlatform peerPlatform,
    required List<SendSource> sources,
  }) {
    final job = SendJob(
      id: const Uuid().v4(),
      endpoint: to,
      peerName: peerName,
      peerPlatform: peerPlatform,
      me: me(),
      sources: sources,
      client: client,
      files: files,
      autoRetryFor: autoRetryFor,
      retryEvery: retryEvery,
    );
    _jobs.insert(0, job);
    SendState? lastState;
    job.addListener(() {
      if (job.state != lastState) {
        lastState = job.state;
        unawaited(_record(job));
        _changes.add(job);
      }
      notifyListeners();
    });
    notifyListeners();
    unawaited(job.run());
    return job;
  }

  /// Removes a finished job from the active list (its history stays).
  void dismiss(SendJob job) {
    if (!job.isFinished) return;
    _jobs.remove(job);
    job.dispose();
    notifyListeners();
  }

  Future<void> _record(SendJob job) {
    final status = switch (job.state) {
      SendState.waiting => HistoryStatus.waiting,
      SendState.active => HistoryStatus.active,
      SendState.paused => HistoryStatus.paused,
      SendState.done => HistoryStatus.done,
      SendState.partial => HistoryStatus.partial,
      SendState.failed => HistoryStatus.failed,
      SendState.cancelled => HistoryStatus.cancelled,
      SendState.declined => HistoryStatus.declined,
      SendState.timeout => HistoryStatus.missed,
      SendState.busy => HistoryStatus.busy,
    };
    return history.put(
      HistoryEntry(
        id: job.id,
        direction: Direction.outgoing,
        peerFingerprint: job.endpoint.fingerprint,
        peerName: job.peerName,
        peerPlatform: job.peerPlatform,
        startedAt: job.startedAt.millisecondsSinceEpoch,
        finishedAt: job.finishedAt?.millisecondsSinceEpoch,
        status: status,
        totalBytes: job.totalBytes,
        doneBytes: job.sentBytes,
        fileCount: job.fileCount,
        doneFiles: job.doneFiles,
        items: [
          for (final i in job.items)
            if (i.offerItem.kind != ItemKind.dir)
              HistoryItem(
                name: i.offerItem.path,
                size: i.offerItem.size,
                kind: i.offerItem.kind,
                text: i.offerItem.text,
                ok: i.done,
                error: i.error?.wire,
              ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    for (final j in _jobs) {
      j.dispose();
    }
    _changes.close();
    super.dispose();
  }
}
