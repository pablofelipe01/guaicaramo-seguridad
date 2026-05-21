import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/data_models.dart';
import '../services/meshtastic_service.dart';

/// Pestaña Salidas — verifica órdenes de servicio uno por uno.
///
/// Flujo:
/// 1. La persona llega con su papel (orden de servicio Sirius nº XXXX).
/// 2. Portero teclea el número (4-5 dígitos) en el campo.
/// 3. Tap "Verificar" → app envía CONSULTA_ITEM al gateway.
/// 4. Gateway responde con ITEM_RESP. App muestra:
///    - AUTORIZADO: card verde con detalle → botón "Registrar Salida"
///    - YA_USADO: card gris ("este orden ya fue usado")
///    - NO_AUTORIZADO: card naranja ("existe pero no autorizado")
///    - NO_EXISTE: card roja ("número 0000 no existe")
/// 5. Si autorizado → tap Registrar Salida → SALIDA_ITEM al gateway → marca usado.
class SalidasScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const SalidasScreen({super.key, required this.meshtasticService});

  @override
  State<SalidasScreen> createState() => _SalidasScreenState();
}

enum _SalidasStage { idle, checking, result, registering, done }

class _SalidasScreenState extends State<SalidasScreen> {
  final _numeroController = TextEditingController();
  StreamSubscription<void>? _itemsSub;

  _SalidasStage _stage = _SalidasStage.idle;
  ItemCheckResult? _lastResult;
  String _queriedNumero = '';

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _itemsSub = _service.itemsUpdatedStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    _itemsSub?.cancel();
    _numeroController.dispose();
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  void _resetForm() {
    setState(() {
      _stage = _SalidasStage.idle;
      _lastResult = null;
      _queriedNumero = '';
      _numeroController.clear();
    });
  }

  Future<void> _verify() async {
    final numero = _numeroController.text.trim();
    if (numero.isEmpty) {
      _showSnack('Ingresa el número del orden');
      return;
    }
    if (!_service.isConnected) {
      _showSnack('Sin conexión al nodo Meshtastic');
      return;
    }
    setState(() {
      _stage = _SalidasStage.checking;
      _queriedNumero = numero;
      _lastResult = null;
    });

    final result = await _service.consultItemWithGateway(numero: numero);

    if (!mounted) return;
    setState(() {
      _lastResult = result;
      _stage = _SalidasStage.result;
    });
  }

  Future<void> _registerExit() async {
    final item = _lastResult?.item;
    if (item == null) return;
    if (!_service.isConnected) {
      _showSnack('Sin conexión al nodo Meshtastic');
      return;
    }
    setState(() => _stage = _SalidasStage.registering);
    final ok = await _service.registerItemExit(item.numero);
    if (!mounted) return;
    setState(() {
      _stage = ok ? _SalidasStage.done : _SalidasStage.result;
    });
    _showSnack(
      ok
          ? 'Salida registrada: #${item.numero} (${item.nombre})'
          : 'Error registrando la salida',
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.outbox, color: Colors.amber.shade800, size: 28),
                const SizedBox(width: 12),
                const Text(
                  'Verificar orden de servicio',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _numeroController,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Número del orden',
                hintText: 'Ej: 0103',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.tag),
              ),
              style: const TextStyle(fontSize: 20, letterSpacing: 2),
              textAlign: TextAlign.center,
              onSubmitted: (_) => _verify(),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _stage == _SalidasStage.checking ||
                      !_service.isConnected
                  ? null
                  : _verify,
              icon: const Icon(Icons.search),
              label: const Text('Verificar'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    final result = _lastResult;
    if (result == null) return const SizedBox.shrink();

    // AUTORIZADO
    if (result.isAuthorized && result.item != null) {
      return _resultCard(
        icon: Icons.check_circle,
        color: Colors.green,
        title: 'AUTORIZADO',
        item: result.item!,
        primaryButton: ElevatedButton.icon(
          onPressed: _stage == _SalidasStage.registering ? null : _registerExit,
          icon: _stage == _SalidasStage.registering
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.logout),
          label: Text(
            _stage == _SalidasStage.registering
                ? 'Registrando…'
                : 'Registrar Salida',
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          ),
        ),
      );
    }

