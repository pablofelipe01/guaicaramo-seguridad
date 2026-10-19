import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/data_models.dart';
import '../services/meshtastic_service.dart';

/// Tipo de acceso a registrar.
/// - [vehiculo]: CC + Placa, consulta tabla Placas.
/// - [persona]: solo CC (+ nombre opcional para aprobación manual), tabla Personas.
/// - [finDeSemana]: solo CC, tabla FinDeSemana (whitelist simple).
enum _AccessMode { vehiculo, persona, finDeSemana }

enum _RecepcionStage {
  idle,
  checking,
  approvedByGateway,
  // Caso 2 — no existe en la base: se habilita el formulario de registro.
  noRegistrado,
  // Caso 1 — existe pero sin autorización activa: bloqueo total, alerta a
  // recepción (la levanta el gateway). El portero no puede registrar.
  sinAutorizacion,
  // Existe pero fue RECHAZADO: requiere admin para reabrir.
  rechazadoExistente,
  sendingSolicitud,
  solicitudEnviada,
  solicitudRechazada,
  solicitudYaVigente,
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
  final _nombreController = TextEditingController();
  final _porteroCommentController = TextEditingController();

  _AccessMode _mode = _AccessMode.vehiculo;
  _RecepcionStage _stage = _RecepcionStage.idle;
  AreaDestino _areaDestino = AreaDestino.defaultArea;

  PlateCheckResult? _lastPlateCheck;
  PersonCheckResult? _lastPersonCheck;
  String? _errorMessage;

  MeshtasticService get _service => widget.meshtasticService;

