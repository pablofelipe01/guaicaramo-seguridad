import 'package:flutter/material.dart';
import '../models/data_models.dart';

class DeliveryIndicator extends StatelessWidget {
  final DeliveryStatus status;
  final double size;

  const DeliveryIndicator({
    super.key,
    required this.status,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case DeliveryStatus.sending:
        return Icon(
          Icons.access_time,
          size: size,
          color: Colors.grey.shade400,
        );
      case DeliveryStatus.delivered:
        return Icon(
          Icons.done_all,
          size: size,
          color: Colors.green,
        );
      case DeliveryStatus.failed:
        return Icon(
          Icons.error_outline,
          size: size,
          color: Colors.red,
        );
      case DeliveryStatus.none:
        return Icon(
          Icons.done,
          size: size,
          color: Colors.grey.shade400,
        );
    }
  }
}
