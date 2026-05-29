import 'package:uuid/uuid.dart';

/// The reason a user submitted a safety report.
enum ReportReason {
  spam,
  harassment,
  inappropriateContent,
  impersonation,
  other;

  String get label {
    switch (this) {
      case ReportReason.spam:
        return 'Spam';
      case ReportReason.harassment:
        return 'Harassment';
      case ReportReason.inappropriateContent:
        return 'Inappropriate content';
      case ReportReason.impersonation:
        return 'Impersonation';
      case ReportReason.other:
        return 'Other';
    }
  }
}

/// An immutable local safety report created by the user.
///
/// Reports are stored locally only and can be exported as plain text for
/// manual escalation. They are never transmitted to any server.
class LocalReport {
  final String reportId;
  final DateTime timestamp;
  final String reporterNodeId;
  final String reportedNodeId;
  final String reportedDisplayName;

  /// Non-null when the report targets a specific chat message.
  final String? messageId;

  /// Snapshot of the offending message content at report time.
  final String? messageContentSnapshot;

  final ReportReason reason;
  final String? notes;

  LocalReport({
    String? reportId,
    required this.timestamp,
    required this.reporterNodeId,
    required this.reportedNodeId,
    required this.reportedDisplayName,
    this.messageId,
    this.messageContentSnapshot,
    required this.reason,
    this.notes,
  }) : reportId = reportId ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
    'reportId': reportId,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'reporterNodeId': reporterNodeId,
    'reportedNodeId': reportedNodeId,
    'reportedDisplayName': reportedDisplayName,
    if (messageId != null) 'messageId': messageId,
    if (messageContentSnapshot != null)
      'messageContentSnapshot': messageContentSnapshot,
    'reason': reason.name,
    if (notes != null) 'notes': notes,
  };

  factory LocalReport.fromJson(Map<String, dynamic> json) => LocalReport(
    reportId: json['reportId'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    reporterNodeId: json['reporterNodeId'] as String,
    reportedNodeId: json['reportedNodeId'] as String,
    reportedDisplayName: json['reportedDisplayName'] as String,
    messageId: json['messageId'] as String?,
    messageContentSnapshot: json['messageContentSnapshot'] as String?,
    reason: ReportReason.values.firstWhere(
      (e) => e.name == (json['reason'] as String? ?? ''),
      orElse: () => ReportReason.other,
    ),
    notes: json['notes'] as String?,
  );

  /// Human-readable representation suitable for export/sharing.
  String toReadableText() {
    final buf = StringBuffer();
    buf.writeln('=== AirGrid Safety Report ===');
    buf.writeln('Report ID:     $reportId');
    buf.writeln('Date/Time:     ${timestamp.toIso8601String()}');
    buf.writeln('Reported user: $reportedDisplayName ($reportedNodeId)');
    buf.writeln('Reason:        ${reason.label}');
    if (messageId != null) {
      buf.writeln('Message ID:    $messageId');
    }
    if (messageContentSnapshot != null && messageContentSnapshot!.isNotEmpty) {
      buf.writeln('Message:       $messageContentSnapshot');
    }
    if (notes != null && notes!.isNotEmpty) {
      buf.writeln('Notes:         $notes');
    }
    buf.writeln('Reporter:      $reporterNodeId');
    return buf.toString();
  }
}
