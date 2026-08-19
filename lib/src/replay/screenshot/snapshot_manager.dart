import 'package:flutter/cupertino.dart';
import 'package:posthog/src/replay/screenshot/screenshot_capturer.dart';

class SnapshotManager {
  // Expando is the equivalent of weakref
  Expando<ViewTreeSnapshotStatus> _snapshotStatuses = Expando();

  ViewTreeSnapshotStatus getStatus(RenderObject renderObject) {
    return _snapshotStatuses[renderObject] ??= ViewTreeSnapshotStatus(false);
  }

  void clear() {
    _snapshotStatuses = Expando();
  }
}
