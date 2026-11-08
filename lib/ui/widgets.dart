import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/safe_url.dart';
import 'svg_icons.dart';
import 'theme.dart';

/// An SVG icon recolored to [color] (defaults to the surrounding text color).
class ArceIcon extends StatelessWidget {
  const ArceIcon(this.svg, {super.key, this.size = 20, this.color});

  final String svg;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? DefaultTextStyle.of(context).style.color ?? context.c.ink;
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
    );
  }
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: context.c.nav, borderRadius: BorderRadius.circular(size * .32)),
        alignment: Alignment.center,
        child: ArceIcon(ArceSvg.brand, size: size * .7, color: Colors.white),
      );
}

class IconTap extends StatelessWidget {
  const IconTap({super.key, required this.svg, required this.onTap, this.tooltip, this.size = 20, this.color});

  final String svg;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final button = InkResponse(
      onTap: onTap,
      radius: 20,
      borderRadius: BorderRadius.circular(11),
      child: SizedBox(
        width: 36,
        height: 36,
        child: Center(child: ArceIcon(svg, size: size, color: color ?? context.c.muted)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class ArceCard extends StatelessWidget {
  const ArceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = const EdgeInsets.only(bottom: 11),
    this.color,
    this.borderColor,
    this.radius = 16,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;
  final Color? borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: color ?? context.c.surface,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: borderColor ?? context.c.line),
          boxShadow: const [BoxShadow(color: Color(0x06192132), blurRadius: 10, offset: Offset(0, 3))],
        ),
        child: child,
      );
}

class StatusLabel extends StatelessWidget {
  const StatusLabel(this.text, {super.key, this.color, this.background});
  final String text;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(color: background ?? context.c.surface2, borderRadius: BorderRadius.circular(30)),
        child: Text(text, style: ts(context, 9, weight: FontWeight.w700, color: color ?? context.c.muted)),
      );
}

class SoftButton extends StatelessWidget {
  const SoftButton({super.key, required this.label, this.svg, required this.onTap, this.height = 36});
  final String label;
  final String? svg;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) => _ButtonShell(
        onTap: onTap,
        height: height,
        background: context.c.surface,
        border: context.c.line,
        foreground: context.c.ink,
        label: label,
        svg: svg,
      );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.svg, required this.onTap, this.height = 36});
  final String label;
  final String? svg;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) => _ButtonShell(
        onTap: onTap,
        height: height,
        background: context.c.accent,
        foreground: Colors.white,
        label: label,
        svg: svg,
      );
}

class _ButtonShell extends StatelessWidget {
  const _ButtonShell({
    required this.onTap,
    required this.height,
    required this.background,
    required this.foreground,
    required this.label,
    this.border,
    this.svg,
  });

  final VoidCallback? onTap;
  final double height;
  final Color background;
  final Color foreground;
  final Color? border;
  final String label;
  final String? svg;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: border == null ? BorderSide.none : BorderSide(color: border!),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (svg != null) ...[ArceIcon(svg!, size: 15, color: foreground), const SizedBox(width: 6)],
                Flexible(
                  child: Text(label, style: ts(context, 10.5, weight: FontWeight.w700, color: foreground), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The compact on/off switch of the interface (38x22).
class ArceSwitch extends StatelessWidget {
  const ArceSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      toggled: value,
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 38,
          height: 22,
          padding: const EdgeInsets.all(3),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(color: value ? c.accent : c.surface3, borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 16,
            height: 16,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Color(0x26000000), blurRadius: 3, offset: Offset(0, 1))],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.last = false,
  });

  final String icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final bool last;

  /// Above this text size the control is put under the text, not beside it: a switch, a button or a value
  /// does not shrink with the text, and beside a title that is two or three lines long it left no room.
  static const stackAbove = 1.15;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final stacked = MediaQuery.textScalerOf(context).scale(10) / 10 > stackAbove;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: ts(context, 11, weight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(subtitle, style: ts(context, 9, color: c.muted, height: 1.45)),
      ],
    );
    final badge = Container(
      width: 31,
      height: 31,
      decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(10)),
      alignment: Alignment.center,
      child: ArceIcon(icon, size: 16, color: c.accent),
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 1),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.line))),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [badge, const SizedBox(width: 10), Expanded(child: text)]),
                const SizedBox(height: 6),
                // a control that is wider than the row (a long value at a large text size) shrinks to fit
                Align(alignment: Alignment.centerRight, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: trailing)),
              ],
            )
          : Row(
              children: [
                badge,
                const SizedBox(width: 10),
                Expanded(child: text),
                const SizedBox(width: 8),
                trailing,
              ],
            ),
    );
  }
}

class ValuePill extends StatelessWidget {
  const ValuePill(this.text, {super.key, this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: c.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(text, style: ts(context, 10, weight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(3, 17, 0, 8),
        child: Text(text, style: ts(context, 10, weight: FontWeight.w700, color: context.c.muted, letterSpacing: .8)),
      );
}

class PageHeading extends StatelessWidget {
  const PageHeading(this.title, this.subtitle, {super.key});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 1, 0, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: ts(context, 20, weight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(subtitle, style: ts(context, 11, color: context.c.muted, height: 1.65)),
          ],
        ),
      );
}

class InfoBox extends StatelessWidget {
  const InfoBox(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: context.c.surface2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.c.line),
        ),
        child: Text(text, style: ts(context, 10, color: context.c.muted, height: 1.65)),
      );
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: .18), spreadRadius: 3)],
        ),
      );
}

/// Centered content column: pages stay readable on wide windows.
class PageColumn extends StatelessWidget {
  const PageColumn({super.key, required this.child, this.maxWidth = 760});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
      );
}

String two(int n) => n.toString().padLeft(2, '0');

String formatTime(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

String formatDate(DateTime t) => '${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';

/// Bottom padding for the content of a bottom sheet: above the keyboard, or, with no keyboard, above
/// the system navigation bar (the three buttons or the gesture bar), so the last buttons stay reachable.
double sheetBottomPadding(BuildContext context) {
  final media = MediaQuery.of(context);
  final inset = media.viewInsets.bottom > media.viewPadding.bottom ? media.viewInsets.bottom : media.viewPadding.bottom;
  return inset + 16;
}

/// Under an address field: a warning when a key or token sent there would travel unencrypted (`http://`
/// to a host outside the house). Nothing when the address is fine or empty.
class ClearTextWarning extends StatelessWidget {
  const ClearTextWarning({super.key, required this.url, required this.what});

  final String url;

  /// What would be sent ("APIキー", "トークン").
  final String what;

  @override
  Widget build(BuildContext context) {
    if (!sendsSecretsInTheClear(url)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        'このアドレスは暗号化されません（http）。$whatが、途中の通信（カフェの Wi-Fi など）から読まれるおそれがあります。自宅の中のサーバー以外は https にしてください。',
        key: const ValueKey('clear-text-warning'),
        style: ts(context, 10, color: context.c.amber, height: 1.5),
      ),
    );
  }
}
