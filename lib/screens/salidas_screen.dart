import 'dart:async';
import 'package:flutter/material.dart';
import '../models/data_models.dart';
import '../services/meshtastic_service.dart';

/// Pestaña Salidas — items autorizados a salir de Guaicaramo.
///
/// Flujo:
/// 1. Portero abre el tab → ve dropdown de items pendientes (cache local).
/// 2. Tap "Refrescar" → app pide la lista al gateway por LoRa. Spinner.
/// 3. Selecciona un item del dropdown → ve detalle (concepto, destino, etc).
/// 4. Tap "Registrar Salida" → marca item como usado y envía SALIDA_ITEM al
///    gateway. El item desaparece del dropdown.
class SalidasScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const SalidasScreen({super.key, required this.meshtasticService});

  @override
  State<SalidasScreen> createState() => _SalidasScreenState();
}

class _SalidasScreenState extends State<SalidasScreen> {
  StreamSubscription<void>? _itemsSub;
  Item? _selected;
  bool _refreshing = false;
  bool _registering = false;

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
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!_service.isConnected) {
      _showSnack('Sin conexión al nodo Meshtastic');
      return;
    }
    setState(() => _refreshing = true);
    final ok = await _service.requestItemsList();
    if (!mounted) return;
    if (!ok) {
      setState(() => _refreshing = false);
      _showSnack('No se pudo enviar la solicitud al gateway');
      return;
    }
    // Espera a que la lista termine de llegar (o pasen 30s).
    // El service expone progress/total; cuando matchean, terminó.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (mounted &&
        DateTime.now().isBefore(deadline) &&
        _service.itemsListInProgress) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

  Future<void> _registerExit() async {
    final item = _selected;
    if (item == null) return;
    if (!_service.isConnected) {
      _showSnack('Sin conexión al nodo Meshtastic');
      return;
    }
    setState(() => _registering = true);
    final ok = await _service.registerItemExit(item.numero);
    if (!mounted) return;
    setState(() {
      _registering = false;
      if (ok) _selected = null;
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

  Widget _buildDropdown(List<Item> pending) {
    if (pending.isEmpty) {
      return Card(
        color: Colors.grey.shade100,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(Icons.inbox, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              const Text(
                'No hay items autorizados pendientes',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'Tap "Refrescar" para consultar el gateway.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );
    }

    // Si el seleccionado actual ya no está en la lista (se marcó usado), limpiar.
    if (_selected != null && !pending.contains(_selected)) {
      _selected = null;
    }

    return DropdownButtonFormField<Item>(
      initialValue: _selected,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Selecciona un orden',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.list_alt),
      ),
      hint: const Text('Ver órdenes pendientes'),
      items: pending
          .map((it) => DropdownMenuItem(
                value: it,
                child: Text(
                  '#${it.numero} — ${it.nombre}',
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      onChanged: (v) => setState(() => _selected = v),
    );
  }

  Widget _buildDetail(Item it) {
    return Card(
      elevation: 3,
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.outbox, color: Colors.amber.shade800, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Orden #${it.numero}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(),
            _row('Nombre', it.nombre),
            if (it.concepto != null && it.concepto!.isNotEmpty)
              _row('Concepto', it.concepto!),
            if (it.destino != null && it.destino!.isNotEmpty)
              _row('Destino', it.destino!),
            if (it.autorizadoPor != null && it.autorizadoPor!.isNotEmpty)
              _row('Autorizado por', it.autorizadoPor!),
            if (it.area != null && it.area!.isNotEmpty)
              _row('Área', it.area!),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _registering ? null : _registerExit,
                icon: _registering
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.logout),
                label: Text(_registering ? 'Registrando…' : 'Registrar Salida'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 15),
          ),
        ],
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
        const Text(
          'Salidas recientes',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...exited.take(10).map(
              (it) => Card(
                color: Colors.grey.shade100,
                elevation: 1,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.check_circle,
                      color: Colors.green, size: 22),
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
    final pending = _service.pendingItems;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Salidas'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Refrescar lista',
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
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
            if (_service.itemsListInProgress)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: _service.itemsListTotal > 0
                          ? _service.itemsListProgress /
                              _service.itemsListTotal
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Recibiendo ${_service.itemsListProgress}/${_service.itemsListTotal}…',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                  ],
                ),
              ),
            _buildDropdown(pending),
            const SizedBox(height: 16),
            if (_selected != null) _buildDetail(_selected!),
            _buildRecentExits(),
          ],
        ),
      ),
    );
  }
}
