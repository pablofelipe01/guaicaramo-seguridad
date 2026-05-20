import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/data_models.dart';
import '../services/meshtastic_service.dart';

/// Estado de la pantalla de recepción.
enum _RecepcionStage {
  idle, // formulario CC + Placa
  checking, // consultando gateway
  approvedByGateway, // ok automático
  notApproved, // gateway dijo no; seleccionar supervisor
  waitingSupervisor, // esperando respuesta del supervisor
  approvedBySupervisor, // supervisor aprobó manualmente
  deniedBySupervisor,
  pendingFromSupervisor,
  error,
}

class RecepcionScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const RecepcionScreen({super.key, required this.meshtasticService});

  @override
  State<RecepcionScreen> createState() => _RecepcionScreenState();
}

class _RecepcionScreenState extends State<RecepcionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _cedulaController = TextEditingController();
  final _placaController = TextEditingController();

  _RecepcionStage _stage = _RecepcionStage.idle;
  PlateCheckResult? _lastCheck;
  VehicleResponse? _lastResponse;
  MeshNode? _selectedSupervisor;
  String? _errorMessage;

  StreamSubscription<VehicleResponse>? _responseSubscription;
  Timer? _supervisorTimeoutTimer;

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _responseSubscription =
        _service.vehicleResponseStream.listen(_onSupervisorResponse);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    _responseSubscription?.cancel();
    _supervisorTimeoutTimer?.cancel();
    _cedulaController.dispose();
    _placaController.dispose();
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  void _resetForm() {
    setState(() {
      _stage = _RecepcionStage.idle;
      _lastCheck = null;
      _lastResponse = null;
      _selectedSupervisor = null;
      _errorMessage = null;
      _cedulaController.clear();
      _placaController.clear();
    });
    _supervisorTimeoutTimer?.cancel();
  }

  String get _cedula => _cedulaController.text.trim();
  String get _placa => _placaController.text.trim().toUpperCase();

  Future<void> _verify() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_service.isConnected) {
      _showSnack('Sin conexión al nodo Meshtastic');
      return;
    }

    setState(() {
      _stage = _RecepcionStage.checking;
      _errorMessage = null;
    });

    final result = await _service.checkPlateWithGateway(
      cedula: _cedula,
      placa: _placa,
    );

    if (!mounted) return;

    setState(() {
      _lastCheck = result;
      switch (result.status) {
        case PlateCheckStatus.approved:
          _stage = _RecepcionStage.approvedByGateway;
          break;
        case PlateCheckStatus.notApproved:
          _stage = _RecepcionStage.notApproved;
          break;
        case PlateCheckStatus.timeout:
          _stage = _RecepcionStage.error;
          _errorMessage =
              'El gateway no respondió a tiempo. Verifica conexión LoRa.';
          break;
        case PlateCheckStatus.error:
          _stage = _RecepcionStage.error;
          _errorMessage = result.note ?? 'Error consultando el gateway.';
          break;
      }
    });
  }

  Future<void> _registerEntryFromGateway() async {
    final approvedBy = 'GATEWAY';
    _service.addVehicleEntry(
      cedula: _cedula,
      placa: _placa,
      approvedBy: approvedBy,
    );
    await _service.sendEntryToGateway(
      cedula: _cedula,
      placa: _placa,
      approvedBy: approvedBy,
    );
    _showSnack('Entrada registrada: $_placa');
    _resetForm();
  }

  Future<void> _requestSupervisorApproval() async {
    final supervisor = _selectedSupervisor;
    if (supervisor == null) {
      _showSnack('Selecciona un supervisor para enviar la solicitud');
      return;
    }

    setState(() => _stage = _RecepcionStage.waitingSupervisor);

    final sent = await _service.requestVehicleApproval(
      cedula: _cedula,
      placa: _placa,
      supervisorNodeId: supervisor.nodeId,
    );

    if (!mounted) return;

    if (!sent) {
      setState(() {
        _stage = _RecepcionStage.error;
        _errorMessage = 'No se pudo enviar la solicitud al supervisor.';
      });
      return;
    }

    // El supervisor puede tardar varios minutos. Timeout de 5 min para limpiar la espera.
    _supervisorTimeoutTimer?.cancel();
    _supervisorTimeoutTimer = Timer(const Duration(minutes: 5), () {
      if (!mounted) return;
      if (_stage == _RecepcionStage.waitingSupervisor) {
        setState(() {
          _stage = _RecepcionStage.error;
          _errorMessage = 'El supervisor no respondió. Intenta de nuevo.';
        });
      }
    });
  }

  void _onSupervisorResponse(VehicleResponse response) {
    if (_stage != _RecepcionStage.waitingSupervisor) return;
    _supervisorTimeoutTimer?.cancel();
    setState(() {
      _lastResponse = response;
      if (response.isApproved) {
        _stage = _RecepcionStage.approvedBySupervisor;
      } else if (response.isDenied) {
        _stage = _RecepcionStage.deniedBySupervisor;
      } else {
        _stage = _RecepcionStage.pendingFromSupervisor;
      }
    });

    if (response.isApproved) {
      _service.addVehicleEntry(
        cedula: _cedula,
        placa: _placa,
        approvedBy: response.supervisorName,
      );
      _service.sendRegistroManualToGateway(
        status: 'APROBADO',
        cedula: _cedula,
        placa: _placa,
        supervisor: response.supervisorName,
        comment: response.comment,
      );
    } else if (response.isDenied) {
      _service.sendRegistroManualToGateway(
        status: 'NEGADO',
        cedula: _cedula,
        placa: _placa,
        supervisor: response.supervisorName,
        comment: response.comment,
      );
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _registerVehicleExit(VehicleEntry entry) async {
    final sent = await _service.sendVehicleExitToGateway(placa: entry.placa);
    if (sent) {
      _service.markVehicleExited(entry.placa);
      _showSnack('Salida registrada: ${entry.placa}');
    } else {
      _showSnack('Error al registrar salida');
    }
  }

  Widget _buildConnectionStatus() {
    IconData icon;
    Color color;
    switch (_service.status) {
      case ConnectionStatus.connected:
        icon = Icons.bluetooth_connected;
        color = Colors.green;
        break;
      case ConnectionStatus.connecting:
      case ConnectionStatus.scanning:
        icon = Icons.bluetooth_searching;
        color = Colors.orange;
        break;
      case ConnectionStatus.error:
        icon = Icons.bluetooth_disabled;
        color = Colors.red;
        break;
      case ConnectionStatus.disconnected:
        icon = Icons.bluetooth;
        color = Colors.grey;
        break;
    }
    return Icon(icon, color: color, size: 22);
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _cedulaController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Cédula',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.badge),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Ingresa la cédula';
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _placaController,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
              LengthLimitingTextInputFormatter(8),
              TextInputFormatter.withFunction(
                (oldValue, newValue) => newValue.copyWith(
                  text: newValue.text.toUpperCase(),
                ),
              ),
            ],
            decoration: const InputDecoration(
              labelText: 'Placa',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.directions_car),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Ingresa la placa';
              if (v.trim().length < 4) return 'Placa muy corta';
              return null;
            },
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _stage == _RecepcionStage.checking || !_service.isConnected
                ? null
                : _verify,
            icon: const Icon(Icons.search),
            label: const Text('Verificar'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    switch (_stage) {
      case _RecepcionStage.idle:
        return const SizedBox.shrink();

      case _RecepcionStage.checking:
        return Card(
          color: Colors.blue.shade50,
          elevation: 3,
          child: const Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text(
                  'Consultando gateway…',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                SizedBox(height: 4),
                Text(
                  'Esperando respuesta de Airtable.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
          ),
        );

      case _RecepcionStage.approvedByGateway:
        return _ResultCard(
          icon: Icons.check_circle,
          color: Colors.green,
          title: 'AUTORIZADO',
          subtitle: _lastCheck?.driverName != null &&
                  _lastCheck!.driverName!.isNotEmpty
              ? 'Conductor: ${_lastCheck!.driverName}'
              : 'Placa $_placa autorizada',
          primaryButton: ElevatedButton.icon(
            onPressed: _registerEntryFromGateway,
            icon: const Icon(Icons.login),
            label: const Text('Registrar Entrada'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            ),
          ),
          onReset: _resetForm,
        );

      case _RecepcionStage.notApproved:
        return _buildNotApprovedCard();

      case _RecepcionStage.waitingSupervisor:
        return Card(
          color: Colors.orange.shade50,
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                const Text(
                  'Esperando respuesta del supervisor…',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                Text(
                  'Solicitud enviada a ${_selectedSupervisor?.displayName ?? "supervisor"}.',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _resetForm,
                  child: const Text('Cancelar'),
                ),
              ],
            ),
          ),
        );

      case _RecepcionStage.approvedBySupervisor:
        return _ResultCard(
          icon: Icons.check_circle,
          color: Colors.green,
          title: 'APROBADO',
          subtitle: 'Por: ${_lastResponse?.supervisorName ?? ""}',
          comment: _lastResponse?.comment,
          info: 'Vehículo registrado en la lista de abajo.',
          onReset: _resetForm,
        );

      case _RecepcionStage.deniedBySupervisor:
        return _ResultCard(
          icon: Icons.cancel,
          color: Colors.red,
          title: 'NEGADO',
          subtitle: 'Por: ${_lastResponse?.supervisorName ?? ""}',
          comment: _lastResponse?.comment,
          onReset: _resetForm,
        );

      case _RecepcionStage.pendingFromSupervisor:
        return _ResultCard(
          icon: Icons.pending,
          color: Colors.orange,
          title: 'PENDIENTE',
          subtitle: 'Por: ${_lastResponse?.supervisorName ?? ""}',
          comment: _lastResponse?.comment,
          info: 'El supervisor pidió tiempo. Repite la consulta más tarde.',
          onReset: _resetForm,
        );

      case _RecepcionStage.error:
        return _ResultCard(
          icon: Icons.error_outline,
          color: Colors.red,
          title: 'ERROR',
          subtitle: _errorMessage ?? 'Error desconocido',
          primaryButton: ElevatedButton.icon(
            onPressed: _verify,
            icon: const Icon(Icons.refresh),
            label: const Text('Reintentar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            ),
          ),
          onReset: _resetForm,
        );
    }
  }

  Widget _buildNotApprovedCard() {
    final supervisors = _service.onlineNodes
        .where((n) => n.nodeId != _service.currentGatewayNodeId)
        .toList();

    return Card(
      color: Colors.orange.shade50,
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber, color: Colors.orange, size: 32),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Placa no autorizada',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'La placa $_placa no está en la lista. Solicita aprobación manual a un supervisor.',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<MeshNode>(
              initialValue: _selectedSupervisor,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Supervisor destino',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.supervisor_account),
              ),
              hint: const Text('Selecciona un supervisor'),
              items: supervisors
                  .map((n) => DropdownMenuItem(
                        value: n,
                        child: Text(
                          '${n.displayName} (${n.shortId})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedSupervisor = v),
            ),
            if (supervisors.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  'No hay supervisores online. Espera a recibir mensajes de otros nodos.',
                  style: TextStyle(
                    color: Colors.orange.shade700,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed:
                  _selectedSupervisor == null ? null : _requestSupervisorApproval,
              icon: const Icon(Icons.send),
              label: const Text('Solicitar Aprobación Manual'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            TextButton(
              onPressed: _resetForm,
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveVehicles() {
    final all = _service.allEntries;
    if (all.isEmpty) return const SizedBox.shrink();

    final active = all.where((v) => !v.hasExited).toList();
    final exited = all.where((v) => v.hasExited).toList();
    final sorted = [...active.reversed, ...exited.reversed];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Row(
          children: [
            const Icon(Icons.directions_car, size: 20),
            const SizedBox(width: 8),
            Text(
              'Vehículos (${active.length} activos)',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...sorted.map(_buildVehicleCard),
      ],
    );
  }

  Widget _buildVehicleCard(VehicleEntry entry) {
    return Card(
      elevation: 2,
      color: entry.hasExited ? Colors.grey.shade100 : Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              entry.hasExited ? Icons.logout : Icons.directions_car,
              color: entry.hasExited ? Colors.grey : Colors.green,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.placa,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      decoration:
                          entry.hasExited ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(
                    'CC ${entry.cedula} • ${entry.approvedBy}',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  Text(
                    'Entrada: ${entry.formattedEntryTime}'
                    '${entry.hasExited ? "  •  Salida: ${entry.formattedExitTime}" : ""}',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
            if (!entry.hasExited)
              ElevatedButton.icon(
                onPressed: () => _registerVehicleExit(entry),
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('Salida'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool get _isFormStage =>
      _stage == _RecepcionStage.idle || _stage == _RecepcionStage.checking;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Recepción', style: TextStyle(fontSize: 18)),
            if (_service.connectedDeviceName != null)
              Text(
                _service.connectedDeviceName!,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: _buildConnectionStatus(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_service.status == ConnectionStatus.connecting ||
                _service.status == ConnectionStatus.scanning)
              const Padding(
                padding: EdgeInsets.only(bottom: 16.0),
                child: LinearProgressIndicator(),
              ),
            if (_isFormStage) _buildForm(),
            if (_stage != _RecepcionStage.idle)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _buildStatusCard(),
              ),
            _buildActiveVehicles(),
          ],
        ),
      ),
    );
  }
}

/// Card de resultado genérica (aprobado/negado/pendiente/error).
class _ResultCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? comment;
  final String? info;
  final Widget? primaryButton;
  final VoidCallback onReset;

  const _ResultCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.comment,
    this.info,
    this.primaryButton,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      color: color.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Icon(icon, color: color, size: 56),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            if (comment != null && comment!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white70,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.comment, size: 18, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        comment!,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (info != null) ...[
              const SizedBox(height: 8),
              Text(
                info!,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            ?primaryButton,
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.add),
              label: const Text('Nueva consulta'),
            ),
          ],
        ),
      ),
    );
  }
}
