import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

/// Files dragged in from the file manager (or a photo dragged out of an
/// album here). Uses the same drag-and-drop library as dragging photos out
/// to the desktop: two libraries can't both own the window's drop target
/// (the second takes it from the first), see ISSUES #063.
class FileDropTarget extends StatelessWidget {
  const FileDropTarget({
    super.key,
    required this.onDragDone,
    this.onDragEntered,
    this.onDragExited,
    required this.child,
  });

  /// Local paths of the dropped files and where (in this widget).
  final void Function(List<String> paths, Offset localPosition) onDragDone;
  final VoidCallback? onDragEntered;
  final VoidCallback? onDragExited;
  final Widget child;

  @override
  Widget build(BuildContext context) => DropRegion(
    formats: const [Formats.fileUri],
    hitTestBehavior: HitTestBehavior.translucent,
    onDropOver: (event) =>
        event.session.allowedOperations.contains(DropOperation.copy)
        ? DropOperation.copy
        : DropOperation.none,
    onDropEnter: (_) => onDragEntered?.call(),
    onDropLeave: (_) => onDragExited?.call(),
    onPerformDrop: (event) async {
      final paths = <String>[];
      for (final item in event.session.items) {
        final reader = item.dataReader;
        if (reader == null || !reader.canProvide(Formats.fileUri)) continue;
        final done = Completer<String?>();
        reader.getValue<Uri>(
          Formats.fileUri,
          (uri) => done.complete(uri?.toFilePath()),
          onError: (_) => done.complete(null),
        );
        final path = await done.future;
        if (path != null) paths.add(path);
      }
      onDragExited?.call();
      if (paths.isNotEmpty) onDragDone(paths, event.position.local);
    },
    child: child,
  );
}
