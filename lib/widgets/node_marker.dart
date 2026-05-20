import 'package:flutter/material.dart';
import '../models/data_models.dart';

/// Marker visual para un nodo en el mapa: pin + etiqueta + indicador de batería.
///
/// Diferencia visualmente:
/// - Gateway → `Icons.cell_tower` color teal
/// - Otros nodos → `Icons.location_on` coloreado por batería (verde >50,
///   naranja 25-50, rojo <25, azul USB-powered).
class NodeMarker extends StatelessWidget {
  final MeshNode node;
  final bool isGateway;
  final bool isMe;
  final VoidCallback? onTap;

  const NodeMarker({
    super.key,
    required this.node,
    this.isGateway = false,
    this.isMe = false,
    this.onTap,
  });

  Color get _color {
    if (isGateway) return Colors.teal;
    if (node.isUsbPowered) return Colors.blue;
    final battery = node.batteryLevel;
    if (battery == null) return Colors.grey;
    if (battery > 50) return Colors.green;
    if (battery > 25) return Colors.orange;
    return Colors.red;
  }

  IconData get _icon =>
      isGateway ? Icons.cell_tower : Icons.location_on;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _color, width: 1.2),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: Text(
              isMe ? '${node.displayName} (tú)' : node.displayName,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
          ),
          Icon(_icon, color: _color, size: 36, shadows: const [
            Shadow(color: Colors.black54, blurRadius: 3, offset: Offset(0, 1)),
          ]),
        ],
      ),
    );
  }
}