  StreamSubscription<GatewayResultNotice>? _resultSub;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    // Resultado proactivo del gateway (recepción resolvió): snackbar prominente.
    _resultSub = _service.gatewayResultStream.listen(_onGatewayResult);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    _resultSub?.cancel();
    _cedulaController.dispose();
    _placaController.dispose();
    _nombreController.dispose();
    _porteroCommentController.dispose();
    super.dispose();
  }

  void _onGatewayResult(GatewayResultNotice n) {
    if (!mounted) return;
    final quien = (n.nombre != null && n.nombre!.isNotEmpty) ? n.nombre! : n.key;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: n.aprobado ? Colors.green.shade700 : Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text(
          n.aprobado
              ? '✓ Recepción AUTORIZÓ a $quien (${n.categoriaLabel})'
              : '✕ Recepción RECHAZÓ a $quien (${n.categoriaLabel})',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  void _resetForm() {
    setState(() {
      _stage = _RecepcionStage.idle;
      _lastPlateCheck = null;
      _lastPersonCheck = null;
      _errorMessage = null;
      _areaDestino = AreaDestino.defaultArea;
      _cedulaController.clear();
      _placaController.clear();
      _nombreController.clear();
      _porteroCommentController.clear();
    });
  }

  String get _cedula => _cedulaController.text.trim();
  String get _placa => _placaController.text.trim().toUpperCase();
  String get _nombre => _nombreController.text.trim();
  String get _porteroComment => _porteroCommentController.text.trim();

  bool get _isVehicle => _mode == _AccessMode.vehiculo;
  bool get _isFinDeSemana => _mode == _AccessMode.finDeSemana;

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

    if (_isVehicle) {
      final result = await _service.checkPlateWithGateway(
        cedula: _cedula,
        placa: _placa,
      );
      if (!mounted) return;
      setState(() {
        _lastPlateCheck = result;
        _stage = _stageFromStatus(result.status);
        if (result.isTimeout) {
          _errorMessage =
              'El gateway no respondió a tiempo. Verifica conexión LoRa.';
        } else if (result.isError) {
          _errorMessage = result.note ?? 'Error consultando el gateway.';
        }
      });
    } else {
      final result = _isFinDeSemana
          ? await _service.checkFinDeSWithGateway(cedula: _cedula)
          : await _service.checkPersonWithGateway(cedula: _cedula);
      if (!mounted) return;
      setState(() {
        _lastPersonCheck = result;
        _stage = _stageFromStatus(result.status);
        if (result.isTimeout) {
          _errorMessage =
              'El gateway no respondió a tiempo. Verifica conexión LoRa.';
        } else if (result.isError) {
          _errorMessage = result.note ?? 'Error consultando el gateway.';
        }
      });
    }
  }

  _RecepcionStage _stageFromStatus(PlateCheckStatus status) {
    switch (status) {
      case PlateCheckStatus.approved:
        return _RecepcionStage.approvedByGateway;
      case PlateCheckStatus.notRegistered:
      // Gateway viejo (NO_APROBADO genérico): tratar como no registrado.
      case PlateCheckStatus.notApproved:
        return _RecepcionStage.noRegistrado;
      case PlateCheckStatus.registeredUnauthorized:
        return _RecepcionStage.sinAutorizacion;
      case PlateCheckStatus.rejected:
        return _RecepcionStage.rechazadoExistente;
      case PlateCheckStatus.timeout:
      case PlateCheckStatus.error:
        return _RecepcionStage.error;
    }
  }

  Future<void> _registerEntryFromGateway() async {
    if (_isVehicle) {
      _service.addVehicleEntry(
        cedula: _cedula,
        placa: _placa,
        approvedBy: 'GATEWAY',
      );
      await _service.sendEntryToGateway(
        cedula: _cedula,
        placa: _placa,
        approvedBy: 'GATEWAY',
      );
      _showSnack('Entrada registrada: $_placa — enviando al sistema…');
    } else {
      final nombre = _lastPersonCheck?.personName ?? _nombre;
      if (_isFinDeSemana) {
        _service.addFinDeSEntry(
          cedula: _cedula,
          nombre: nombre,
          approvedBy: 'GATEWAY',
        );
        await _service.sendFinDeSEntryToGateway(
          cedula: _cedula,
          approvedBy: 'GATEWAY',
        );
      } else {
        _service.addPersonEntry(
          cedula: _cedula,
          nombre: nombre,
          approvedBy: 'GATEWAY',
        );
        await _service.sendPersonEntryToGateway(
          cedula: _cedula,
          approvedBy: 'GATEWAY',
        );
      }
      _showSnack('Entrada registrada: $nombre — enviando al sistema…');
    }
    _resetForm();
  }

  /// Caso 2 (solo vehículos) — el conductor no existe en Placas. Envía la
  /// SOLICITUD_V al gateway, que crea la fila PENDIENTE con el motivo y el área
  /// de destino, y responde el resultado.
  Future<void> _registrarConductor() async {
    if (!_service.isConnected) {
      _showSnack('Sin conexión al nodo Meshtastic');
      return;
    }
    if (_nombre.isEmpty) {
      _showSnack('Nombre es requerido');
      return;
    }
    if (_porteroComment.length < 5) {
      _showSnack('Descripción requerida (mín 5 caracteres)');
      return;
    }

    setState(() => _stage = _RecepcionStage.sendingSolicitud);

    final result = await _service.sendSolicitudVehiculoToGateway(
      cedula: _cedula,
      placa: _placa,
      areaCode: _areaDestino.code,
      nombre: _nombre,
      comment: _porteroComment,
    );

    if (!mounted) return;

    setState(() {
      switch (result) {
        case SolicitudResult.registrada:
          _stage = _RecepcionStage.solicitudEnviada;
        case SolicitudResult.rechazada:
          _stage = _RecepcionStage.solicitudRechazada;
        case SolicitudResult.yaVigente:
          _stage = _RecepcionStage.solicitudYaVigente;
        case SolicitudResult.timeout:
          _stage = _RecepcionStage.error;
          _errorMessage =
              'El gateway no respondió a tiempo. Verifica la conexión LoRa.';
        case SolicitudResult.error:
          _stage = _RecepcionStage.error;
          _errorMessage = 'No se pudo registrar la solicitud en el gateway.';
      }
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _registerVehicleExit(VehicleEntry entry) async {
    final sent = await _service.sendVehicleExitToGateway(placa: entry.placa);
    if (sent) {
      _service.markVehicleExited(entry.placa);
      _showSnack('Salida registrada: ${entry.placa} — enviando al sistema…');
    } else {
      _showSnack('Error al registrar salida');
    }
  }

  Future<void> _registerPersonExit(PersonEntry entry) async {
    final sent = await _service.sendPersonExitToGateway(cedula: entry.cedula);
    if (sent) {
      _service.markPersonExited(entry.cedula);
      _showSnack('Salida registrada: ${entry.nombre} — enviando al sistema…');
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

  Widget _buildModeToggle() {
    return SegmentedButton<_AccessMode>(
      segments: const [
        ButtonSegment(
          value: _AccessMode.vehiculo,
          icon: Icon(Icons.directions_car),
          label: Text('Vehículo'),
        ),
        ButtonSegment(
          value: _AccessMode.persona,
          icon: Icon(Icons.person),
          label: Text('Persona'),
        ),
        ButtonSegment(
          value: _AccessMode.finDeSemana,
          icon: Icon(Icons.weekend),
          label: Text('Fin de S'),
        ),
      ],
      selected: {_mode},
      showSelectedIcon: false,
      onSelectionChanged: (s) {
        if (_stage != _RecepcionStage.idle &&
            _stage != _RecepcionStage.checking) {
          return;
        }
        setState(() {
          _mode = s.first;
          _resetForm();
        });
      },
    );
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
          if (_isVehicle)
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
          // En persona y fin-de-semana solo se pide la CC; el nombre se captura
          // en el formulario de registro (Caso 2) si no está registrado.
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

  String get _approvedSubtitle {
    if (_isVehicle) {
      final driver = _lastPlateCheck?.driverName;
      return (driver != null && driver.isNotEmpty)
          ? 'Conductor: $driver'
          : 'Placa $_placa autorizada';
    }
    final person = _lastPersonCheck?.personName;
    final area = _lastPersonCheck?.area;
    final base = (person != null && person.isNotEmpty)
        ? (_isFinDeSemana ? 'Fin de S: $person' : 'Persona: $person')
        : 'CC $_cedula autorizada';
    if (_isFinDeSemana && area != null && area.isNotEmpty) {
      return '$base · $area';
    }
    return base;
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
                  'La red puede tardar hasta un minuto. No repita la consulta.',
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
          subtitle: _approvedSubtitle,
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

      case _RecepcionStage.noRegistrado:
        return _buildRegistroCard();

      case _RecepcionStage.sinAutorizacion:
        return _buildSinAutorizacionCard();

      case _RecepcionStage.rechazadoExistente:
        return _buildRechazadoCard();

      case _RecepcionStage.sendingSolicitud:
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
                  'Enviando solicitud…',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                SizedBox(height: 4),
                Text(
                  'Esperando confirmación del gateway.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
          ),
        );

      case _RecepcionStage.solicitudEnviada:
        return _ResultCard(
          icon: Icons.mark_email_read,
          color: Colors.blue,
          title: 'SOLICITUD ENVIADA',
          subtitle: 'Esperando aprobación en Airtable.',
          info: 'Se registró la solicitud. Cuando alguien la apruebe, '
              'vuelve a consultar y aparecerá como AUTORIZADO.',
          onReset: _resetForm,
        );

      case _RecepcionStage.solicitudRechazada:
        return _ResultCard(
          icon: Icons.block,
          color: Colors.red,
          title: 'RECHAZADA',
          subtitle: _isVehicle
              ? 'La placa $_placa fue rechazada.'
              : 'La cédula $_cedula fue rechazada.',
          info: 'No se reabre desde la app. Si debe entrar, un administrador '
              'tiene que habilitarla en Airtable.',
          onReset: _resetForm,
        );

      case _RecepcionStage.solicitudYaVigente:
        return _ResultCard(
          icon: Icons.check_circle,
          color: Colors.green,
          title: 'YA AUTORIZADA',
          subtitle: 'Esta entrada ya está vigente.',
          info: 'Vuelve a consultar para registrar el ingreso.',
          primaryButton: ElevatedButton.icon(
            onPressed: _verify,
            icon: const Icon(Icons.refresh),
            label: const Text('Consultar de nuevo'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            ),
          ),
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

  /// Caso 2 — no existe en la base.
  ///
  /// En vehículos el portero SÍ puede registrar al conductor: formulario rápido
  /// (placa y cédula fijas, nombre + motivo de visita + área de destino) que
  /// crea la fila PENDIENTE en Placas. En persona y fin de semana no hay
  /// registro desde la mesh: solo se le dice que llame a recepción.
  Widget _buildRegistroCard() {
    if (!_isVehicle) {
      final label = _isFinDeSemana
          ? 'La cédula $_cedula no está en la lista de fin de semana.'
          : 'La cédula $_cedula no está registrada.';
      return _ResultCard(
        icon: Icons.phone_in_talk,
        color: Colors.red,
        title: 'NO REGISTRADO',
        subtitle: label,
        info: 'Esta persona no está autorizada. Llame a recepción.',
        onReset: _resetForm,
      );
    }

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
                const Icon(Icons.person_add_alt, color: Colors.orange, size: 32),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Conductor no registrado',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'La placa $_placa no está registrada. Completa los datos y envía '
              'a aprobación de recepción.',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            // Placa y cédula vienen de la consulta: se muestran, no se editan.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  const Icon(Icons.directions_car, size: 18, color: Colors.grey),
                  const SizedBox(width: 8),
                  Text(
                    _placa,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Icon(Icons.badge, size: 18, color: Colors.grey),
                  const SizedBox(width: 8),
                  Text('CC $_cedula', style: const TextStyle(fontSize: 15)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nombreController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Nombre completo *',
                hintText: 'Nombre y apellido del conductor',
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _porteroCommentController,
              minLines: 2,
              maxLines: 3,
              maxLength: MeshtasticService.maxMotivoVisita,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: '¿Para dónde se dirige? *',
                hintText: 'Ej: "entrega de insumos en almacén"',
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
                prefixIcon: Icon(Icons.edit_note),
              ),
            ),
            DropdownButtonFormField<AreaDestino>(
              initialValue: _areaDestino,
              decoration: const InputDecoration(
                labelText: 'Área de destino *',
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
                prefixIcon: Icon(Icons.place),
              ),
              // Las áreas deshabilitadas se ven en la lista (grises) pero no se
              // pueden elegir: hoy el portero solo registra báscula y almacén.
              items: [
                for (final area in AreaDestino.values)
                  DropdownMenuItem(
                    value: area,
                    enabled: area.enabled,
                    child: Text(
                      area.label,
                      style: TextStyle(
                        color: area.enabled ? null : Colors.grey.shade400,
                      ),
                    ),
                  ),
              ],
              onChanged: (area) {
                if (area == null || !area.enabled) return;
                setState(() => _areaDestino = area);
              },
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _registrarConductor,
              icon: const Icon(Icons.send),
              label: const Text('REGISTRAR'),
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

  /// Caso 1 — la persona/placa YA existe pero sin autorización activa. Bloqueo
  /// total: el portero no puede registrar. El gateway ya levantó la alerta a
  /// recepción y avisará el resultado por push.
  Widget _buildSinAutorizacionCard() {
    final nombre = _isVehicle
        ? _lastPlateCheck?.driverName
        : _lastPersonCheck?.personName;
    final quien = (nombre != null && nombre.isNotEmpty)
        ? nombre
        : (_isVehicle ? 'La placa $_placa' : 'La cédula $_cedula');

    return Card(
      color: Colors.red.shade50,
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            const Icon(Icons.gpp_bad, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            const Text(
              'SIN AUTORIZACIÓN',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$quien está registrado pero NO tiene autorización de ingreso activa.',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: const Row(
                children: [
                  Icon(Icons.notifications_active, color: Colors.red, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Se notificó a recepción. No puedes autorizar el ingreso. '
                      'Espera la decisión — te avisaremos aquí.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _resetForm,
              icon: const Icon(Icons.add),
              label: const Text('Nueva consulta'),
            ),
          ],
        ),
      ),
    );
  }

  /// Existe pero fue RECHAZADO previamente: requiere admin para reabrir.
  Widget _buildRechazadoCard() {
    final subtitle = _isVehicle
        ? 'La placa $_placa fue rechazada.'
        : 'La cédula $_cedula fue rechazada.';
    return _ResultCard(
      icon: Icons.block,
      color: Colors.red,
      title: 'RECHAZADA',
      subtitle: subtitle,
      info: 'No se reabre desde la app. Si debe entrar, un administrador '
          'tiene que habilitarla en Airtable.',
      onReset: _resetForm,
    );
  }

  Widget _buildActiveList() {
    final vehicleAll = _service.allEntries;
    final personAll = _service.allPersonEntries;
    if (vehicleAll.isEmpty && personAll.isEmpty) return const SizedBox.shrink();

    final vehiclesActive = vehicleAll.where((v) => !v.hasExited).toList();
    final vehiclesExited = vehicleAll.where((v) => v.hasExited).toList();
    final personsActive = personAll.where((v) => !v.hasExited).toList();
    final personsExited = personAll.where((v) => v.hasExited).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Row(
          children: [
            const Icon(Icons.list, size: 20),
            const SizedBox(width: 8),
            Text(
              'Activos: ${vehiclesActive.length} 🚗 · ${personsActive.length} 👤',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...vehiclesActive.reversed.map(_buildVehicleCard),
        ...personsActive.reversed.map(_buildPersonCard),
        ...vehiclesExited.reversed.map(_buildVehicleCard),
        ...personsExited.reversed.map(_buildPersonCard),
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
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  Text(
                    'Entrada: ${entry.formattedEntryTime}'
                    '${entry.hasExited ? "  •  Salida: ${entry.formattedExitTime}" : ""}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
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

  Widget _buildPersonCard(PersonEntry entry) {
    return Card(
      elevation: 2,
      color: entry.hasExited ? Colors.grey.shade100 : Colors.purple.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              entry.hasExited ? Icons.logout : Icons.person,
              color: entry.hasExited ? Colors.grey : Colors.purple,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.nombre,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      decoration:
                          entry.hasExited ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(
                    'CC ${entry.cedula} • ${entry.approvedBy}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  Text(
                    'Entrada: ${entry.formattedEntryTime}'
                    '${entry.hasExited ? "  •  Salida: ${entry.formattedExitTime}" : ""}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
            if (!entry.hasExited)
              ElevatedButton.icon(
                onPressed: () => _registerPersonExit(entry),
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

  /// Entradas que el gateway todavía no confirmó (REG_OK). Mientras se
  /// reintenta se ve "Enviando…"; si se agotan los intentos queda en rojo con
  /// "Reintentar" para que el portero no crea que quedó guardada.
  Widget _buildRegistrosBanner() {
    final pendientes = _service.registrosPendientes;
    if (pendientes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in pendientes)
          if (r.estado == RegistroEnvioEstado.fallido)
            Card(
              elevation: 2,
              color: Colors.red.shade50,
              child: ListTile(
                leading: const Icon(Icons.error, color: Colors.red),
                title: Text(
                  '${r.label} NO llegó al sistema',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14),
                ),
                subtitle: Text(
                  '${r.motivo ?? 'Sin confirmación'} · '
                  '${r.createdAt.hour.toString().padLeft(2, '0')}:'
                  '${r.createdAt.minute.toString().padLeft(2, '0')}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _service.retryRegistro(r.regId),
                      child: const Text('Reintentar'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Descartar',
                      onPressed: () => _confirmDiscardRegistro(r),
                    ),
                  ],
                ),
              ),
            )
          else
            Card(
              color: Colors.grey.shade100,
              child: ListTile(
                dense: true,
                leading: const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text('Enviando ${r.label}…'),
                subtitle: Text(r.intentos > 1
                    ? 'Intento ${r.intentos} de 3 · ${r.motivo ?? ''}'
                    : 'Esperando confirmación del gateway'),
              ),
            ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _confirmDiscardRegistro(RegistroPendiente r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Descartar aviso'),
        content: Text(
          '${r.label} no está en el sistema central. Descártelo solo si ya '
          'la registraron por otro medio (ej: directo en Airtable).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    if (ok == true) _service.discardRegistro(r.regId);
  }

  /// Banner con los resultados que recepción ya resolvió (push del gateway).
  /// El portero los ve aunque haya seguido con otra consulta.
  Widget _buildResultsBanner() {
    final results = _service.gatewayResults;
    if (results.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in results.reversed)
          Card(
            elevation: 2,
            color: r.aprobado ? Colors.green.shade50 : Colors.red.shade50,
            child: ListTile(
              leading: Icon(
                r.aprobado ? Icons.check_circle : Icons.cancel,
                color: r.aprobado ? Colors.green : Colors.red,
              ),
              title: Text(
                '${r.titulo} — ${(r.nombre != null && r.nombre!.isNotEmpty) ? r.nombre! : r.key}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              subtitle: Text('${r.categoriaLabel} · ${r.key}'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Descartar',
                onPressed: () => _service.dismissGatewayResult(r),
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
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
            _buildRegistrosBanner(),
            _buildResultsBanner(),
            Center(child: _buildModeToggle()),
            const SizedBox(height: 16),
            if (_isFormStage) _buildForm(),
            if (_stage != _RecepcionStage.idle)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _buildStatusCard(),
              ),
            _buildActiveList(),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? info;
  final Widget? primaryButton;
  final VoidCallback onReset;

  const _ResultCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
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
