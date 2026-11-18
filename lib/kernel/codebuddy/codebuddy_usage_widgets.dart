import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'codebuddy_account_models.dart';

/// Circular credit/status ring for CodeBuddy accounts in the composer toolbar
/// and account management cards.
class CodeBuddyQuotaRing extends StatelessWidget {
  const CodeBuddyQuotaRing({
    super.key,
    required this.fraction,
    this.size = 18,
    this.strokeWidth = 2.1,
    this.trackColor,
    this.accentColor,
  });

  final double fraction;
  final double size;
  final double strokeWidth;
  final Color? trackColor;
  final Color? accentColor;

  static Color colorForPercentage(int pct) => pct >= 25
      ? const Color(0xFF0EA5E9)
      : pct >= 10
      ? const Color(0xFFD98B1C)
      : const Color(0xFFDC3E3E);

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.clamp(0.0, 1.0);
    final pct = (clamped * 100).round();
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _CodeBuddyRingPainter(
          fraction: clamped,
          strokeWidth: strokeWidth,
          activeColor: accentColor ?? colorForPercentage(pct),
          trackColor:
              trackColor ??
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.16),
        ),
      ),
    );
  }
}

class _CodeBuddyRingPainter extends CustomPainter {
  const _CodeBuddyRingPainter({
    required this.fraction,
    required this.strokeWidth,
    required this.activeColor,
    required this.trackColor,
  });

  final double fraction;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, trackPaint);

    if (fraction <= 0.0) return;
    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    if (fraction >= 0.995) {
      canvas.drawCircle(center, radius, activePaint);
      return;
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      activePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CodeBuddyRingPainter old) =>
      old.fraction != fraction ||
      old.strokeWidth != strokeWidth ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor;
}

/// Compact badge showing the CodeBuddy region (`CN`, `AI`, `iOA`, `专享`).
class CodeBuddyRegionBadge extends StatelessWidget {
  const CodeBuddyRegionBadge({super.key, required this.region});

  final CodeBuddyRegion region;

  @override
  Widget build(BuildContext context) {
    final color = switch (region) {
      CodeBuddyRegion.cn => const Color(0xFF0284C7),
      CodeBuddyRegion.global => const Color(0xFF6366F1),
      CodeBuddyRegion.ioa => const Color(0xFF0D9488),
      CodeBuddyRegion.cloudhosted || CodeBuddyRegion.selfhosted =>
        const Color(0xFF7C3AED),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 0.8),
      ),
      child: Text(
        region.shortBadge,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.15,
        ),
      ),
    );
  }
}

/// Compact badge showing the CodeBuddy plan tier (`PRO`, `旗舰版`, `FREE`, `API KEY`).
class CodeBuddyEditionBadge extends StatelessWidget {
  const CodeBuddyEditionBadge({super.key, required this.edition});

  final CodeBuddyEdition edition;

  @override
  Widget build(BuildContext context) {
    final color = switch (edition) {
      CodeBuddyEdition.pro => const Color(0xFF0EA5E9),
      CodeBuddyEdition.ultimate || CodeBuddyEdition.exclusive =>
        const Color(0xFFD97706),
      CodeBuddyEdition.apiKey => const Color(0xFF10B981),
      CodeBuddyEdition.free => const Color(0xFF6B7280),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 0.8),
      ),
      child: Text(
        edition.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.15,
        ),
      ),
    );
  }
}
