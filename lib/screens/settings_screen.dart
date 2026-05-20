import 'package:flutter/material.dart';
import '../models/data_models.dart';
import '../services/meshtastic_service.dart';
import '../widgets/battery_indicator.dart';

class SettingsScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;
  final VoidCallback onDeviceChange;
  final VoidCallback onDisconnect;

  const SettingsScreen({
    super.key,
    required this.meshtasticService,
    required this.onDeviceChange,
    required this.onDisconnect,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  LoraRegion _selectedRegion = LoraRegion.unset;
  int? _selectedGatewayNodeId;
  bool _isApplyingConfig = false;

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _loadSavedRegion();
    _loadSavedGateway();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSavedRegion() async {
    final region = await _service.getSavedLoraRegion();
    if (mounted) setState(() => _selectedRegion = region);
  }

  Future<void> _loadSavedGateway() async {
    final nodeId = await _service.getSavedGatewayNodeId();
    if (mounted) setState(() => _selectedGatewayNodeId = nodeId);
  }

  Future<void> _applyConfiguration() async {
    setState(() => _isApplyingConfig = true);

    final success = await _service.setLoraRegion(_selectedRegion);

    setState(() => _isApplyingConfig = false);

    if (!mounted) return;

    final message = success
        ? (_service.isConnected
            ? 'Configuración aplicada correctamente'
            : 'Región guardada. Se aplicará al conectar un dispositivo.')
        : 'Error al guardar configuración';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _disconnectDevice() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Desconectar nodo'),
        content: const Text(
          '¿Estás seguro de que deseas desconectar el nodo? '
          'Deberás seleccionar uno nuevo para continuar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Desconectar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _service.disconnectAndClear();
      widget.onDisconnect();
    }
  }

  void _changeDevice() {
    widget.onDeviceChange();
  }

  Future<void> _clearStoredData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Borrar todos los datos'),
        content: const Text(
          'Esto eliminará permanentemente:\n\n'
          '• Vehículos activos y registrados\n'
          '• Solicitudes pendientes y respondidas\n'
          '• Historial completo de chat\n\n'
          'La configuración del nodo, gateway y región LoRa se mantienen.\n\n'
          '¿Continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _service.clearAllData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Datos borrados'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildNodeInfoSection() {
    final deviceName = _service.connectedDeviceName ?? 'Desconocido';
    final deviceMac = _service.connectedDeviceMac ?? 'N/A';
    final isConnected = _service.isConnected;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bluetooth,
                  color: isConnected ? Colors.blue : Colors.grey,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Nodo Conectado',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            _buildInfoRow('Nombre', deviceName),
            const SizedBox(height: 8),
            _buildInfoRow('MAC Address', deviceMac),
            const SizedBox(height: 8),
            _buildInfoRow(
              'Estado',
              isConnected ? 'Conectado' : 'Desconectado',
              valueColor: isConnected ? Colors.green : Colors.red,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Batería',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                ),
                BatteryIndicator(
                  batteryLevel: _service.connectedNodeBatteryLevel,
                  voltage: _service.connectedNodeVoltage,
                  iconSize: 20,
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _disconnectDevice,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Desconectar'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 14,
              color: valueColor,
            ),
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildGatewaySection() {
    final nodes = _service.onlineNodes;
    final selectedNode = nodes.cast<MeshNode?>().firstWhere(
          (n) => n!.nodeId == _selectedGatewayNodeId,
          orElse: () => null,
        );

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.cell_tower, color: Colors.teal),
                SizedBox(width: 12),
                Text(
                  'Gateway',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            DropdownButtonFormField<MeshNode>(
              initialValue: selectedNode,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Nodo Gateway',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.router),
              ),
              hint: const Text('Seleccione el gateway'),
              items: nodes.map((node) {
                return DropdownMenuItem(
                  value: node,
                  child: Text(
                    '${node.displayName} (${node.shortId})',
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedGatewayNodeId = value.nodeId);
                  _service.saveGatewayNodeId(value.nodeId);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Gateway: ${value.displayName}'),
                      backgroundColor: Colors.teal,
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Las consultas de placas y registros se envían a este nodo.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoraConfigSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.settings_input_antenna, color: Colors.orange),
                SizedBox(width: 12),
                Text(
                  'Configuración LoRa',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            DropdownButtonFormField<LoraRegion>(
              initialValue: _selectedRegion,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Región LoRa',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.public),
              ),
              items: LoraRegion.values.map((region) {
                return DropdownMenuItem(
                  value: region,
                  child: Text(region.displayName),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedRegion = value);
                }
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: !_isApplyingConfig ? _applyConfiguration : null,
                icon: _isApplyingConfig
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check),
                label: Text(
                  _isApplyingConfig ? 'Aplicando...' : 'Aplicar Configuración',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (!_service.isConnected)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  'Sin conexión — la región se guardará localmente',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionsSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.touch_app, color: Colors.purple),
                SizedBox(width: 12),
                Text(
                  'Acciones',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _changeDevice,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Cambiar Nodo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _clearStoredData,
                icon: const Icon(Icons.delete_forever),
                label: const Text('Borrar Datos Almacenados'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Elimina vehículos, solicitudes y chat. No afecta la configuración.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración del Nodo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildNodeInfoSection(),
            const SizedBox(height: 16),
            _buildGatewaySection(),
            const SizedBox(height: 16),
            _buildLoraConfigSection(),
            const SizedBox(height: 16),
            _buildActionsSection(),
          ],
        ),
      ),
    );
  }
}
