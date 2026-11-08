import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/settings.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// The icon shown while the model works. Five styles, from a quiet static one to a spinner.
class ThinkingIcon extends StatefulWidget {
  const ThinkingIcon({super.key, required this.style, this.size = 35, this.animate = true});

  final ThinkingStyle style;
  final double size;
  final bool animate;

  @override
  State<ThinkingIcon> createState() => _ThinkingIconState();
}

class _ThinkingIconState extends State<ThinkingIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(ThinkingIcon old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_controller.isAnimating) _controller.repeat();
    if (!widget.animate) _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final size = widget.size;
    final brain = ArceIcon(ArceSvg.brain, size: size * .72, color: c.accent);
    // The two styles with dots are a group (the brain and its dots) that is as wide as it is, so
    // it can sit in the middle of whatever holds it; the others are a square of [size].
    final grouped = widget.style == ThinkingStyle.basic || widget.style == ThinkingStyle.dots;
    return SizedBox(
      width: grouped ? null : size,
      height: size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          switch (widget.style) {
            case ThinkingStyle.basic:
              // the dots to the right of the brain, level with its lower half
              return Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                brain,
                SizedBox(width: size * .16),
                Padding(
                  padding: EdgeInsets.only(top: size * .3),
                  child: _Dots(t: t, color: c.faint, active: c.accent),
                ),
              ]);
            case ThinkingStyle.dots:
              // the dots under the brain, in the middle
              return Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                brain,
                const SizedBox(height: 3),
                _Dots(t: t, color: c.faint, active: c.accent, size: 4),
              ]);
            case ThinkingStyle.ring:
              return CustomPaint(
                painter: _RingPainter(turns: t, track: c.surface3, arc: c.accent),
                child: Center(child: brain),
              );
            case ThinkingStyle.pulse:
              final scale = .8 + .5 * t;
              return Stack(alignment: Alignment.center, children: [
                Transform.scale(
                  scale: scale,
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: c.accent.withValues(alpha: .19 * (1 - t))),
                  ),
                ),
                brain,
              ]);
            case ThinkingStyle.rotation:
              return CustomPaint(painter: _SpinnerPainter(turns: t, color: c.accent, track: c.faint));
          }
        },
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.t, required this.color, required this.active, this.size = 5});

  final double t;
  final Color color;
  final Color active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final lit = (t * 3).floor() % 3;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 3; i++) ...[
        if (i > 0) const SizedBox(width: 3),
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: i == lit ? active : color),
        ),
      ],
    ]);
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.turns, required this.track, required this.arc});
  final double turns;
  final Color track;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(1), 0, math.pi * 2, false, paint..color = track);
    canvas.drawArc(rect.deflate(1), turns * math.pi * 2 - math.pi / 2, math.pi / 2, false, paint..color = arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.turns != turns || old.track != track || old.arc != arc;
}

/// Eight dots around a circle whose brightness chases around, like a loading wheel.
class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.turns, required this.color, required this.track});
  final double turns;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 4;
    for (var i = 0; i < 8; i++) {
      final angle = i / 8 * math.pi * 2 - math.pi / 2;
      final phase = ((turns * 8) - i) % 8; // 0 = just lit
      final strength = (1 - (phase / 8)).clamp(0.15, 1.0);
      final dotRadius = 1.6 + 1.6 * strength;
      canvas.drawCircle(
        center + Offset(math.cos(angle), math.sin(angle)) * radius,
        dotRadius,
        Paint()..color = Color.lerp(track, color, strength)!,
      );
    }
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.turns != turns;
}
