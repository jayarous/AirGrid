import 'dart:async';
import 'dart:io';

import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';

class AutomaticImageRetryConfig {
  const AutomaticImageRetryConfig({
    required this.ackTimeout,
    required this.backoff,
    required this.startupGrace,
    required this.maxAttempts,
  });

  final Duration ackTimeout;
  final Duration backoff;
  final Duration startupGrace;
  final int maxAttempts;
}

class _AutomaticImageRetryState {
  _AutomaticImageRetryState({
    this.attempts = 0,
    this.inFlight = false,
    this.timer,
  });

  int attempts;
  bool inFlight;
  Timer? timer;

  void cancel() {
    timer?.cancel();
    timer = null;
    inFlight = false;
  }
}

class AutomaticImageRetryController {
  AutomaticImageRetryController({
    required bool Function() isDisposed,
    required AirGridMessage? Function(String messageId) messageById,
    required void Function(String messageId, DeliveryStatus status)
    forceStatusUpdate,
    required Future<bool> Function(AirGridMessage message) retryAttempt,
    required AutomaticImageRetryConfig Function() config,
  }) : _isDisposed = isDisposed,
       _messageById = messageById,
       _forceStatusUpdate = forceStatusUpdate,
       _retryAttempt = retryAttempt,
       _config = config;

  final bool Function() _isDisposed;
  final AirGridMessage? Function(String messageId) _messageById;
  final void Function(String messageId, DeliveryStatus status) _forceStatusUpdate;
  final Future<bool> Function(AirGridMessage message) _retryAttempt;
  final AutomaticImageRetryConfig Function() _config;

  final Map<String, _AutomaticImageRetryState> _retries = {};

  void handleStatus(String messageId, DeliveryStatus newStatus) {
    if (newStatus == DeliveryStatus.delivered ||
        newStatus == DeliveryStatus.read ||
        newStatus == DeliveryStatus.failed) {
      cancel(messageId);
      return;
    }

    if (newStatus != DeliveryStatus.sent) {
      return;
    }

    final message = _messageById(messageId);
    if (message == null) {
      return;
    }

    restoreWatch(message);
  }

  void restoreWatches(Iterable<AirGridMessage> messages) {
    for (final message in messages) {
      if (_canRestoreWatch(message)) {
        _schedule(message.id, resetAttempts: true);
      }
    }
  }

  void restoreWatch(AirGridMessage message) {
    if (_isCandidate(message)) {
      _schedule(message.id);
      return;
    }

    if (message.deliveryStatus == DeliveryStatus.delivered ||
        message.deliveryStatus == DeliveryStatus.read ||
        message.deliveryStatus == DeliveryStatus.failed) {
      cancel(message.id);
    }
  }

  void cancel(String messageId) {
    final retryState = _retries.remove(messageId);
    retryState?.cancel();
  }

  void cancelAll() {
    for (final retryState in _retries.values) {
      retryState.cancel();
    }
    _retries.clear();
  }

  bool _isCandidate(AirGridMessage message) {
    return message.isLocal &&
        message.conversationType == 'private' &&
        message.messageKind == 'image' &&
        message.peerNodeId != null &&
        (message.deliveryStatus == DeliveryStatus.pending ||
            message.deliveryStatus == DeliveryStatus.sent);
  }

  bool _canRestoreWatch(AirGridMessage message) {
    if (!_isCandidate(message)) {
      return false;
    }

    final age = DateTime.now().difference(message.timestamp);
    if (age > _config().startupGrace) {
      return false;
    }

    return _hasRecoverablePayload(message);
  }

  bool _hasRecoverablePayload(AirGridMessage message) {
    final tempPath = message.mediaTempPath;
    if (tempPath != null && tempPath.isNotEmpty && File(tempPath).existsSync()) {
      return true;
    }

    final preview = message.mediaPreviewBase64;
    return preview != null && preview.isNotEmpty;
  }

  void _schedule(
    String messageId, {
    bool resetAttempts = false,
    Duration? delay,
  }) {
    if (_isDisposed()) return;
    final message = _messageById(messageId);
    if (message == null || !_isCandidate(message)) {
      cancel(messageId);
      return;
    }

    final retryState = _retries.putIfAbsent(messageId, _AutomaticImageRetryState.new);
    if (resetAttempts) {
      retryState.attempts = 0;
    }
    retryState.cancel();
    retryState.timer = Timer(
      delay ?? _config().ackTimeout,
      () {
        if (_isDisposed()) return;
        unawaited(_handleTimeout(messageId));
      },
    );
  }

  Future<void> _handleTimeout(String messageId) async {
    if (_isDisposed()) return;
    try {
      final retryState = _retries[messageId];
      if (retryState == null || retryState.inFlight) {
        return;
      }

      final message = _messageById(messageId);
      if (message == null || !_isCandidate(message)) {
        cancel(messageId);
        return;
      }

      if (!_hasRecoverablePayload(message)) {
        cancel(messageId);
        _forceStatusUpdate(messageId, DeliveryStatus.failed);
        return;
      }

      final config = _config();
      if (retryState.attempts >= config.maxAttempts) {
        cancel(messageId);
        _forceStatusUpdate(messageId, DeliveryStatus.failed);
        return;
      }

      retryState.inFlight = true;
      retryState.attempts++;

      final success = await _retryAttempt(message);

      if (_isDisposed()) return;

      retryState.inFlight = false;
      final refreshed = _messageById(messageId);
      if (refreshed == null) {
        cancel(messageId);
        return;
      }

      if (refreshed.deliveryStatus == DeliveryStatus.delivered ||
          refreshed.deliveryStatus == DeliveryStatus.read ||
          refreshed.deliveryStatus == DeliveryStatus.failed) {
        cancel(messageId);
        return;
      }

      if (success) {
        _schedule(messageId, delay: config.ackTimeout);
        return;
      }

      if (retryState.attempts >= config.maxAttempts ||
          !_hasRecoverablePayload(refreshed)) {
        cancel(messageId);
        _forceStatusUpdate(messageId, DeliveryStatus.failed);
        return;
      }

      _schedule(messageId, delay: config.backoff);
    } catch (_) {
      if (_isDisposed()) return;
      cancel(messageId);
      _forceStatusUpdate(messageId, DeliveryStatus.failed);
    }
  }
}
