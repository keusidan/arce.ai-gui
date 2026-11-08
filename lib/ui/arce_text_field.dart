import 'package:flutter/material.dart';

/// The one text input of the app. The chat box, the settings, the editors and the searches are all
/// built from it, so they take the same keyboard input: suggestions, autocorrect and the keyboard's
/// learning are on. (The editors used to turn them off, so a Japanese keyboard showed no conversion
/// candidates there.)
///
/// A secret (an API key, a token: [obscure]) is the one exception. Hidden text is not shown to the
/// keyboard's dictionary, so it is not learned or suggested back.
class ArceTextField extends StatelessWidget {
  const ArceTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.minLines,
    this.maxLines = 1,
    this.maxLength,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.style,
    this.decoration,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? minLines;
  final int? maxLines;
  final int? maxLength;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextStyle? style;
  final InputDecoration? decoration;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      minLines: obscure ? 1 : minLines,
      maxLines: obscure ? 1 : maxLines,
      maxLength: maxLength,
      autofocus: autofocus,
      autocorrect: !obscure,
      enableSuggestions: !obscure,
      enableIMEPersonalizedLearning: !obscure,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: style,
      decoration: decoration,
    );
  }
}
