import 'dart:convert';

/// Result of a validation operation.
class ValidationResult {
  final bool isValid;
  final String? sanitizedValue;
  final String? error;

  const ValidationResult.ok(this.sanitizedValue) : isValid = true, error = null;

  const ValidationResult.rejected(this.error)
    : isValid = false,
      sanitizedValue = null;
}

/// Validates and sanitizes display names for local users and remote peers.
///
/// **Policy for local input (onboarding/settings)**:
/// - Trim whitespace
/// - Collapse multiple consecutive whitespace to single space
/// - Reject if empty after trimming
/// - Reject if contains control characters (except normal whitespace)
/// - Reject if length > 32 characters after sanitization
///
/// **Policy for remote input (mesh packets)**:
/// - Apply same rules but **reject** instead of sanitize
/// - Log and drop malformed peer names — don't silently fix hostile input
class DisplayNameValidator {
  DisplayNameValidator._();

  static const int maxLength = 32;

  /// Validates and sanitizes a display name for **local user input**.
  ///
  /// Returns [ValidationResult.ok] with sanitized value if valid,
  /// or [ValidationResult.rejected] with error message if invalid.
  static ValidationResult validateLocal(String input) {
    // Check for control characters BEFORE collapsing whitespace
    // (so we reject newlines, nulls, etc. before they get normalized)
    if (_containsControlChars(input)) {
      return const ValidationResult.rejected(
        'Display name contains invalid characters',
      );
    }

    // Trim and collapse whitespace (spaces and tabs)
    final trimmed = input.trim();
    final collapsed = trimmed.replaceAll(RegExp(r'[ \t]+'), ' ');

    // Reject empty
    if (collapsed.isEmpty) {
      return const ValidationResult.rejected('Display name cannot be empty');
    }

    // Reject if too long
    if (collapsed.length > maxLength) {
      return ValidationResult.rejected(
        'Display name cannot exceed $maxLength characters',
      );
    }

    return ValidationResult.ok(collapsed);
  }

  /// Validates a display name from a **remote peer**.
  ///
  /// Does NOT sanitize — rejects any malformed input.
  /// Returns [ValidationResult.ok] if valid as-is, or rejected with reason.
  static ValidationResult validateRemote(String input) {
    // Remote names must not have leading/trailing whitespace
    if (input != input.trim()) {
      return const ValidationResult.rejected(
        'Remote display name has leading/trailing whitespace',
      );
    }

    // Must not have consecutive whitespace
    if (input.contains(RegExp(r'\s{2,}'))) {
      return const ValidationResult.rejected(
        'Remote display name has consecutive whitespace',
      );
    }

    // Reject empty
    if (input.isEmpty) {
      return const ValidationResult.rejected('Remote display name is empty');
    }

    // Reject control characters
    if (_containsControlChars(input)) {
      return const ValidationResult.rejected(
        'Remote display name contains control characters',
      );
    }

    // Reject if too long
    if (input.length > maxLength) {
      return ValidationResult.rejected(
        'Remote display name exceeds $maxLength characters',
      );
    }

    return ValidationResult.ok(input);
  }

  /// Like [validateRemote], but treats an **absent** name as valid.
  ///
  /// Phase 1 of metadata minimisation. `senderName` is cleartext on every
  /// packet, including encrypted private ones, and those are broadcast to
  /// every connected endpoint for crowd relay — so today every peer in range
  /// learns who is talking to whom.
  ///
  /// Senders cannot simply stop including the name: [validateRemote] rejects
  /// empty, so any node running a released build would drop such packets at
  /// the validation gate and private messaging would break across versions.
  /// The rollout is therefore staged:
  ///
  ///   Phase 1 (this) — receivers accept a missing name and fall back to the
  ///                    known-contact record for display.
  ///   Phase 2 (later, once phase 1 is widely deployed) — senders omit the
  ///                    name on private packets.
  ///
  /// A non-empty name is still validated exactly as strictly as before: this
  /// relaxes *absence*, not malformed input.
  static ValidationResult validateRemoteOptional(String input) {
    if (input.isEmpty) return const ValidationResult.ok('');
    return validateRemote(input);
  }

  /// Returns true if [s] contains control characters except normal whitespace.
  ///
  /// Allows: space (0x20), tab (0x09), but NOT newlines or other control chars.
  static bool _containsControlChars(String s) {
    for (var i = 0; i < s.length; i++) {
      final code = s.codeUnitAt(i);
      // Control chars are 0x00-0x1F and 0x7F-0x9F
      if ((code < 0x20 || (code >= 0x7F && code <= 0x9F)) &&
          code != 0x20 && // space
          code != 0x09) {
        // tab
        return true;
      }
    }
    return false;
  }
}

