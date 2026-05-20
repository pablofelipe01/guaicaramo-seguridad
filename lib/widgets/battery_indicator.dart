import 'package:flutter/material.dart';

class BatteryIndicator extends StatelessWidget {
  final int? batteryLevel;
  final double? voltage;
  final double iconSize;
  final bool showPercentage;

  const BatteryIndicator({
    super.key,
    required this.batteryLevel,
    this.voltage,
    this.iconSize = 18,
    this.showPercentage = true,
  });

  @override
  Widget build(BuildContext context) {
    if (batteryLevel == null) {
      return Icon(
        Icons.battery_unknown,
        size: iconSize,
        color: Colors.grey,
      );
    }

    final level = batteryLevel!;
    final isUsb = level > 100;

    final IconData icon;
    final Color color;

    if (isUsb) {
      icon = Icons.power;
      color = Colors.blue;
    } else if (level > 75) {
      icon = Icons.battery_full;
      color = Colors.green;
    } else if (level > 50) {
      icon = Icons.battery_5_bar;
      color = Colors.green;
    } else if (level > 25) {
      icon = Icons.battery_3_bar;
      color = Colors.orange;
    } else {
      icon = Icons.battery_1_bar;
      color = Colors.red;
    }

    if (!showPercentage) {
      return Icon(icon, size: iconSize, color: color);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: color),
        const SizedBox(width: 2),
        Text(
          isUsb ? 'USB' : '$level%',
          style: TextStyle(
            fontSize: iconSize * 0.65,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