    // YA_USADO
    if (result.isAlreadyUsed && result.item != null) {
      return _resultCard(
        icon: Icons.block,
        color: Colors.grey,
        title: 'YA USADO',
        item: result.item!,
        info: 'Este orden ya fue marcado como usado anteriormente. '
            'No puede salir de nuevo.',
      );
    }

    // NO_AUTORIZADO
    if (result.isNotAuthorized) {
      return _resultCard(
        icon: Icons.warning_amber,
        color: Colors.orange,
        title: 'NO AUTORIZADO',
        info: 'El orden $_queriedNumero existe pero el admin no lo ha '
            'aprobado. Verifica con quien firmó el papel.',
      );
    }

    // NO_EXISTE
    if (result.isNotFound) {
      return _resultCard(
        icon: Icons.help_outline,
        color: Colors.red,
        title: 'NO EXISTE',
        info: 'No hay un orden con número $_queriedNumero en el sistema. '
            'Verifica el número en el papel.',
      );
    }

    // Timeout / Error
    return _resultCard(
      icon: Icons.error_outline,
      color: Colors.red,
      title: result.isTimeout ? 'SIN RESPUESTA' : 'ERROR',
      info: result.isTimeout
          ? 'El gateway no respondió a tiempo. Verifica conexión LoRa y '
              'reintenta.'
          : result.note ?? 'Error consultando el gateway.',
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
    );
  }

  Widget _resultCard({
    required IconData icon,
    required Color color,
    required String title,
    Item? item,
    String? info,
    Widget? primaryButton,
  }) {
    return Card(
      elevation: 4,
      color: color.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(icon, color: color, size: 56),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            if (item != null) ...[
              const SizedBox(height: 8),
              Text(
                '#${item.numero}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 12),
              _detailRow('Nombre', item.nombre),
              if (item.concepto != null && item.concepto!.isNotEmpty)
                _detailRow('Concepto', item.concepto!),
              if (item.destino != null && item.destino!.isNotEmpty)
                _detailRow('Destino', item.destino!),
              if (item.autorizadoPor != null && item.autorizadoPor!.isNotEmpty)
                _detailRow('Autorizado por', item.autorizadoPor!),
              if (item.area != null && item.area!.isNotEmpty)
                _detailRow('Área', item.area!),
            ],
            if (info != null) ...[
              const SizedBox(height: 12),
              Text(
                info,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            ?primaryButton,
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _resetForm,
              icon: const Icon(Icons.refresh),
              label: const Text('Nueva consulta'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDoneCard() {
    return Card(
      elevation: 4,
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 56),
            const SizedBox(height: 12),
            const Text(
              '✓ SALIDA REGISTRADA',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '#$_queriedNumero ya quedó registrado como usado en Airtable.',
              style: const TextStyle(fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _resetForm,
              icon: const Icon(Icons.add),
              label: const Text('Nueva consulta'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentExits() {
    final exited = _service.knownItems
        .where((i) => i.usado && i.fechaSalida != null)
        .toList()
      ..sort((a, b) => b.fechaSalida!.compareTo(a.fechaSalida!));
    if (exited.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(
          'Salidas recientes (${exited.length})',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...exited.take(10).map(
              (it) => Card(
                color: Colors.grey.shade100,
                elevation: 1,
                child: ListTile(
                  dense: true,
                  leading:
                      const Icon(Icons.check_circle, color: Colors.green, size: 22),
                  title: Text(
                    '#${it.numero} — ${it.nombre}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    it.concepto ?? '',
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    _formatTime(it.fechaSalida!),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Salidas'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _buildConnectionStatus(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_stage == _SalidasStage.idle ||
                _stage == _SalidasStage.checking)
              _buildForm(),
            if (_stage == _SalidasStage.checking)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text(
                      'Consultando gateway…',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            if (_stage == _SalidasStage.result ||
                _stage == _SalidasStage.registering)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _buildResultCard(),
              ),
            if (_stage == _SalidasStage.done)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _buildDoneCard(),
              ),
            _buildRecentExits(),
          ],
        ),
      ),
    );
  }
}
