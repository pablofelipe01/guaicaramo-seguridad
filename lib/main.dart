import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'models/data_models.dart';
import 'services/meshtastic_service.dart';
import 'screens/chat_screen.dart';
import 'screens/map_screen.dart';
import 'screens/recepcion_screen.dart';
import 'screens/requests_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  runApp(const GuaicaramoControlApp());
}

class GuaicaramoControlApp extends StatelessWidget {
  const GuaicaramoControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Guaicaramo Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          secondary: Colors.teal,
        ),
        useMaterial3: true,
      ),
      home: const StartupScreen(),
    );
  }
}

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  final _meshtasticService = MeshtasticService();

  @override
  void initState() {
    super.initState();
    _checkSavedDevice();
  }

  Future<void> _checkSavedDevice() async {
    final savedAddress = await _meshtasticService.getSavedDeviceAddress();

    if (!mounted) return;

    if (savedAddress != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) =>
              MainScreen(meshtasticService: _meshtasticService),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) =>
              DeviceSelectionScreen(meshtasticService: _meshtasticService),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.bluetooth_searching,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('Cargando...'),
          ],
        ),
      ),
    );
  }
}

class DeviceSelectionScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const DeviceSelectionScreen({super.key, required this.meshtasticService});

  @override
  State<DeviceSelectionScreen> createState() => _DeviceSelectionScreenState();
}

class _DeviceSelectionScreenState extends State<DeviceSelectionScreen> {
  final List<ScannedDevice> _devices = [];
  bool _isScanning = false;
  bool _permissionsGranted = false;
  String? _permissionError;
  StreamSubscription<ScannedDevice>? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndScan();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkPermissionsAndScan() async {
    setState(() {
      _permissionError = null;
    });

    final denied = <String>[];

    if (Platform.isAndroid) {
      final bluetoothScan = await Permission.bluetoothScan.request();
      final bluetoothConnect = await Permission.bluetoothConnect.request();
      final location = await Permission.locationWhenInUse.request();

      try {
        await Permission.bluetooth.request();
      } catch (_) {}

      if (!bluetoothScan.isGranted) denied.add('Bluetooth Scan');
      if (!bluetoothConnect.isGranted) denied.add('Bluetooth Connect');
      if (!location.isGranted) denied.add('Ubicación');
    } else if (Platform.isIOS) {
      final bluetooth = await Permission.bluetooth.request();
      if (!bluetooth.isGranted) denied.add('Bluetooth');
    }

    if (denied.isNotEmpty) {
      setState(() {
        _permissionsGranted = false;
        _permissionError = Platform.isIOS
            ? 'Permiso de Bluetooth denegado.\nVaya a Ajustes > Guaicaramo Control > Bluetooth para habilitarlo.'
            : 'Permisos denegados: ${denied.join(", ")}.\nVaya a Configuración > Apps > Guaicaramo Control > Permisos para habilitarlos.';
      });
      return;
    }

    setState(() {
      _permissionsGranted = true;
      _permissionError = null;
    });

    _startScanning();
  }

  void _startScanning() {
    setState(() {
      _devices.clear();
      _isScanning = true;
    });

    _scanSubscription = widget.meshtasticService.scanDevices().listen(
      (device) {
        setState(() {
          final exists = _devices.any((d) => d.address == device.address);
          if (!exists) {
            _devices.add(device);
          }
        });
      },
      onDone: () {
        setState(() => _isScanning = false);
      },
      onError: (_) {
        setState(() => _isScanning = false);
      },
    );
  }

