import 'dart:io';

void main() {
  final file = File('airgrid/lib/features/home/home_screen.dart');
  var code = file.readAsStringSync();

  code = code.replaceAll(
    "floatingActionButton: Padding(\r\n        padding: const EdgeInsets.only(bottom: 8.0, right: 6.0),\r\n        child: FloatingActionButton.extended(\r\n          elevation: 6,\r\n          shape: RoundedRectangleBorder(\r\n            borderRadius: BorderRadius.circular(16),\r\n          ),\r\n          onPressed: _openPublicChat,\r\n          icon: const Icon(Icons.forum),\r\n          label: const Text('Public chat'),\r\n        ),\r\n      )",
    "floatingActionButton: FloatingActionButton.extended(\r\n        elevation: 4,\r\n        hoverElevation: 6,\r\n        focusElevation: 6,\r\n        highlightElevation: 8,\r\n        shape: RoundedRectangleBorder(\r\n          borderRadius: BorderRadius.circular(20),\r\n        ),\r\n        onPressed: _openPublicChat,\r\n        icon: const Icon(Icons.forum_rounded),\r\n        label: const Text('Public Chat', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2)),\r\n      )"
  );

  code = code.replaceAll(
    "floatingActionButton: Padding(\n        padding: const EdgeInsets.only(bottom: 8.0, right: 6.0),\n        child: FloatingActionButton.extended(\n          elevation: 6,\n          shape: RoundedRectangleBorder(\n            borderRadius: BorderRadius.circular(16),\n          ),\n          onPressed: _openPublicChat,\n          icon: const Icon(Icons.forum),\n          label: const Text('Public chat'),\n        ),\n      )",
    "floatingActionButton: FloatingActionButton.extended(\n        elevation: 4,\n        hoverElevation: 6,\n        focusElevation: 6,\n        highlightElevation: 8,\n        shape: RoundedRectangleBorder(\n          borderRadius: BorderRadius.circular(20),\n        ),\n        onPressed: _openPublicChat,\n        icon: const Icon(Icons.forum_rounded),\n        label: const Text('Public Chat', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2)),\n      )"
  );

  file.writeAsStringSync(code);
}
