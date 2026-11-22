import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Emoji grid with categories and search. Returns the chosen emoji,
/// '' to remove the icon, or null when dismissed.
Future<String?> showIconPicker(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      final colors = context.noteColors;
      final surface = Theme.of(context).colorScheme.surface;
      return Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 400,
          height: 440,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Text('아이콘', style: TextStyle(color: colors.text)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context, ''),
                      child: const Text('제거'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: EmojiPicker(
                  onEmojiSelected: (_, emoji) =>
                      Navigator.pop(context, emoji.emoji),
                  config: Config(
                    emojiViewConfig: EmojiViewConfig(
                      columns: 9,
                      emojiSizeMax: 26,
                      backgroundColor: surface,
                    ),
                    categoryViewConfig: CategoryViewConfig(
                      initCategory: Category.SMILEYS,
                      backgroundColor: surface,
                      indicatorColor: const Color(0xFF2383E2),
                      iconColorSelected: const Color(0xFF2383E2),
                    ),
                    bottomActionBarConfig: BottomActionBarConfig(
                      backgroundColor: surface,
                      buttonColor: surface,
                      buttonIconColor: colors.textMuted,
                      showBackspaceButton: false,
                    ),
                    searchViewConfig: SearchViewConfig(
                      backgroundColor: surface,
                      hintText: '검색 (영어)',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
