import 'package:flutter/material.dart';

class AlertKind {
  final int id;
  final String emoji;
  final String label;
  final String shortLabel;
  final Color color;
  final IconData icon;

  const AlertKind({
    required this.id,
    required this.emoji,
    required this.label,
    required this.shortLabel,
    required this.color,
    required this.icon,
  });

  static const control = AlertKind(
    id: 1,
    emoji: '🚔',
    label: 'Control policial',
    shortLabel: 'Control',
    color: Color(0xFF3B82F6),
    icon: Icons.local_police_outlined,
  );

  static const accidente = AlertKind(
    id: 2,
    emoji: '⚠️',
    label: 'Accidente',
    shortLabel: 'Accidente',
    color: Color(0xFFEAB308),
    icon: Icons.car_crash_outlined,
  );

  static const peligro = AlertKind(
    id: 3,
    emoji: '🚨',
    label: 'Peligro en la vía',
    shortLabel: 'Peligro',
    color: Color(0xFFEF4444),
    icon: Icons.warning_amber_rounded,
  );

  static const taco = AlertKind(
    id: 4,
    emoji: '🚧',
    label: 'Tráfico / Taco',
    shortLabel: 'Taco',
    color: Color(0xFFF97316),
    icon: Icons.traffic_outlined,
  );

  static const klkMane = AlertKind(
    id: 5,
    emoji: '🎉',
    label: 'KLK MANE ACTIVO',
    shortLabel: '¡KLK!',
    color: Color(0xFFEC4899),
    icon: Icons.celebration_outlined,
  );

  static const List<AlertKind> all = [control, accidente, peligro, taco, klkMane];

  static AlertKind fromId(int id) =>
      all.firstWhere((a) => a.id == id, orElse: () => peligro);
}
