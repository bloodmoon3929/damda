import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/find_replace_menu/find_replace_widget.dart';
import 'package:flutter/material.dart';

abstract class FindReplaceService {
  void show();

  void dismiss();
}

OverlayEntry? _findReplaceMenuEntry;

class FindReplaceMenu implements FindReplaceService {
  FindReplaceMenu({
    required this.context,
    required this.editorState,
    required this.showReplaceMenu,
    this.localizations,
    required this.style,
    this.showRegexButton = true,
    this.showCaseSensitiveButton = true,
  });

  final BuildContext context;
  final EditorState editorState;
  final bool showReplaceMenu;
  final FindReplaceLocalizations? localizations;
  final FindReplaceStyle style;
  final bool showRegexButton;
  final bool showCaseSensitiveButton;

  final double topOffset = 52;
  final double rightOffset = 40;

  bool _selectionUpdateByInner = false;

  @override
  void dismiss() {
    if (_findReplaceMenuEntry != null) {
      editorState.service.keyboardService?.enable();
      editorState.service.scrollService?.enable();
    }

    editorState.onDispose.removeListener(dismiss);

    _findReplaceMenuEntry?.remove();
    _findReplaceMenuEntry = null;

    final isSelectionDisposed =
        editorState.service.selectionServiceKey.currentState == null;
    if (!isSelectionDisposed) {
      final selectionService = editorState.service.selectionService;
      selectionService.currentSelection.removeListener(_onSelectionChange);
    }
  }

  @override
  void show() {
    if (_findReplaceMenuEntry != null) {
      dismiss();
    }

    // PATCH(notes #058): no "is there a cursor" check — the page menu opens
    // find with nothing selected (always on a phone).

    editorState.onDispose.addListener(dismiss);

    _findReplaceMenuEntry = OverlayEntry(
      builder: (context) {
        // PATCH(notes #058): on a phone the bar is wider than the screen;
        // keep it on screen (below the status bar) and shrink it to fit.
        final screen = MediaQuery.sizeOf(context).width;
        final narrow = screen < 600;
        return Positioned(
          top: narrow ? MediaQuery.paddingOf(context).top + 4 : topOffset,
          right: narrow ? 8 : rightOffset,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: screen - 16),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child:
                  style.findMenuBuilder?.call(
                    context,
                    editorState,
                    localizations,
                    style,
                    showReplaceMenu,
                    dismiss,
                  ) ??
                  Material(
                    borderRadius: BorderRadius.circular(8.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: editorState.editorStyle.selectionColor,
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 5,
                            spreadRadius: 1,
                            color: Colors.black.withValues(alpha: 0.1),
                          ),
                        ],
                        borderRadius: BorderRadius.circular(6.0),
                      ),
                      child: FindAndReplaceMenuWidget(
                        onDismiss: dismiss,
                        editorState: editorState,
                        showReplaceMenu: showReplaceMenu,
                        localizations: localizations,
                        style: style,
                        showRegexButton: showRegexButton,
                        showCaseSensitiveButton: showCaseSensitiveButton,
                      ),
                    ),
                  ),
            ),
          ),
        );
      },
    );

    Overlay.of(context, rootOverlay: true).insert(_findReplaceMenuEntry!);
  }

  void _onSelectionChange() {
    // workaround: SelectionService has been released after hot reload.
    final isSelectionDisposed =
        editorState.service.selectionServiceKey.currentState == null;
    if (!isSelectionDisposed) {
      final selectionService = editorState.service.selectionService;
      if (selectionService.currentSelection.value == null) {
        return;
      }
    }

    if (_selectionUpdateByInner) {
      _selectionUpdateByInner = false;

      return;
    }

    dismiss();
  }
}
