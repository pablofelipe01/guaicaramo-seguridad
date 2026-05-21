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
  StreamSubscription<VehicleRequest>? _vehicleSubscription;
  StreamSubscription<PersonRequest>? _personSubscription;
  final Map<String, TextEditingController> _commentControllers = {};

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _vehicleSubscription =
        _service.vehicleRequestStream.listen((_) => _bumpRebuild());
    _personSubscription =
        _service.personRequestStream.listen((_) => _bumpRebuild());
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    _vehicleSubscription?.cancel();
    _personSubscription?.cancel();
    for (final c in _commentControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  void _bumpRebuild() {
    if (mounted) setState(() {});
  }

  TextEditingController _commentController(String key) =>
      _commentControllers.putIfAbsent(key, () => TextEditingController());

  Future<void> _respondVehicle(String status, VehicleRequest req) async {
    final comment = _commentController('v${req.requestId}').text.trim();
    final ok = await _service.respondToVehicleRequest(
      request: req,
      status: status,
      supervisorName: _service.connectedDeviceName ?? 'Supervisor',
      comment: comment.isNotEmpty ? comment : null,
    );
    _showResponseSnack(ok, status, req.fromNodeName);
  }

  Future<void> _respondPerson(String status, PersonRequest req) async {
    final comment = _commentController('p${req.requestId}').text.trim();
    final ok = await _service.respondToPersonRequest(
      request: req,
      status: status,
      supervisorName: _service.connectedDeviceName ?? 'Supervisor',
      comment: comment.isNotEmpty ? comment : null,
    );
    _showResponseSnack(ok, status, req.fromNodeName);
  }

  void _showResponseSnack(bool ok, String status, String dest) {
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Respuesta "$status" enviada a $dest'),
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

  /// Items unificados para mostrar mezclados, ordenados por timestamp.
  List<_Item> _allItems() {
    final items = <_Item>[
      ..._service.allRequests.map((r) => _Item.vehicle(r)),
      ..._service.allPersonRequests.map((r) => _Item.person(r)),
    ];
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items;
  }

  Widget _buildCard(_Item item) {
    final isResponded = item.isResponded;
    final key = item.commentKey;
    final ctrl = _commentController(key);

    final icon = item.isVehicle ? Icons.directions_car : Icons.directions_walk;
    final iconColor = item.isVehicle ? Colors.blue : Colors.purple;
    final title = item.isVehicle ? item.vehicle!.placa : 'CC ${item.person!.cedula}';
    final subtitleCedula = item.isVehicle
        ? 'CC ${item.vehicle!.cedula}'
        : 'Peatón';

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
                      Icon(icon, color: iconColor, size: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${item.formattedDate} ${item.formattedTime}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.badge, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text(subtitleCedula, style: const TextStyle(fontSize: 14)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.router, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'De: ${item.fromNodeName}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (item.porteroComment != null &&
                item.porteroComment!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  border: Border.all(color: Colors.amber.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: Colors.amber.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.porteroComment!,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.amber.shade900,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (item.acompananteCedulas.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade50,
                  border: Border.all(color: Colors.blueGrey.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.group,
                            size: 18, color: Colors.blueGrey.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'Acompañantes (${item.acompananteCedulas.length}):',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.blueGrey.shade800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    for (final cc in item.acompananteCedulas)
                      Padding(
                        padding: const EdgeInsets.only(left: 26, top: 2),
                        child: Text(
                          'CC $cc',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blueGrey.shade700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (isResponded) ...[
              const SizedBox(height: 8),
              _buildRespondedBadge(item),
            ] else ...[
              const Divider(height: 16),
              TextField(
                controller: ctrl,
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
                      onPressed: () => _dispatch(item, 'APROBADO'),
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
                      onPressed: () => _dispatch(item, 'NEGADO'),
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
                      onPressed: () => _dispatch(item, 'PENDIENTE'),
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

  void _dispatch(_Item item, String status) {
    if (item.isVehicle) {
      _respondVehicle(status, item.vehicle!);
    } else {
      _respondPerson(status, item.person!);
    }
  }

  Widget _buildRespondedBadge(_Item item) {
    final status = item.responseStatus ?? '';
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
                '${item.supervisorName != null ? " por ${item.supervisorName}" : ""}',
                style: TextStyle(fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
          if (item.comment != null && item.comment!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text(
                item.comment!,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _allItems();
    final pendingCount = _service.pendingRequestsCount;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Solicitudes'),
            if (pendingCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$pendingCount',
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
      body: items.isEmpty
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
              itemCount: items.length,
              itemBuilder: (context, index) => _buildCard(items[index]),
            ),
    );
  }
}

/// View model interno para mezclar vehículos y peatones en una sola lista.
class _Item {
  final VehicleRequest? vehicle;
  final PersonRequest? person;

  _Item.vehicle(this.vehicle) : person = null;
  _Item.person(this.person) : vehicle = null;

  bool get isVehicle => vehicle != null;
  DateTime get timestamp =>
      isVehicle ? vehicle!.timestamp : person!.timestamp;
  String get fromNodeName =>
      isVehicle ? vehicle!.fromNodeName : person!.fromNodeName;
  bool get isResponded =>
      isVehicle ? vehicle!.isResponded : person!.isResponded;
  String? get responseStatus =>
      isVehicle ? vehicle!.responseStatus : person!.responseStatus;
  String? get supervisorName =>
      isVehicle ? vehicle!.supervisorName : person!.supervisorName;
  String? get comment => isVehicle ? vehicle!.comment : person!.comment;
  String? get porteroComment =>
      isVehicle ? vehicle!.porteroComment : person!.porteroComment;
  List<String> get acompananteCedulas =>
      isVehicle ? vehicle!.acompananteCedulas : const <String>[];
  String get formattedTime =>
      isVehicle ? vehicle!.formattedTime : person!.formattedTime;
  String get formattedDate =>
      isVehicle ? vehicle!.formattedDate : person!.formattedDate;
  String get commentKey => isVehicle
      ? 'v${vehicle!.requestId}'
      : 'p${person!.requestId}';
}
