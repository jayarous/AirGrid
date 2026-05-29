#!/usr/bin/env pwsh
# Fix the corrupted seenByNodes arrays in mesh_service_test.dart

$file = "test/domain/mesh_service_test.dart"
$content = Get-Content $file -Raw

# The corruption pattern: seenByNodes: [import 'dart:convert';...final _remoteNodeId = testNodeId('remote');
# Should be: seenByNodes: [_remoteNodeId],

# Define the corrupted block (this is what got inserted)
$corruptedBlock = @"
import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/transport/packet_fragmenter.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

// Test node ID constants (valid UUIDs)
final _localNodeId = testNodeId('local');
final _remoteNodeId = testNodeId('remote');
"@

# Replace with the correct value
$content = $content -replace [regex]::Escape("        seenByNodes: [$corruptedBlock"), "        seenByNodes: [_remoteNodeId]"
$content = $content -replace [regex]::Escape("          seenByNodes: [$corruptedBlock"), "          seenByNodes: [_remoteNodeId]"

# Write back
$content | Set-Content $file -NoNewline

Write-Host "Fixed corrupted seenByNodes arrays"
