import 'package:emoji_regex/emoji_regex.dart';
import 'package:fl_clash/enum/enum.dart' show FontFamily;
import 'package:flutter/material.dart';

/// Xboard-only aligned text. Keep Twemoji confined to emoji spans so ordinary
/// digits retain their text font. Upstream EmojiText remains unmodified.
class XbEmojiText extends StatelessWidget {
  const XbEmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    // RichText does not inherit DefaultTextStyle as Text does. Resolve the
    // surrounding platform font first, including when the caller omits style.
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final spans = <TextSpan>[];
    var last = 0;
    for (final match in emojiRegex().allMatches(text)) {
      if (match.start > last) {
        spans.add(
          TextSpan(
            text: text.substring(last, match.start),
            style: effectiveStyle,
          ),
        );
      }
      spans.add(
        TextSpan(
          text: match.group(0),
          style: effectiveStyle.copyWith(fontFamily: FontFamily.twEmoji.value),
        ),
      );
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: effectiveStyle));
    }
    return RichText(
      textScaler: MediaQuery.of(context).textScaler,
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
      textAlign: textAlign ?? TextAlign.start,
      text: TextSpan(style: effectiveStyle, children: spans),
    );
  }
}