  Future<void> _selectDevice(ScannedDevice device) async {
    await widget.meshtasticService.connectToDevice(device);

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            MainScreen(meshtasticService: widget.meshtasticService),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Seleccionar Dispositivo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (!_isScanning)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startScanning,
              tooltip: 'Escanear de nuevo',
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isScanning) const LinearProgressIndicator(),
          if (_permissionError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.red.shade50,
              child: Column(
                children: [
                  const Icon(Icons.warning_amber, color: Colors.red, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    _permissionError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red.shade700, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => openAppSettings(),
                        icon: const Icon(Icons.settings),
                        label: const Text('Abrir Configuración'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _checkPermissionsAndScan,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_permissionsGranted) ...[
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Icon(
                    Icons.bluetooth_searching,
                    color: _isScanning ? Colors.blue : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _isScanning
                        ? 'Buscando dispositivos Meshtastic...'
                        : 'Dispositivos encontrados: ${_devices.length}',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: _devices.isEmpty && _permissionsGranted
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isScanning
                              ? Icons.bluetooth_searching
                              : Icons.bluetooth_disabled,
                          size: 64,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isScanning
                              ? 'Escaneando...'
                              : 'No se encontraron dispositivos',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        if (!_isScanning) ...[
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _startScanning,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Escanear de nuevo'),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      return ListTile(
                        leading: const Icon(
                          Icons.bluetooth,
                          color: Colors.blue,
                        ),
                        title: Text(
                          device.name.isNotEmpty
                              ? device.name
                              : 'Dispositivo desconocido',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          device.address,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _selectDevice(device),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const MainScreen({super.key, required this.meshtasticService});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;

  /// Destino opcional para el tab de chat (usado por el mapa para abrir DM
  /// con un nodo específico al tappearlo).
  ChatDestination? _pendingChatDestination;

  MeshtasticService get _service => widget.meshtasticService;

  /// Abre el tab de chat pre-seleccionando un destino. Lo llamará MapScreen
  /// (Fase 4) al tappear un nodo.
  void openChatWith(ChatDestination destination) {
    setState(() {
      _pendingChatDestination = destination;
      _currentIndex = 2;
    });
    _service.clearUnreadChat();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service.addListener(_onServiceChange);
    _connectToDevice();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_onServiceChange);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_service.isConnected) {
        debugPrint('📱 [LIFECYCLE] App resumed, reconectando...');
        _service.connectToSavedDevice();
      }
    }
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  Future<void> _connectToDevice() async {
    await _service.connectToSavedDevice();
  }

  void _navigateToDeviceSelection() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            DeviceSelectionScreen(meshtasticService: _service),
      ),
    );
  }

  Widget _buildCurrentPage() {
    switch (_currentIndex) {
      case 0:
        return RecepcionScreen(meshtasticService: _service);
      case 1:
        return RequestsScreen(meshtasticService: _service);
      case 2:
        final dest = _pendingChatDestination;
        // Limpiar el destino tras consumirlo para que cambios de tab posteriores
        // no fuercen abrir el mismo DM.
        _pendingChatDestination = null;
        return ChatScreen(
          key: ValueKey(dest ?? 'default'),
          meshtasticService: _service,
          initialDestination: dest,
        );
      case 3:
        return MapScreen(
          meshtasticService: _service,
          onOpenChat: openChatWith,
        );
      case 4:
        return SettingsScreen(
          meshtasticService: _service,
          onDeviceChange: _navigateToDeviceSelection,
          onDisconnect: _navigateToDeviceSelection,
        );
      default:
        return RecepcionScreen(meshtasticService: _service);
    }
  }

  Future<bool> _confirmExit() async {
    final activeCount = _service.activeEntries.length;
    final pendingCount = _service.pendingRequestsCount;

    final extraInfo = <String>[];
    if (activeCount > 0) {
      extraInfo.add(
        '$activeCount vehículo${activeCount == 1 ? '' : 's'} activo${activeCount == 1 ? '' : 's'}',
      );
    }
    if (pendingCount > 0) {
      extraInfo.add(
        '$pendingCount solicitud${pendingCount == 1 ? '' : 'es'} pendiente${pendingCount == 1 ? '' : 's'}',
      );
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Salir de la app?'),
        content: Text(
          extraInfo.isEmpty
              ? 'La app dejará de recibir mensajes mientras esté cerrada.'
              : 'Tienes ${extraInfo.join(' y ')}. '
                  'Los datos quedan guardados, pero la app dejará de recibir mensajes mientras esté cerrada.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Salir'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _handlePopAttempt() async {
    if (_currentIndex != 0) {
      setState(() => _currentIndex = 0);
      return;
    }
    final shouldExit = await _confirmExit();
    if (shouldExit) {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = _service.pendingRequestsCount;
    final unreadChat = _service.unreadChatCount;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handlePopAttempt();
      },
      child: Scaffold(
        body: _buildCurrentPage(),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            if (index == 2) {
              _service.clearUnreadChat();
            }
            setState(() => _currentIndex = index);
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.directions_car_outlined),
              selectedIcon: Icon(Icons.directions_car),
              label: 'Recepción',
            ),
            NavigationDestination(
              icon: Badge(
                label: Text('$pendingCount'),
                isLabelVisible: pendingCount > 0,
                child: const Icon(Icons.list_alt_outlined),
              ),
              selectedIcon: Badge(
                label: Text('$pendingCount'),
                isLabelVisible: pendingCount > 0,
                child: const Icon(Icons.list_alt),
              ),
              label: 'Solicitudes',
            ),
            NavigationDestination(
              icon: Badge(
                label: Text('$unreadChat'),
                isLabelVisible: unreadChat > 0,
                child: const Icon(Icons.chat_bubble_outline),
              ),
              selectedIcon: Badge(
                label: Text('$unreadChat'),
                isLabelVisible: unreadChat > 0,
                child: const Icon(Icons.chat_bubble),
              ),
              label: 'Chat',
            ),
            const NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: 'Mapa',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