/// Validates message content for local sends and remote receives.
///
/// **Policy for local input (send boundary)**:
/// - Trim whitespace at send time
/// - Reject if empty after trim
/// - Reject control chars except newline (0x0A), carriage return (0x0D), tab (0x09)
/// - Reject if UTF-8 encoded byte length exceeds threshold (8 KB safe limit)
///
/// **Policy for remote input (inbound packets)**:
/// - Same rules but **reject** instead of sanitize
/// - Log and drop oversized or malformed content
class MessageContentValidator {
  MessageContentValidator._();

  /// Maximum content length in UTF-8 encoded bytes.
  /// Set to 8 KB as a safe limit (well below 16 KB packet size).
  static const int maxEncodedBytes = 8 * 1024;

  /// Validates and sanitizes message content for **local send**.
  ///
  /// Returns [ValidationResult.ok] with trimmed content if valid,
  /// or [ValidationResult.rejected] with error message if invalid.
  static ValidationResult validateLocal(String input) {
    // Trim at send time
    final trimmed = input.trim();

    // Reject empty
    if (trimmed.isEmpty) {
      return const ValidationResult.rejected('Message cannot be empty');
    }

    // Reject disallowed control characters
    if (_containsDisallowedControlChars(trimmed)) {
      return const ValidationResult.rejected(
        'Message contains invalid control characters',
      );
    }

    // Check encoded byte length
    final encoded = utf8.encode(trimmed);
    if (encoded.length > maxEncodedBytes) {
      return ValidationResult.rejected(
        'Message exceeds maximum size of $maxEncodedBytes bytes '
        '(${encoded.length} bytes)',
      );
    }

    return ValidationResult.ok(trimmed);
  }

  /// Validates message content from a **remote peer**.
  ///
  /// Does NOT sanitize — rejects any malformed input.
  static ValidationResult validateRemote(String input) {
    // Remote content must not have leading/trailing whitespace
    // (sender should have trimmed it)
    if (input != input.trim()) {
      return const ValidationResult.rejected(
        'Remote message has untrimmed whitespace',
      );
    }

    // Reject empty
    if (input.isEmpty) {
      return const ValidationResult.rejected('Remote message is empty');
    }

    // Reject disallowed control characters
    if (_containsDisallowedControlChars(input)) {
      return const ValidationResult.rejected(
        'Remote message contains invalid control characters',
      );
    }

    // Check encoded byte length
    final encoded = utf8.encode(input);
    if (encoded.length > maxEncodedBytes) {
      return ValidationResult.rejected(
        'Remote message exceeds maximum size of $maxEncodedBytes bytes '
        '(${encoded.length} bytes)',
      );
    }

    return ValidationResult.ok(input);
  }

  /// Returns true if [s] contains control chars other than newline, CR, and tab.
  ///
  /// Allows: LF (0x0A), CR (0x0D), TAB (0x09).
  /// Rejects: All other control chars (0x00-0x1F except allowed, and 0x7F-0x9F).
  static bool _containsDisallowedControlChars(String s) {
    for (var i = 0; i < s.length; i++) {
      final code = s.codeUnitAt(i);
      // Control chars are 0x00-0x1F and 0x7F-0x9F
      if ((code < 0x20 || (code >= 0x7F && code <= 0x9F)) &&
          code != 0x0A && // LF
          code != 0x0D && // CR
          code != 0x09) {
        // TAB
        return true;
      }
    }
    return false;
  }
}

/// Validates node IDs (UUID v4 format).
///
/// **Policy**:
/// - Must be a valid UUID v4 format: 8-4-4-4-12 hex digits with hyphens
/// - Lowercase preferred but accepts uppercase
/// - For remote peers: strict validation, reject malformed IDs
class NodeIdValidator {
  NodeIdValidator._();

  /// UUID v4 regex: 8-4-4-4-12 hex digits with hyphens.
  /// Accepts both lowercase and uppercase hex.
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// Validates a node ID (UUID v4).
  ///
  /// Returns [ValidationResult.ok] if valid, or rejected with reason.
  static ValidationResult validate(String input) {
    if (input.isEmpty) {
      return const ValidationResult.rejected('Node ID is empty');
    }

    if (!_uuidPattern.hasMatch(input)) {
      return const ValidationResult.rejected(
        'Node ID is not a valid UUID v4 format',
      );
    }

    return ValidationResult.ok(input);
  }

  /// Returns true if [input] is a valid UUID v4.
  static bool isValid(String input) {
    return _uuidPattern.hasMatch(input);
  }
}
