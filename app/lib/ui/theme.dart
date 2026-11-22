import 'package:flutter/material.dart';

/// Notion-like neutral palette.
class NoteColors extends ThemeExtension<NoteColors> {
  const NoteColors({
    required this.sidebar,
    required this.hover,
    required this.text,
    required this.textMuted,
    required this.divider,
  });

  final Color sidebar;
  final Color hover;
  final Color text;
  final Color textMuted;
  final Color divider;

  static const light = NoteColors(
    sidebar: Color(0xFFF7F7F5),
    hover: Color(0xFFEBEBEA),
    text: Color(0xFF37352F),
    textMuted: Color(0xFF91918E),
    divider: Color(0xFFE9E9E7),
  );

  static const dark = NoteColors(
    sidebar: Color(0xFF202020),
    hover: Color(0xFF2C2C2C),
    text: Color(0xFFD4D4D4),
    textMuted: Color(0xFF7F7F7F),
    divider: Color(0xFF2F2F2F),
  );

  @override
  NoteColors copyWith() => this;

  @override
  NoteColors lerp(NoteColors? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

extension NoteColorsX on BuildContext {
  NoteColors get noteColors => Theme.of(this).extension<NoteColors>()!;
}

ThemeData buildTheme(Brightness brightness) {
  final colors = brightness == Brightness.light
      ? NoteColors.light
      : NoteColors.dark;
  final base = ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF2383E2),
      brightness: brightness,
      surface: brightness == Brightness.light
          ? Colors.white
          : const Color(0xFF191919),
    ),
    scaffoldBackgroundColor: brightness == Brightness.light
        ? Colors.white
        : const Color(0xFF191919),
    dividerColor: colors.divider,
    extensions: [colors],
  );
  // Menus and dialogs like Notion's: plain surface (no Material tint),
  // a thin border, soft shadow, compact rows.
  final panel = brightness == Brightness.light
      ? Colors.white
      : const Color(0xFF252525);
  final panelShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(10),
    side: BorderSide(color: colors.divider),
  );
  final menuText = TextStyle(fontSize: 14, color: colors.text);
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: colors.text,
      displayColor: colors.text,
    ),
    iconTheme: IconThemeData(color: colors.textMuted, size: 18),
    popupMenuTheme: PopupMenuThemeData(
      color: panel,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: panelShape,
      textStyle: menuText,
      labelTextStyle: WidgetStatePropertyAll(menuText),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(panelShape),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: panel,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: colors.text,
      ),
    ),
    dividerTheme: DividerThemeData(color: colors.divider, space: 1),
  );
}
