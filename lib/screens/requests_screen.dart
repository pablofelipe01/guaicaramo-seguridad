import 'dart:async';
import 'package:flutter/material.dart';
import '../models/data_models.dart';
import '../services/meshtastic_service.dart';

class RequestsScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const RequestsScreen({super.key, required this.meshtasticService});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  StreamSubscription<VehicleRequest>? _requestSubscription;
  final Map<int, TextEditingController> _commentControllers = {};

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _requestSubscription =
        _service.vehicleRequestStream.listen(_onNewRequest);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    _requestSubscription?.cancel();
    for (final controller in _commentControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  void _onNewRequest(VehicleRequest request) {
    debugPrint('📋 [REQUESTS_SCREEN] Nueva solicitud: ${request.placa}');
    if (mounted) setState(() {});
  }

  TextEditingController _getCommentController(int requestId) {
    return _commentControllers.putIfAbsent(
      requestId,
      () => TextEditingController(),
    );
  }

  Future<void> _respond(String status, VehicleRequest request) async {
    final comment = _getCommentController(request.requestId).text.trim();

    final success = await _service.respondToVehicleRequest(
      request: request,
      status: status,
      supervisorName: _service.connectedDeviceName ?? 'Supervisor',
      comment: comment.isNotEmpty ? comment : null,
    );

    if (!mounted) return;

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Respuesta "$status" enviada a ${request.fromNodeName}'),
          backgroundColor: status == 'APROBADO'
              ? Colors.green
              : status == 'NEGADO'
                  ? Colors.red
                  : Colors.orange,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al enviar respuesta'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildRequestCard(VehicleRequest request) {
    final isResponded = request.isResponded;
    final commentController = _getCommentController(request.requestId);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 2,
      color: isResponded ? Colors.grey.shade100 : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.directions_car,
                          color: Colors.blue, size: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          request.placa,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${request.formattedDate} ${request.formattedTime}',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.badge, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text(
                  'CC ${request.cedula}',
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.router, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'De: ${request.fromNodeName}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (isResponded) ...[
              const SizedBox(height: 8),
              _buildRespondedBadge(request),
            ] else ...[
              const Divider(height: 16),
              TextField(
                controller: commentController,
                decoration: InputDecoration(
                  hintText: 'Comentario opcional…',
                  prefixIcon: const Icon(Icons.comment, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                maxLines: 1,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _respond('APROBADO', request),
                      icon: const Icon(Icons.check_circle, size: 18),
                      label: const Text('Aprobar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _respond('NEGADO', request),
                      icon: const Icon(Icons.cancel, size: 18),
                      label: const Text('Negar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _respond('PENDIENTE', request),
                      icon: Icon(
                        Icons.pending,
                        size: 18,
                        color: Colors.orange.shade700,
                      ),
                      label: Text(
                        'Pendiente',
                        style: TextStyle(color: Colors.orange.shade700),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.orange.shade700),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRespondedBadge(VehicleRequest request) {
    final status = request.responseStatus ?? '';
    final bg = status == 'APROBADO'
        ? Colors.green.shade100
        : status == 'NEGADO'
            ? Colors.red.shade100
            : Colors.orange.shade100;
    final color = status == 'APROBADO'
        ? Colors.green.shade700
        : status == 'NEGADO'
            ? Colors.red.shade700
            : Colors.orange.shade700;
    final icon = status == 'APROBADO'
        ? Icons.check_circle
        : status == 'NEGADO'
            ? Icons.cancel
            : Icons.pending;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 4),
              Text(
                'Respondido: $status'
                '${request.supervisorName != null ? " por ${request.supervisorName}" : ""}',
                style: TextStyle(fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
          if (request.comment != null && request.comment!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text(
                request.comment!,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _service.pendingRequests;
    final allRequests = _service.allRequests;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Solicitudes'),
            if (pending.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${pending.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (!_service.isConnected)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Icon(Icons.bluetooth_disabled, color: Colors.red),
            ),
        ],
      ),
      body: allRequests.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inbox, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No hay solicitudes',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Las solicitudes de aprobación\naparecerán aquí',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: allRequests.length,
              itemBuilder: (context, index) {
                // Más recientes primero.
                final request = allRequests[allRequests.length - 1 - index];
                return _buildRequestCard(request);
              },
            ),
    );
  }
}
