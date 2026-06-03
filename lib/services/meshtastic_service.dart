import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:meshtastic_flutter/meshtastic_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/data_models.dart';

const int _maxMessageBytes = 237;

const String _savedDeviceAddressKey = 'saved_device_address';
const String _savedDeviceNameKey = 'saved_device_name';
const String _loraRegionKey = 'lora_region';
const String _gatewayNodeIdKey = 'gateway_node_id';
const String _vehicleEntriesKey = 'vehicle_entries';
const String _vehicleRequestsKey = 'vehicle_requests';
const String _personEntriesKey = 'person_entries';
const String _personRequestsKey = 'person_requests';
const String _itemsCacheKey = 'items_cache';
const String _messageHistoryKey = 'message_history';
const String _lastSessionDateKey = 'last_session_date';
const int _maxMessageHistory = 100;
const int _maxTrackPoints = 500;

// Gateway de Guaicaramo — nodo Heltec V3 conectado por USB a la Pi.
// Es el único nodo pre-cargado; los demás aparecen automáticamente al
// recibir tráfico de la mesh (NodeInfo o mensajes de texto).
const int gatewayNodeId = 0x9ea29bc4;
const String gatewayNodeName = 'Guaicaramo Gateway';

enum ConnectionStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  error,
}

enum LoraRegion {
  unset('UNSET', 'Sin configurar'),
  us('US', '915 MHz'),
  eu433('EU_433', '433 MHz'),
  eu868('EU_868', '868 MHz');

  final String code;
  final String frequency;

  const LoraRegion(this.code, this.frequency);

  String get displayName => '$code ($frequency)';

  static LoraRegion fromCode(String code) {
    return LoraRegion.values.firstWhere(
      (r) => r.code == code,
      orElse: () => LoraRegion.unset,
    );
  }
}

class ScannedDevice {
  final String name;
  final String address;
  final dynamic rawDevice;

  ScannedDevice({
    required this.name,
    required this.address,
    required this.rawDevice,
  });
}

class MeshtasticService extends ChangeNotifier {
  MeshtasticClient? _client;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _statusMessage = 'Desconectado';
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _packetSubscription;

  String? _connectedDeviceName;
  String? _connectedDeviceMac;

  // Auto-reconexión
  bool _autoReconnectEnabled = false;
  bool _isReconnecting = false;
  static const int _maxReconnectAttempts = 10;
  static const Duration _reconnectDelay = Duration(seconds: 2);

  // Keepalive
  Timer? _keepaliveTimer;
  static const Duration _keepaliveInterval = Duration(seconds: 15);

  // Chat / nodos
  final List<ChatMessage> _messageHistory = [];
  final Map<int, MeshNode> _knownNodes = {};

  // Dedupe de paquetes — Queue FIFO + Set O(1) lookup (fix bug sirius_porteria).
  final Queue<int> _processedPacketIds = Queue<int>();
  final Set<int> _processedPacketSet = {};
  static const int _maxProcessedPacketIds = 200;

  // Tracks GPS por sesión (no persistido — se reconstruye desde la mesh).
  final Map<int, List<NodePositionPoint>> _sessionTracks = {};

  // Gateway configurable
  int? _selectedGatewayNodeId;

  MeshtasticService() {
    for (final entry in _preloadedNodes) {
      _knownNodes[entry.nodeId] = entry;
    }
    _loadSavedGatewayNodeId();
    _loadPersistedState();
  }

  static final List<MeshNode> _preloadedNodes = [
    MeshNode(nodeId: gatewayNodeId, nodeName: gatewayNodeName, isOnline: true),
  ];

  int get currentGatewayNodeId => _selectedGatewayNodeId ?? gatewayNodeId;
  MeshNode? get currentGatewayNode => _knownNodes[currentGatewayNodeId];

  // Delivery tracking de DMs.
  final Map<int, List<ChatMessage>> _pendingDeliveries = {};
  static const int _deliveryTimeoutSeconds = 45;

  // Unreads
  int _unreadChatCount = 0;
  final Set<int> _nodesWithUnread = {};
  final Set<int> _channelsWithUnread = {};

  // Solicitudes y entradas de vehículos
  final List<VehicleRequest> _vehicleRequests = [];
  final List<VehicleEntry> _vehicleEntries = [];

  // Solicitudes y entradas de peatones
  final List<PersonRequest> _personRequests = [];
  final List<PersonEntry> _personEntries = [];

  // Consultas en vuelo — requestId -> Completer.
  // ignore: unused_field
  final Map<String, Completer<PlateCheckResult>> _pendingPlateChecks = {};
  final Map<String, Completer<PersonCheckResult>> _pendingPersonChecks = {};

  /// Contador secuencial para garantizar requestIds únicos cuando se disparan
  /// múltiples consultas en el mismo milisegundo (driver + acompañantes en
  /// paralelo). Sin esto, dos calls colisionan en `_pendingChecks[id]` y la
  /// primera Completer queda huérfana → timeout silencioso.
  int _requestSeq = 0;

  String _newRequestId() {
    _requestSeq = (_requestSeq + 1) & 0xFFFF;
    return '${DateTime.now().millisecondsSinceEpoch}-$_requestSeq';
  }

  // ---------- Items (órdenes de salida) ----------

  /// Items conocidos, indexed por numero. Persiste localmente para no perder
  /// la lista si la app se cierra antes de registrar la salida.
  final Map<String, Item> _knownItems = {};

  /// Fragmentos de listado en curso: requestId -> {totalEsperado, items}.
  /// Cuando llegan todos los LIST_RESP de un mismo requestId, se commitea.
  final Map<String, _ItemListInProgress> _pendingItemLists = {};

  /// requestId de la última solicitud de lista — para que la UI muestre
  /// progreso o complete cuando llega el total esperado.
  String? _lastItemListRequestId;
  int _lastItemListProgress = 0;
  int _lastItemListTotal = -1;

  /// Consultas de item en vuelo: requestId -> Completer.
  final Map<String, Completer<ItemCheckResult>> _pendingItemChecks = {};

  final _itemsUpdatedController = StreamController<void>.broadcast();

  Stream<void> get itemsUpdatedStream => _itemsUpdatedController.stream;

  List<Item> get knownItems => _knownItems.values.toList();
  List<Item> get pendingItems =>
      _knownItems.values.where((i) => !i.usado).toList();

  int get itemsListProgress => _lastItemListProgress;
  int get itemsListTotal => _lastItemListTotal;
  bool get itemsListInProgress =>
      _lastItemListTotal >= 0 &&
      _lastItemListProgress < _lastItemListTotal;

  final _messageController = StreamController<ChatMessage>.broadcast();
  final _vehicleRequestController = StreamController<VehicleRequest>.broadcast();
  final _vehicleResponseController = StreamController<VehicleResponse>.broadcast();
  final _personRequestController = StreamController<PersonRequest>.broadcast();
  final _personResponseController = StreamController<PersonResponse>.broadcast();
  final _nodePositionController = StreamController<MeshNode>.broadcast();

  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<VehicleRequest> get vehicleRequestStream => _vehicleRequestController.stream;
  Stream<VehicleResponse> get vehicleResponseStream => _vehicleResponseController.stream;
  Stream<PersonRequest> get personRequestStream => _personRequestController.stream;
  Stream<PersonResponse> get personResponseStream => _personResponseController.stream;
  Stream<MeshNode> get nodePositionStream => _nodePositionController.stream;

  List<VehicleRequest> get pendingRequests =>
      _vehicleRequests.where((r) => !r.isResponded).toList();
  List<VehicleRequest> get allRequests => List.unmodifiable(_vehicleRequests);

  List<PersonRequest> get pendingPersonRequests =>
      _personRequests.where((r) => !r.isResponded).toList();
  List<PersonRequest> get allPersonRequests => List.unmodifiable(_personRequests);

  /// Total combinado para el badge del tab Solicitudes.
  int get pendingRequestsCount =>
      pendingRequests.length + pendingPersonRequests.length;

  List<VehicleEntry> get activeEntries =>
      _vehicleEntries.where((v) => !v.hasExited).toList();
  List<VehicleEntry> get allEntries => List.unmodifiable(_vehicleEntries);

  List<PersonEntry> get activePersonEntries =>
      _personEntries.where((v) => !v.hasExited).toList();
  List<PersonEntry> get allPersonEntries => List.unmodifiable(_personEntries);

  ConnectionStatus get status => _status;
  String get statusMessage => _statusMessage;
  bool get isConnected => _status == ConnectionStatus.connected;

  String? get connectedDeviceName => _connectedDeviceName;
  String? get connectedDeviceMac => _connectedDeviceMac;

  List<ChatMessage> get messageHistory => List.unmodifiable(_messageHistory);

  /// Nodos online — excluye al nodo local (fix bug sirius_porteria).
  List<MeshNode> get onlineNodes {
    final myId = myNodeNum;
    return _knownNodes.values
        .where((n) => n.isOnline && (myId == null || n.nodeId != myId))
        .toList();
  }

  /// Nodos con posición GPS conocida (para el mapa).
  List<MeshNode> get nodesWithPosition =>
      _knownNodes.values.where((n) => n.hasPosition).toList();

  /// Track de posiciones de un nodo en la sesión actual.
  List<NodePositionPoint> getTrackFor(int nodeId) =>
      List.unmodifiable(_sessionTracks[nodeId] ?? const []);

  /// ID del nodo local — null si aún no llegó NodeInfo del cliente.
  int? get myNodeNum => _client?.myNodeInfo?.myNodeNum;

  int get unreadChatCount => _unreadChatCount;
  bool hasUnreadFromNode(int nodeId) => _nodesWithUnread.contains(nodeId);
  bool hasUnreadOnChannel(int channel) => _channelsWithUnread.contains(channel);

  /// Limpia el contador global y los sets de no-leídos (fix bug sirius_porteria).
  void clearUnreadChat() {
    _unreadChatCount = 0;
    _nodesWithUnread.clear();
    _channelsWithUnread.clear();
    notifyListeners();
  }

  void clearUnreadForDestination(ChatDestination destination) {
    if (destination.isChannel) {
      _channelsWithUnread.remove(destination.channel);
    } else if (destination.nodeId != null) {
      _nodesWithUnread.remove(destination.nodeId);
    }
    notifyListeners();
  }

  List<ChatMessage> getMessagesForDestination(ChatDestination destination) {
    if (destination.isChannel) {
      return _messageHistory
          .where((m) => m.channel == destination.channel && !m.isDirectMessage)
          .toList();
    } else {
      return _messageHistory
          .where((m) =>
              m.isDirectMessage &&
              (m.fromNodeId == destination.nodeId ||
                  m.toNodeId == destination.nodeId))
          .toList();
    }
  }

  void clearMessageHistory() {
    _messageHistory.clear();
    _saveMessageHistory();
    notifyListeners();
    debugPrint('🗑️ [SERVICE] Historial de mensajes limpiado');
  }

  String _getNodeName(int nodeId) {
    if (_knownNodes.containsKey(nodeId)) {
      final node = _knownNodes[nodeId]!;
      if (node.nodeName.isNotEmpty) return node.nodeName;
    }
    try {
      final nodes = _client?.nodes;
      if (nodes != null) {
        final nodeInfo = nodes[nodeId];
        if (nodeInfo?.user?.longName != null &&
            nodeInfo!.user!.longName.isNotEmpty) {
          return nodeInfo.user!.longName;
        }
        if (nodeInfo?.user?.shortName != null &&
            nodeInfo!.user!.shortName.isNotEmpty) {
          return nodeInfo.user!.shortName;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error obteniendo nombre de nodo: $e');
    }
    return '!${nodeId.toRadixString(16).padLeft(8, '0')}';
  }

  static int getUtf8ByteLength(String text) => utf8.encode(text).length;
  static bool isMessageTooLong(String text) =>
      getUtf8ByteLength(text) > _maxMessageBytes;
  static int get maxMessageBytes => _maxMessageBytes;

  Future<void> _ensureClientInitialized() async {
    if (_client == null) {
      _client = MeshtasticClient();
      await _client!.initialize();
    }
  }

  // ---------- Persistencia de dispositivo / configuración ----------

  Future<String?> getSavedDeviceAddress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_savedDeviceAddressKey);
  }

  Future<String?> getSavedDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_savedDeviceNameKey);
  }

  Future<void> saveDeviceInfo(String address, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_savedDeviceAddressKey, address);
    await prefs.setString(_savedDeviceNameKey, name);
  }

  Future<void> clearSavedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_savedDeviceAddressKey);
    await prefs.remove(_savedDeviceNameKey);
    _connectedDeviceName = null;
    _connectedDeviceMac = null;
  }

  Future<LoraRegion> getSavedLoraRegion() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_loraRegionKey);
    return code != null ? LoraRegion.fromCode(code) : LoraRegion.unset;
  }

  Future<void> saveLoraRegion(LoraRegion region) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_loraRegionKey, region.code);
  }

  Future<void> _loadSavedGatewayNodeId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_gatewayNodeIdKey);
    if (saved != null) {
      _selectedGatewayNodeId = saved;
      notifyListeners();
    }
  }

  Future<int> getSavedGatewayNodeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_gatewayNodeIdKey) ?? gatewayNodeId;
  }

  Future<void> saveGatewayNodeId(int nodeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_gatewayNodeIdKey, nodeId);
    _selectedGatewayNodeId = nodeId;
    notifyListeners();
  }

  // ---------- Persistencia de estado de la app ----------

  Future<void> _loadPersistedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final entriesJson = prefs.getString(_vehicleEntriesKey);
      if (entriesJson != null) {
        final decoded = jsonDecode(entriesJson) as List<dynamic>;
        _vehicleEntries.clear();
        for (final item in decoded) {
          _vehicleEntries
              .add(VehicleEntry.fromJson(item as Map<String, dynamic>));
        }
      }

      final requestsJson = prefs.getString(_vehicleRequestsKey);
      if (requestsJson != null) {
        final decoded = jsonDecode(requestsJson) as List<dynamic>;
        _vehicleRequests.clear();
        for (final item in decoded) {
          _vehicleRequests
              .add(VehicleRequest.fromJson(item as Map<String, dynamic>));
        }
      }

      final personEntriesJson = prefs.getString(_personEntriesKey);
      if (personEntriesJson != null) {
        final decoded = jsonDecode(personEntriesJson) as List<dynamic>;
        _personEntries.clear();
        for (final item in decoded) {
          _personEntries
              .add(PersonEntry.fromJson(item as Map<String, dynamic>));
        }
      }

      final personRequestsJson = prefs.getString(_personRequestsKey);
      if (personRequestsJson != null) {
        final decoded = jsonDecode(personRequestsJson) as List<dynamic>;
        _personRequests.clear();
        for (final item in decoded) {
          _personRequests
              .add(PersonRequest.fromJson(item as Map<String, dynamic>));
        }
      }

      final messagesJson = prefs.getString(_messageHistoryKey);
      if (messagesJson != null) {
        final decoded = jsonDecode(messagesJson) as List<dynamic>;
        _messageHistory.clear();
        for (final item in decoded) {
          _messageHistory
              .add(ChatMessage.fromJson(item as Map<String, dynamic>));
        }
      }

      final itemsJson = prefs.getString(_itemsCacheKey);
      if (itemsJson != null) {
        final decoded = jsonDecode(itemsJson) as List<dynamic>;
        _knownItems.clear();
        for (final raw in decoded) {
          final it = Item.fromJson(raw as Map<String, dynamic>);
          _knownItems[it.numero] = it;
        }
      }

      // Limpieza diaria
      final lastDateStr = prefs.getString(_lastSessionDateKey);
      final today = _dateKey(DateTime.now());
      if (lastDateStr != null && lastDateStr != today) {
        final beforeV = _vehicleEntries.length;
        final beforeP = _personEntries.length;
        _vehicleEntries.removeWhere((v) => v.hasExited);
        _vehicleRequests.removeWhere((r) => r.isResponded);
        _personEntries.removeWhere((v) => v.hasExited);
        _personRequests.removeWhere((r) => r.isResponded);
        debugPrint(
          '🗓️ [DAILY_CLEANUP] Cambio de día. Vehículos: $beforeV → ${_vehicleEntries.length}, Peatones: $beforeP → ${_personEntries.length}',
        );
        await _saveVehicleEntries();
        await _saveVehicleRequests();
        await _savePersonEntries();
        await _savePersonRequests();
      }
      await prefs.setString(_lastSessionDateKey, today);

      debugPrint(
        '✅ [PERSIST] Cargado — entradas: ${_vehicleEntries.length}, solicitudes: ${_vehicleRequests.length}, mensajes: ${_messageHistory.length}',
      );
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ [PERSIST] Error cargando estado: $e\n$st');
    }
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _saveVehicleEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(_vehicleEntries.map((v) => v.toJson()).toList());
      await prefs.setString(_vehicleEntriesKey, encoded);
    } catch (e) {
      debugPrint('❌ [PERSIST] Error guardando entradas: $e');
    }
  }

  Future<void> _saveVehicleRequests() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(_vehicleRequests.map((r) => r.toJson()).toList());
      await prefs.setString(_vehicleRequestsKey, encoded);
    } catch (e) {
      debugPrint('❌ [PERSIST] Error guardando solicitudes: $e');
    }
  }

  Future<void> _savePersonEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(_personEntries.map((v) => v.toJson()).toList());
      await prefs.setString(_personEntriesKey, encoded);
    } catch (e) {
      debugPrint('❌ [PERSIST] Error guardando peatones: $e');
    }
  }

  Future<void> _savePersonRequests() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(_personRequests.map((r) => r.toJson()).toList());
      await prefs.setString(_personRequestsKey, encoded);
    } catch (e) {
      debugPrint('❌ [PERSIST] Error guardando solicitudes peatones: $e');
    }
  }

  Future<void> _saveMessageHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(_messageHistory.map((m) => m.toJson()).toList());
      await prefs.setString(_messageHistoryKey, encoded);
    } catch (e) {
      debugPrint('❌ [PERSIST] Error guardando mensajes: $e');
    }
  }

  Future<void> clearAllData() async {
    _vehicleEntries.clear();
    _vehicleRequests.clear();
    _personEntries.clear();
    _personRequests.clear();
    _messageHistory.clear();
    _nodesWithUnread.clear();
    _channelsWithUnread.clear();
    _unreadChatCount = 0;
    _pendingDeliveries.clear();
    _processedPacketIds.clear();
    _processedPacketSet.clear();
    _sessionTracks.clear();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_vehicleEntriesKey);
      await prefs.remove(_vehicleRequestsKey);
      await prefs.remove(_personEntriesKey);
      await prefs.remove(_personRequestsKey);
      await prefs.remove(_messageHistoryKey);
    } catch (e) {
      debugPrint('❌ [PERSIST] Error borrando datos: $e');
    }

    debugPrint('🗑️ [PERSIST] Toda la data fue borrada');
    notifyListeners();
  }

  Future<bool> setLoraRegion(LoraRegion region) async {
    await saveLoraRegion(region);
    if (isConnected && _client != null) {
      try {
        final configMessage = 'CONFIG|LORA_REGION|${region.code}';
        await _client!.sendTextMessage(configMessage, channel: 0);
      } catch (e) {
        debugPrint('Aviso: No se pudo enviar región al dispositivo: $e');
      }
    }
    return true;
  }

  // ---------- Scan & Connect ----------

  Stream<ScannedDevice> scanDevices() async* {
    try {
      _updateStatus(ConnectionStatus.scanning, 'Buscando dispositivos...');
      await _ensureClientInitialized();

      await for (final device in _client!.scanForDevices()) {
        yield ScannedDevice(
          name: device.platformName,
          address: device.remoteId.toString(),
          rawDevice: device,
        );
      }
    } catch (e) {
      _updateStatus(ConnectionStatus.error, 'Error escaneando: ${e.toString()}');
    }
  }

  Future<void> connectToSavedDevice() async {
    if (_client != null &&
        (isConnected || _status == ConnectionStatus.connecting)) {
      debugPrint('✅ [SERVICE] Ya conectado/conectando, omitiendo reconexión');
      return;
    }

    final savedAddress = await getSavedDeviceAddress();
    final savedName = await getSavedDeviceName();
    if (savedAddress != null) {
      _connectedDeviceName = savedName;
      _connectedDeviceMac = savedAddress;
      await connectToDeviceByAddress(savedAddress);
    }
  }

  Future<void> connectToDeviceByAddress(String address) async {
    try {
      _updateStatus(ConnectionStatus.connecting, 'Conectando...');
      await _ensureClientInitialized();

      await _connectionSubscription?.cancel();
      await _packetSubscription?.cancel();

      _connectionSubscription = _client!.connectionStream.listen((status) {
        final stateStr = status.state.toString().toLowerCase();
        if (stateStr.contains('connected') && !stateStr.contains('dis')) {
          _updateStatus(ConnectionStatus.connected, 'Conectado');
          _autoReconnectEnabled = true;
          _startKeepalive();
          _applyInitialConfig();
        } else if (stateStr.contains('disconnect')) {
          _onUnexpectedDisconnect();
        }
      });

      _packetSubscription = _client!.packetStream.listen(
        _handlePacket,
        onError: (e) => debugPrint('❌ [PACKET_ERROR] $e'),
        onDone: () => debugPrint('⚠️ [PACKET_DONE] packetStream cerrado'),
      );

      await for (final device in _client!.scanForDevices()) {
        if (device.remoteId.toString() == address) {
          _connectedDeviceName = device.platformName;
          _connectedDeviceMac = address;
          _updateStatus(
            ConnectionStatus.connecting,
            'Conectando a ${device.platformName}...',
          );
          await _client!.connectToDevice(device);
          break;
        }
      }
    } catch (e) {
      _updateStatus(ConnectionStatus.error, 'Error: ${e.toString()}');
    }
  }

  Future<void> connectToDevice(ScannedDevice device) async {
    try {
      _updateStatus(
        ConnectionStatus.connecting,
        'Conectando a ${device.name}...',
      );
      await _ensureClientInitialized();

      await _connectionSubscription?.cancel();
      await _packetSubscription?.cancel();

      _connectionSubscription = _client!.connectionStream.listen((status) {
        final stateStr = status.state.toString().toLowerCase();
        if (stateStr.contains('connected') && !stateStr.contains('dis')) {
          _updateStatus(ConnectionStatus.connected, 'Conectado');
          _autoReconnectEnabled = true;
          _startKeepalive();
          _applyInitialConfig();
        } else if (stateStr.contains('disconnect')) {
          _onUnexpectedDisconnect();
        }
      });

      _packetSubscription = _client!.packetStream.listen(
        _handlePacket,
        onError: (e) => debugPrint('❌ [PACKET_ERROR] $e'),
        onDone: () => debugPrint('⚠️ [PACKET_DONE] packetStream cerrado'),
      );

      await _client!.connectToDevice(device.rawDevice);
      _connectedDeviceName = device.name;
      _connectedDeviceMac = device.address;
      await saveDeviceInfo(device.address, device.name);
    } catch (e) {
      _updateStatus(ConnectionStatus.error, 'Error: ${e.toString()}');
    }
  }

  Future<void> _applyInitialConfig() async {
    final savedRegion = await getSavedLoraRegion();
    if (savedRegion != LoraRegion.unset) {
      await setLoraRegion(savedRegion);
    }
  }

  void _startKeepalive() {
    _stopKeepalive();
    _keepaliveTimer = Timer.periodic(_keepaliveInterval, (_) async {
      if (isConnected && _client != null) {
        try {
          await _client!.keepAlive();
        } catch (e) {
          debugPrint('⚠️ [KEEPALIVE] Error: $e');
        }
      }
    });
    debugPrint(
        '💓 [KEEPALIVE] Timer iniciado (cada ${_keepaliveInterval.inSeconds}s)');
  }

  void _stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  void _onUnexpectedDisconnect() {
    _stopKeepalive();
    final wasConnected = _status == ConnectionStatus.connected;
    _updateStatus(ConnectionStatus.disconnected, 'Desconectado');
    if (wasConnected && _autoReconnectEnabled && !_isReconnecting) {
      _attemptReconnect();
    }
  }

  Future<void> _attemptReconnect() async {
    final savedAddress = await getSavedDeviceAddress();
    if (savedAddress == null || _isReconnecting) return;

    _isReconnecting = true;

    for (int attempt = 1; attempt <= _maxReconnectAttempts; attempt++) {
      if (!_autoReconnectEnabled) break;
      if (isConnected) break;

      debugPrint('🔄 [RECONNECT] Intento $attempt/$_maxReconnectAttempts...');
      _updateStatus(
        ConnectionStatus.connecting,
        'Reconectando ($attempt/$_maxReconnectAttempts)...',
      );

      try {
        await _connectionSubscription?.cancel();
        await _packetSubscription?.cancel();
        _client = null;

        await _ensureClientInitialized();

        _connectionSubscription = _client!.connectionStream.listen((status) {
          final stateStr = status.state.toString().toLowerCase();
          if (stateStr.contains('connected') && !stateStr.contains('dis')) {
            _updateStatus(ConnectionStatus.connected, 'Conectado');
            _isReconnecting = false;
            _startKeepalive();
            _applyInitialConfig();
          } else if (stateStr.contains('disconnect')) {
            _onUnexpectedDisconnect();
          }
        });

        _packetSubscription = _client!.packetStream.listen(
          _handlePacket,
          onError: (e) => debugPrint('❌ [PACKET_ERROR] $e'),
        );

        await for (final device in _client!.scanForDevices()) {
          if (device.remoteId.toString() == savedAddress) {
            await _client!.connectToDevice(device);
            debugPrint('✅ [RECONNECT] Reconectado exitosamente');
            _isReconnecting = false;
            return;
          }
        }
      } catch (e) {
        debugPrint('❌ [RECONNECT] Intento $attempt falló: $e');
      }

      if (attempt < _maxReconnectAttempts) {
        await Future.delayed(_reconnectDelay);
      }
    }

    _isReconnecting = false;
    if (!isConnected) {
      _updateStatus(ConnectionStatus.error, 'No se pudo reconectar');
    }
  }

  Future<void> disconnect() async {
    _autoReconnectEnabled = false;
    _stopKeepalive();
    try {
      await _connectionSubscription?.cancel();
      await _packetSubscription?.cancel();
      await _client?.disconnect();
      _client = null;
      _updateStatus(ConnectionStatus.disconnected, 'Desconectado');
    } catch (e) {
      _updateStatus(
        ConnectionStatus.error,
        'Error al desconectar: ${e.toString()}',
      );
    }
  }

  Future<void> disconnectAndClear() async {
    await disconnect();
    await clearSavedDevice();
  }

  // ---------- Chat ----------

  Future<bool> sendChatMessage(
    String text, {
    int? channel,
    int? destinationId,
  }) async {
    if (!isConnected || _client == null) return false;

    try {
      if (destinationId != null) {
        debugPrint(
          '📤 [SEND] DM → 0x${destinationId.toRadixString(16)}: "$text"',
        );
        await _client!.sendTextMessage(text, destinationId: destinationId);
      } else {
        debugPrint('📤 [SEND] CH ${channel ?? 0}: "$text"');
        await _client!.sendTextMessage(text, channel: channel ?? 0);
      }

      final isDM = destinationId != null;
      final myMessage = ChatMessage(
        messageText: text,
        fromNodeId: myNodeNum ?? 0,
        fromNodeName: _connectedDeviceName ?? 'Yo',
        timestamp: DateTime.now(),
        channel: channel ?? 0,
        toNodeId: destinationId,
        isDirectMessage: isDM,
        isMine: true,
        deliveryStatus: isDM ? DeliveryStatus.sending : DeliveryStatus.none,
      );
      _addMessageToHistory(myMessage);
      _messageController.add(myMessage);

      if (destinationId != null) {
        _pendingDeliveries.putIfAbsent(destinationId, () => []);
        _pendingDeliveries[destinationId]!.add(myMessage);
        _scheduleDeliveryTimeout(myMessage, destinationId);
      }

      return true;
    } catch (e, stackTrace) {
      debugPrint('❌ [SEND] Error: $e\n$stackTrace');
      return false;
    }
  }

  // ---------- Vehículos ----------

  /// Consulta al gateway si una placa está autorizada.
  /// Envía `CONSULTA|<requestId>|<cedula>|<placa>` y espera `RESPUESTA|...`.
  /// Resuelve con [PlateCheckStatus.timeout] si no llega respuesta en [timeout].
  Future<PlateCheckResult> checkPlateWithGateway({
    required String cedula,
    required String placa,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isConnected || _client == null) {
      return PlateCheckResult(
        status: PlateCheckStatus.error,
        note: 'Sin conexión al nodo',
      );
    }

    final requestId = _newRequestId();
    final completer = Completer<PlateCheckResult>();
    _pendingPlateChecks[requestId] = completer;

    final message = 'CONSULTA|$requestId|$cedula|$placa';
    debugPrint('🚗 [VEHICLE] CONSULTA → gateway: $message');
    final sent =
        await sendChatMessage(message, destinationId: currentGatewayNodeId);

    if (!sent) {
      _pendingPlateChecks.remove(requestId);
      return PlateCheckResult(
        status: PlateCheckStatus.error,
        note: 'No se pudo enviar al gateway',
      );
    }

    Future.delayed(timeout, () {
      final pending = _pendingPlateChecks.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        debugPrint('⏰ [VEHICLE] Timeout consulta $requestId');
        pending.complete(PlateCheckResult(status: PlateCheckStatus.timeout));
      }
    });

    return completer.future;
  }

  /// Sanitiza un texto para que no rompa el split por `|` del protocolo.
  /// Reemplaza pipes con `/` y recorta a 150 caracteres.
  static String _sanitizeComment(String? raw) {
    if (raw == null) return '';
    final cleaned = raw.replaceAll('|', '/').trim();
    return cleaned.length > 150 ? cleaned.substring(0, 150) : cleaned;
  }

  /// Empaca hasta 4 acompañantes como 8 partes intercaladas (cc1|nombre1|...).
  /// Si la lista tiene menos de 4, las posiciones sobrantes quedan vacías.
  static List<String> _packAcompanantes(List<Acompanante> list) {
    final out = <String>[];
    for (var i = 0; i < 4; i++) {
      if (i < list.length) {
        out.add(_sanitizeShort(list[i].cedula));
        out.add(_sanitizeShort(list[i].nombre ?? ''));
      } else {
        out.add('');
        out.add('');
      }
    }
    return out;
  }

  static String _sanitizeShort(String s) {
    final cleaned = s.replaceAll('|', '/').trim();
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }


  /// Solicita aprobación manual a un supervisor enviando
  /// `SOLICITUD_V|<cedula>|<placa>|<comment>|<a1>|<a2>|<a3>|<a4>` (CCs solamente).
  Future<bool> requestVehicleApproval({
    required String cedula,
    required String placa,
    required int supervisorNodeId,
    String? comment,
    List<String> acompananteCedulas = const [],
  }) async {
    final safeComment = _sanitizeComment(comment);
    final ccs = List<String>.generate(4, (i) {
      if (i < acompananteCedulas.length) {
        return _sanitizeShort(acompananteCedulas[i]);
      }
      return '';
    });
    final message =
        'SOLICITUD_V|$cedula|$placa|$safeComment|${ccs.join('|')}';
    debugPrint(
      '🚗 [VEHICLE] SOLICITUD_V → 0x${supervisorNodeId.toRadixString(16)}: $message',
    );
    return sendChatMessage(message, destinationId: supervisorNodeId);
  }

  /// Supervisor responde a una solicitud. Envía `<STATUS>|<supervisor>|<comment?>`
  /// al portero y marca el [request] como respondido localmente (fix bug:
  /// matchea por requestId, no por fromNodeId).
  Future<bool> respondToVehicleRequest({
    required VehicleRequest request,
    required String status, // APROBADO, NEGADO, PENDIENTE
    required String supervisorName,
    String? comment,
  }) async {
    if (!isConnected || _client == null) return false;

    final safeComment = _sanitizeComment(comment);
    final body = safeComment.isNotEmpty
        ? '$status|$supervisorName|$safeComment'
        : '$status|$supervisorName';

    debugPrint(
      '🚗 [VEHICLE] $status → 0x${request.fromNodeId.toRadixString(16)}: $body',
    );
    final sent = await sendChatMessage(body, destinationId: request.fromNodeId);
    if (!sent) return false;

    for (final r in _vehicleRequests) {
      if (r.requestId == request.requestId) {
        r.isResponded = true;
        r.responseStatus = status;
        r.supervisorName = supervisorName;
        r.comment = safeComment.isNotEmpty ? safeComment : null;
        break;
      }
    }
    await _saveVehicleRequests();
    notifyListeners();
    return true;
  }

  /// `ENTRADA_V|<cedula>|<placa>|<aprobadoPor>|<a1cc>|<a1nom>|<a2cc>|<a2nom>|<a3cc>|<a3nom>|<a4cc>|<a4nom>`
  Future<bool> sendEntryToGateway({
    required String cedula,
    required String placa,
    required String approvedBy,
    List<Acompanante> acompanantes = const [],
  }) async {
    final packed = _packAcompanantes(acompanantes);
    final message =
        'ENTRADA_V|$cedula|$placa|$approvedBy|${packed.join('|')}';
    debugPrint('🚗 [VEHICLE] ENTRADA_V → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  /// `REGISTRO_MANUAL|<status>|<cedula>|<placa>|<supervisor>|<comment>|<a1cc>|<a1nom>|...|<a4nom>`
  /// Usado cuando la aprobación vino del supervisor (no de la lista de Airtable).
  Future<bool> sendRegistroManualToGateway({
    required String status,
    required String cedula,
    required String placa,
    required String supervisor,
    String? comment,
    List<Acompanante> acompanantes = const [],
  }) async {
    final safeComment = _sanitizeComment(comment);
    final packed = _packAcompanantes(acompanantes);
    final message =
        'REGISTRO_MANUAL|$status|$cedula|$placa|$supervisor|$safeComment|${packed.join('|')}';
    debugPrint('🚗 [VEHICLE] REGISTRO_MANUAL → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  // ---------- Solicitudes de aprobación al gateway (visitante no registrado) ----------
  //
  // En vez de pedir aprobación a un nodo supervisor, el portero envía la
  // solicitud al gateway, que crea una fila PENDIENTE en la tabla maestra
  // (Placas / Personas / FinDeSemana). Alguien la aprueba luego en Airtable.

  /// `SOLICITUD_V|<cedula>|<placa>|<comment>` al gateway → fila PENDIENTE en Placas.
  Future<bool> sendSolicitudVehiculoToGateway({
    required String cedula,
    required String placa,
    String? comment,
  }) async {
    final safeComment = _sanitizeComment(comment);
    final message = 'SOLICITUD_V|$cedula|$placa|$safeComment';
    debugPrint('🚗 [VEHICLE] SOLICITUD_V → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  /// `SOLICITUD_P|<cedula>|<nombre>|<comment>` al gateway → fila PENDIENTE en Personas.
  Future<bool> sendSolicitudPersonaToGateway({
    required String cedula,
    String? nombre,
    String? comment,
  }) async {
    final safeNombre = _sanitizeShort(nombre ?? '');
    final safeComment = _sanitizeComment(comment);
    final message = 'SOLICITUD_P|$cedula|$safeNombre|$safeComment';
    debugPrint('🚶 [PERSON] SOLICITUD_P → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  /// `SOLICITUD_F|<cedula>|<comment>` al gateway → fila PENDIENTE en FinDeSemana.
  Future<bool> sendSolicitudFinDeSToGateway({
    required String cedula,
    String? comment,
  }) async {
    final safeComment = _sanitizeComment(comment);
    final message = 'SOLICITUD_F|$cedula|$safeComment';
    debugPrint('🗓️ [FINDES] SOLICITUD_F → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  // ---------- Peatones (paralelo a vehículos) ----------

  /// Consulta al gateway si una persona está autorizada.
  /// Envía `CONSULTA_P|<requestId>|<cedula>` y espera `RESPUESTA_P|...`.
  Future<PersonCheckResult> checkPersonWithGateway({
    required String cedula,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isConnected || _client == null) {
      return PersonCheckResult(
        status: PlateCheckStatus.error,
        note: 'Sin conexión al nodo',
      );
    }

    final requestId = _newRequestId();
    final completer = Completer<PersonCheckResult>();
    _pendingPersonChecks[requestId] = completer;

    final message = 'CONSULTA_P|$requestId|$cedula';
    debugPrint('🚶 [PERSON] CONSULTA_P → gateway: $message');
    final sent =
        await sendChatMessage(message, destinationId: currentGatewayNodeId);

    if (!sent) {
      _pendingPersonChecks.remove(requestId);
      return PersonCheckResult(
        status: PlateCheckStatus.error,
        note: 'No se pudo enviar al gateway',
      );
    }

    Future.delayed(timeout, () {
      final pending = _pendingPersonChecks.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        debugPrint('⏰ [PERSON] Timeout consulta $requestId');
        pending.complete(PersonCheckResult(status: PlateCheckStatus.timeout));
      }
    });

    return completer.future;
  }

  // ---------- Fin de Semana (paralelo a peatones, tabla aparte) ----------

  /// Consulta al gateway si una persona está en la lista de FinDeSemana.
  /// Envía `CONSULTA_F|<requestId>|<cedula>` y espera `RESPUESTA_F|...`.
  /// Reusa [PersonCheckResult] — el nombre y area vienen en la respuesta.
  Future<PersonCheckResult> checkFinDeSWithGateway({
    required String cedula,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isConnected || _client == null) {
      return PersonCheckResult(
        status: PlateCheckStatus.error,
        note: 'Sin conexión al nodo',
      );
    }

    final requestId = _newRequestId();
    final completer = Completer<PersonCheckResult>();
    _pendingPersonChecks[requestId] = completer;

    final message = 'CONSULTA_F|$requestId|$cedula';
    debugPrint('🗓️ [FINDES] CONSULTA_F → gateway: $message');
    final sent =
        await sendChatMessage(message, destinationId: currentGatewayNodeId);

    if (!sent) {
      _pendingPersonChecks.remove(requestId);
      return PersonCheckResult(
        status: PlateCheckStatus.error,
        note: 'No se pudo enviar al gateway',
      );
    }

    Future.delayed(timeout, () {
      final pending = _pendingPersonChecks.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        debugPrint('⏰ [FINDES] Timeout consulta $requestId');
        pending.complete(PersonCheckResult(status: PlateCheckStatus.timeout));
      }
    });

    return completer.future;
  }

  /// `SOLICITUD_F|<cedula>|<comment>` al supervisor.
  Future<bool> requestFinDeSApproval({
    required String cedula,
    required int supervisorNodeId,
    String? comment,
  }) async {
    final safeComment = _sanitizeComment(comment);
    final message = 'SOLICITUD_F|$cedula|$safeComment';
    debugPrint(
      '🗓️ [FINDES] SOLICITUD_F → 0x${supervisorNodeId.toRadixString(16)}: $message',
    );
    return sendChatMessage(message, destinationId: supervisorNodeId);
  }

  /// Supervisor responde a una solicitud fin de semana.
  /// Envía `<STATUS>_F|<supervisor>|<comment>` al portero.
  Future<bool> respondToFinDeSRequest({
    required PersonRequest request,
    required String status,
    required String supervisorName,
    String? comment,
  }) async {
    if (!isConnected || _client == null) return false;

    final safeComment = _sanitizeComment(comment);
    final body = safeComment.isNotEmpty
        ? '${status}_F|$supervisorName|$safeComment'
        : '${status}_F|$supervisorName';

    debugPrint(
      '🗓️ [FINDES] ${status}_F → 0x${request.fromNodeId.toRadixString(16)}: $body',
    );
    final sent = await sendChatMessage(body, destinationId: request.fromNodeId);
    if (!sent) return false;

    for (final r in _personRequests) {
      if (r.requestId == request.requestId) {
        r.isResponded = true;
        r.responseStatus = status;
        r.supervisorName = supervisorName;
        r.comment = safeComment.isNotEmpty ? safeComment : null;
        break;
      }
    }
    await _savePersonRequests();
    notifyListeners();
    return true;
  }

  void addFinDeSEntry({
    required String cedula,
    required String nombre,
    required String approvedBy,
  }) {
    _personEntries.add(PersonEntry(
      cedula: cedula,
      nombre: nombre,
      entryTime: DateTime.now(),
      approvedBy: approvedBy,
      categoria: 'FIN_DE_SEMANA',
    ));
    debugPrint('🗓️ [FINDES] Entrada: $nombre ($cedula)');
    _savePersonEntries();
    notifyListeners();
  }

  /// `ENTRADA_F|<cedula>|<aprobadoPor>` al gateway.
  Future<bool> sendFinDeSEntryToGateway({
    required String cedula,
    required String approvedBy,
  }) async {
    final message = 'ENTRADA_F|$cedula|$approvedBy';
    debugPrint('🗓️ [FINDES] ENTRADA_F → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  /// `SALIDA_F|<cedula>` al gateway.
  Future<bool> sendFinDeSExitToGateway({required String cedula}) async {
    final message = 'SALIDA_F|$cedula';
    debugPrint('🗓️ [FINDES] SALIDA_F → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  /// `REGISTRO_MANUAL_F|<status>|<cedula>|<supervisor>|<comment>` al gateway.
  Future<bool> sendRegistroManualFinDeSToGateway({
    required String status,
    required String cedula,
    required String supervisor,
    String? comment,
  }) async {
    final message =
        'REGISTRO_MANUAL_F|$status|$cedula|$supervisor|${comment ?? ''}';
    debugPrint('🗓️ [FINDES] REGISTRO_MANUAL_F → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  // ---------- Peatones (paralelo a vehículos) ----------

  /// `SOLICITUD_P|<cedula>|<comment>` como DM al supervisor.
  /// El comment es opcional pero útil para que el supervisor entienda el contexto.
  Future<bool> requestPersonApproval({
    required String cedula,
    required int supervisorNodeId,
    String? comment,
  }) async {
    final safeComment = _sanitizeComment(comment);
    final message = 'SOLICITUD_P|$cedula|$safeComment';
    debugPrint(
      '🚶 [PERSON] SOLICITUD_P → 0x${supervisorNodeId.toRadixString(16)}: $message',
    );
    return sendChatMessage(message, destinationId: supervisorNodeId);
  }

  /// Supervisor responde a una solicitud de peatón.
  Future<bool> respondToPersonRequest({
    required PersonRequest request,
    required String status, // APROBADO, NEGADO, PENDIENTE
    required String supervisorName,
    String? comment,
  }) async {
    if (!isConnected || _client == null) return false;

    final safeComment = _sanitizeComment(comment);
    // Sufijo _P para distinguir de respuestas de vehículos.
    final body = safeComment.isNotEmpty
        ? '${status}_P|$supervisorName|$safeComment'
        : '${status}_P|$supervisorName';

    debugPrint(
      '🚶 [PERSON] ${status}_P → 0x${request.fromNodeId.toRadixString(16)}: $body',
    );
    final sent = await sendChatMessage(body, destinationId: request.fromNodeId);
    if (!sent) return false;

    for (final r in _personRequests) {
      if (r.requestId == request.requestId) {
        r.isResponded = true;
        r.responseStatus = status;
        r.supervisorName = supervisorName;
        r.comment = safeComment.isNotEmpty ? safeComment : null;
        break;
      }
    }
    await _savePersonRequests();
    notifyListeners();
    return true;
  }

  void addPersonEntry({
    required String cedula,
    required String nombre,
    required String approvedBy,
  }) {
    _personEntries.add(PersonEntry(
      cedula: cedula,
      nombre: nombre,
      entryTime: DateTime.now(),
      approvedBy: approvedBy,
    ));
    debugPrint('🚶 [PERSON] Entrada: $nombre ($cedula)');
    _savePersonEntries();
    notifyListeners();
  }

  void markPersonExited(String cedula) {
    for (final entry in _personEntries) {
      if (entry.cedula == cedula && !entry.hasExited) {
        entry.exitTime = DateTime.now();
        debugPrint('🚶 [PERSON] Salida: $cedula');
        _savePersonEntries();
        notifyListeners();
        return;
      }
    }
  }

  /// `ENTRADA_P|<cedula>|<aprobadoPor>` al gateway.
  Future<bool> sendPersonEntryToGateway({
    required String cedula,
    required String approvedBy,
  }) async {
    final message = 'ENTRADA_P|$cedula|$approvedBy';
    debugPrint('🚶 [PERSON] ENTRADA_P → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  /// `SALIDA_P|<cedula>` al gateway.
  Future<bool> sendPersonExitToGateway({required String cedula}) async {
    final message = 'SALIDA_P|$cedula';
    debugPrint('🚶 [PERSON] SALIDA_P → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  /// `REGISTRO_MANUAL_P|<status>|<cedula>|<supervisor>|<comment>` al gateway.
  Future<bool> sendRegistroManualPersonToGateway({
    required String status,
    required String cedula,
    required String supervisor,
    String? comment,
  }) async {
    final message =
        'REGISTRO_MANUAL_P|$status|$cedula|$supervisor|${comment ?? ''}';
    debugPrint('🚶 [PERSON] REGISTRO_MANUAL_P → gateway: $message');
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  /// Registra entrada en el estado local (y dispara envío al gateway).
  void addVehicleEntry({
    required String cedula,
    required String placa,
    required String approvedBy,
    List<Acompanante> acompanantes = const [],
  }) {
    _vehicleEntries.add(VehicleEntry(
      cedula: cedula,
      placa: placa,
      entryTime: DateTime.now(),
      approvedBy: approvedBy,
      acompanantes: acompanantes,
    ));
    debugPrint(
      '🚗 [VEHICLE] Entrada registrada: $placa ($cedula)'
      '${acompanantes.isNotEmpty ? " +${acompanantes.length} acompañantes" : ""}',
    );
    _saveVehicleEntries();
    notifyListeners();
  }

  void markVehicleExited(String placa) {
    for (final entry in _vehicleEntries) {
      if (entry.placa == placa && !entry.hasExited) {
        entry.exitTime = DateTime.now();
        debugPrint('🚪 [VEHICLE] Salida: $placa');
        _saveVehicleEntries();
        notifyListeners();
        return;
      }
    }
  }

  /// Envía `SALIDA_V|<placa>` al gateway. TODO Fase 3 (lógica completa).
  Future<bool> sendVehicleExitToGateway({required String placa}) async {
    final message = 'SALIDA_V|$placa';
    return sendChatMessage(message, destinationId: currentGatewayNodeId);
  }

  // ---------- Manejo de paquetes ----------

  void _handlePacket(dynamic packet) {
    try {
      final int packetId = packet.id as int? ?? 0;
      if (packetId != 0 && _processedPacketSet.contains(packetId)) {
        return;
      }

      final int fromNodeId = packet.from as int? ?? 0;
      final int? toNodeId = packet.to as int?;
      final int channel = packet.channel as int? ?? 0;
      final bool isDM =
          toNodeId != null && toNodeId != 0xFFFFFFFF && toNodeId != 0;

      // Actualizar nombres de nodo desde NodeInfo
      try {
        if (packet.isNodeInfo == true) {
          final nodes = _client?.nodes;
          if (nodes != null && nodes.containsKey(fromNodeId)) {
            final nodeInfo = nodes[fromNodeId];
            final nodeName =
                nodeInfo?.user?.longName ?? nodeInfo?.user?.shortName ?? '';
            if (nodeName.isNotEmpty) {
              _updateKnownNode(fromNodeId, nodeName);
            }
          }
        }
      } catch (_) {}

      try {
        if (packet.isPosition == true) {
          final decoded = packet.decoded;
          if (decoded != null) {
            final payload = decoded.payload;
            if (payload is List<int> && payload.isNotEmpty) {
              final pos = Position.fromBuffer(payload);
              if (pos.hasLatitudeI() && pos.hasLongitudeI()) {
                final lat = pos.latitudeI / 1e7;
                final lon = pos.longitudeI / 1e7;
                final alt = pos.hasAltitude() ? pos.altitude : null;
                debugPrint(
                  '🗺️ [POSITION] $fromNodeId → ($lat, $lon) alt=$alt',
                );
                _updateNodePosition(fromNodeId, lat, lon, alt);
              }
            }
          }
          _markPacketProcessed(packetId);
          return;
        }
      } catch (e) {
        debugPrint('⚠️ [POSITION] Error parsing: $e');
      }

      // Routing (ACK/NACK) → actualiza estado de entrega de DMs
      try {
        if ((packet.isRouting as bool? ?? false)) {
          _handleRoutingPacket(packet);
          _markPacketProcessed(packetId);
          return;
        }
      } catch (_) {}

      // Solo procesar paquetes de texto
      bool isTextMessage = false;
      try {
        isTextMessage = packet.isTextMessage as bool? ?? false;
      } catch (_) {}

      if (!isTextMessage) {
        bool hasPayload = false;
        try {
          final decoded = packet.decoded;
          hasPayload = decoded != null && decoded.payload != null;
        } catch (_) {}
        if (!hasPayload) return;
      }

      String? text;
      try {
        final decoded = packet.decoded;
        if (decoded != null) {
          final payload = decoded.payload;
          if (payload is List<int> && payload.isNotEmpty) {
            text = utf8.decode(payload, allowMalformed: true);
          }
        }
      } catch (_) {
        try {
          text = packet.textMessage as String?;
        } catch (_) {}
      }

      if (text == null || text.isEmpty) return;

      final String fromName = _getNodeName(fromNodeId);
      if (fromNodeId != 0) {
        _updateKnownNode(fromNodeId, fromName);
      }

      // ---------- Protocolo Guaicaramo ----------

      // RESPUESTA_F del gateway a una consulta de fin-de-semana.
      // Formato: RESPUESTA_F|reqId|APROBADO|nombre|area  o  RESPUESTA_F|reqId|NO_APROBADO
      if (text.startsWith('RESPUESTA_F|')) {
        final parts = text.split('|');
        if (parts.length >= 3) {
          final requestId = parts[1];
          final statusStr = parts[2];
          final completer = _pendingPersonChecks.remove(requestId);
          debugPrint(
            '🗓️ [FINDES] RESPUESTA_F $requestId → $statusStr',
          );
          if (completer != null && !completer.isCompleted) {
            PersonCheckResult result;
            switch (statusStr) {
              case 'APROBADO':
                result = PersonCheckResult(
                  status: PlateCheckStatus.approved,
                  personName: parts.length > 3 ? parts[3] : null,
                  area: parts.length > 4 ? parts[4] : null,
                );
                break;
              case 'NO_APROBADO':
                result =
                    PersonCheckResult(status: PlateCheckStatus.notApproved);
                break;
              case 'ERROR':
              default:
                result = PersonCheckResult(
                  status: PlateCheckStatus.error,
                  note: parts.length > 3 ? parts[3] : null,
                );
                break;
            }
            completer.complete(result);
          }
        }
        _markPacketProcessed(packetId);
        return;
      }

      // SOLICITUD_F — supervisor recibe pedido fin-de-semana.
      if (text.startsWith('SOLICITUD_F|')) {
        final parts = text.split('|');
        if (parts.length >= 2) {
          final porteroComment =
              parts.length >= 3 && parts[2].isNotEmpty ? parts[2] : null;
          final request = PersonRequest(
            requestId: DateTime.now().millisecondsSinceEpoch,
            cedula: parts[1],
            fromNodeId: fromNodeId,
            fromNodeName: fromName,
            timestamp: DateTime.now(),
            porteroComment: porteroComment,
          );
          debugPrint(
            '🗓️ [FINDES] SOLICITUD_F CC ${parts[1]} de $fromName'
            '${porteroComment != null ? " — \"$porteroComment\"" : ""}',
          );
          _personRequests.add(request);
          _personRequestController.add(request);
          _savePersonRequests();
          notifyListeners();
        }
        _markPacketProcessed(packetId);
        return;
      }

      // Respuestas del supervisor para fin-de-semana (sufijo _F).
      // Chequear ANTES de _P/sin sufijo.
      if (text.startsWith('APROBADO_F|') ||
          text.startsWith('NEGADO_F|') ||
          text.startsWith('PENDIENTE_F|')) {
        final parts = text.split('|');
        if (parts.length >= 2) {
          // Quitar sufijo _F.
          final rawStatus = parts[0].substring(0, parts[0].length - 2);
          final response = PersonResponse(
            status: rawStatus,
            supervisorName: parts[1],
            comment: parts.length > 2 ? parts[2] : null,
            fromNodeId: fromNodeId,
            timestamp: DateTime.now(),
          );
          debugPrint(
            '🗓️ [FINDES] Respuesta $rawStatus de ${parts[1]}',
          );
          _personResponseController.add(response);
        }
        _markPacketProcessed(packetId);
        return;
      }

      // RESPUESTA_P del gateway a una consulta de peatón.
      // Debe chequearse ANTES de RESPUESTA| (prefijos comparten texto).
      if (text.startsWith('RESPUESTA_P|')) {
        final parts = text.split('|');
        if (parts.length >= 3) {
          final requestId = parts[1];
          final statusStr = parts[2];
          final completer = _pendingPersonChecks.remove(requestId);
          debugPrint(
            '🚶 [PERSON] RESPUESTA_P $requestId → $statusStr (pendiente: ${completer != null})',
          );
          if (completer != null && !completer.isCompleted) {
            PersonCheckResult result;
            switch (statusStr) {
              case 'APROBADO':
                result = PersonCheckResult(
                  status: PlateCheckStatus.approved,
                  personName: parts.length > 3 ? parts[3] : null,
                );
                break;
              case 'NO_APROBADO':
                result =
                    PersonCheckResult(status: PlateCheckStatus.notApproved);
                break;
              case 'ERROR':
              default:
                result = PersonCheckResult(
                  status: PlateCheckStatus.error,
                  note: parts.length > 3 ? parts[3] : null,
                );
                break;
            }
            completer.complete(result);
          }
        }
        _markPacketProcessed(packetId);
        return;
      }

      // SOLICITUD_P — supervisor recibe pedido para peatón.
      // Formato nuevo: SOLICITUD_P|cedula|comment  (3 partes)
      // Formato viejo: SOLICITUD_P|cedula          (2 partes — sin comment)
      if (text.startsWith('SOLICITUD_P|')) {
        final parts = text.split('|');
        if (parts.length >= 2) {
          final porteroComment = parts.length >= 3 && parts[2].isNotEmpty
              ? parts[2]
              : null;
          final request = PersonRequest(
            requestId: DateTime.now().millisecondsSinceEpoch,
            cedula: parts[1],
            fromNodeId: fromNodeId,
            fromNodeName: fromName,
            timestamp: DateTime.now(),
            porteroComment: porteroComment,
          );
          debugPrint(
            '🚶 [PERSON] SOLICITUD_P CC ${parts[1]} de $fromName'
            '${porteroComment != null ? " — \"$porteroComment\"" : ""}',
          );
          _personRequests.add(request);
          _personRequestController.add(request);
          _savePersonRequests();
          notifyListeners();
        }
        _markPacketProcessed(packetId);
        return;
      }

      // Respuestas del supervisor para peatones (DM al portero).
      // Chequear ANTES de APROBADO|/NEGADO|/PENDIENTE| de vehículos.
      if (text.startsWith('APROBADO_P|') ||
          text.startsWith('NEGADO_P|') ||
          text.startsWith('PENDIENTE_P|')) {
        final parts = text.split('|');
        if (parts.length >= 2) {
          // Quitar sufijo _P para tener el status crudo.
          final rawStatus = parts[0].substring(0, parts[0].length - 2);
          final response = PersonResponse(
            status: rawStatus,
            supervisorName: parts[1],
            comment: parts.length > 2 ? parts[2] : null,
            fromNodeId: fromNodeId,
            timestamp: DateTime.now(),
          );
          debugPrint(
            '🚶 [PERSON] Respuesta $rawStatus de ${parts[1]}',
          );
          _personResponseController.add(response);
        }
        _markPacketProcessed(packetId);
        return;
      }

      // Items — respuestas del gateway.
      // ITEM_RESP|reqId|numero|status[|nombre|concepto|destino|autorizado_por|area]
      if (text.startsWith('ITEM_RESP|')) {
        _handleItemResp(text.split('|'));
        _markPacketProcessed(packetId);
        return;
      }
      // LIST_RESP|reqId|seq|total|numero|nombre|concepto|destino|autorizado_por|area
      if (text.startsWith('LIST_RESP|')) {
        _handleListResp(text.split('|'));
        _markPacketProcessed(packetId);
        return;
      }
      // SALIDA_ITEM_OK|numero
      if (text.startsWith('SALIDA_ITEM_OK|')) {
        _handleSalidaItemOk(text.split('|'));
        _markPacketProcessed(packetId);
        return;
      }

      // RESPUESTA del gateway a una consulta de placa.
      if (text.startsWith('RESPUESTA|')) {
        final parts = text.split('|');
        if (parts.length >= 3) {
          final requestId = parts[1];
          final statusStr = parts[2];
          final completer = _pendingPlateChecks.remove(requestId);
          debugPrint(
            '🚗 [VEHICLE] RESPUESTA $requestId → $statusStr (pendiente: ${completer != null})',
          );
          if (completer != null && !completer.isCompleted) {
            PlateCheckResult result;
            switch (statusStr) {
              case 'APROBADO':
                result = PlateCheckResult(
                  status: PlateCheckStatus.approved,
                  driverName: parts.length > 3 ? parts[3] : null,
                );
                break;
              case 'NO_APROBADO':
                result =
                    PlateCheckResult(status: PlateCheckStatus.notApproved);
                break;
              case 'ERROR':
              default:
                result = PlateCheckResult(
                  status: PlateCheckStatus.error,
                  note: parts.length > 3 ? parts[3] : null,
                );
                break;
            }
            completer.complete(result);
          }
        }
        _markPacketProcessed(packetId);
        return;
      }

      // SOLICITUD_V — supervisor recibe pedido de aprobación manual.
      // Formato actual: SOLICITUD_V|cedula|placa|comment|a1cc|a2cc|a3cc|a4cc  (8 partes)
      // Formato anterior: SOLICITUD_V|cedula|placa|comment                   (4 partes)
      // Formato original: SOLICITUD_V|cedula|placa                           (3 partes)
      // El parser tolera todos para no romper celulares en versiones viejas.
      if (text.startsWith('SOLICITUD_V|')) {
        final parts = text.split('|');
        if (parts.length >= 3) {
          final porteroComment = parts.length >= 4 && parts[3].isNotEmpty
              ? parts[3]
              : null;
          final acompCedulas = <String>[];
          for (var i = 4; i < parts.length && i < 8; i++) {
            final cc = parts[i].trim();
            if (cc.isNotEmpty) acompCedulas.add(cc);
          }
          final request = VehicleRequest(
            requestId: DateTime.now().millisecondsSinceEpoch,
            cedula: parts[1],
            placa: parts[2],
            fromNodeId: fromNodeId,
            fromNodeName: fromName,
            timestamp: DateTime.now(),
            porteroComment: porteroComment,
            acompananteCedulas: acompCedulas,
          );
          debugPrint(
            '🚗 [VEHICLE] SOLICITUD_V recibida: ${parts[2]} (CC ${parts[1]}) de $fromName'
            '${porteroComment != null ? " — \"$porteroComment\"" : ""}'
            '${acompCedulas.isNotEmpty ? " +${acompCedulas.length} acomp" : ""}',
          );
          _vehicleRequests.add(request);
          _vehicleRequestController.add(request);
          _saveVehicleRequests();
          notifyListeners();
        }
        _markPacketProcessed(packetId);
        return;
      }

      // Respuestas del supervisor (DM al portero).
      if (text.startsWith('APROBADO|') ||
          text.startsWith('NEGADO|') ||
          text.startsWith('PENDIENTE|')) {
        final parts = text.split('|');
        if (parts.length >= 2) {
          final response = VehicleResponse(
            status: parts[0],
            supervisorName: parts[1],
            comment: parts.length > 2 ? parts[2] : null,
            fromNodeId: fromNodeId,
            timestamp: DateTime.now(),
          );
          debugPrint(
            '🚗 [VEHICLE] Respuesta ${parts[0]} de ${parts[1]}',
          );
          _vehicleResponseController.add(response);
        }
        _markPacketProcessed(packetId);
        return;
      }

      // ---------- Mensaje normal de chat ----------
      final chatMessage = ChatMessage(
        messageText: text,
        fromNodeId: fromNodeId,
        fromNodeName: fromName,
        timestamp: DateTime.now(),
        channel: channel,
        toNodeId: toNodeId,
        isDirectMessage: isDM,
        isMine: false,
      );

      _addMessageToHistory(chatMessage);

      _unreadChatCount++;
      if (isDM) {
        _nodesWithUnread.add(fromNodeId);
      } else {
        _channelsWithUnread.add(channel);
      }

      _messageController.add(chatMessage);
      _markPacketProcessed(packetId);
    } catch (e, stackTrace) {
      debugPrint('❌ [PACKET] Error: $e\n$stackTrace');
    }
  }

  /// Dedupe con cola FIFO real (fix bug sirius_porteria — Set.first no era FIFO).
  void _markPacketProcessed(int packetId) {
    if (packetId == 0) return;
    _processedPacketIds.add(packetId);
    _processedPacketSet.add(packetId);
    while (_processedPacketIds.length > _maxProcessedPacketIds) {
      final oldest = _processedPacketIds.removeFirst();
      _processedPacketSet.remove(oldest);
    }
  }

  void _scheduleDeliveryTimeout(ChatMessage message, int destinationId) {
    Future.delayed(const Duration(seconds: _deliveryTimeoutSeconds), () {
      if (message.deliveryStatus == DeliveryStatus.sending) {
        message.deliveryStatus = DeliveryStatus.failed;
        _pendingDeliveries[destinationId]?.remove(message);
        debugPrint('⏰ [DELIVERY] Timeout → nodo $destinationId');
        notifyListeners();
      }
    });
  }

  void _handleRoutingPacket(dynamic packet) {
    try {
      final int fromNodeId = packet.from as int? ?? 0;
      final decoded = packet.decoded;
      if (decoded == null) return;

      final payload = decoded.payload;
      if (payload == null || payload is! List<int> || payload.isEmpty) return;

      final routing = Routing.fromBuffer(payload);
      if (routing.hasErrorReason()) {
        final error = routing.errorReason;
        if (error == Routing_Error.NONE) {
          _updateDeliveryStatus(fromNodeId, DeliveryStatus.delivered);
        } else {
          debugPrint('❌ [ROUTING] Error: $error');
          _updateDeliveryStatus(fromNodeId, DeliveryStatus.failed);
        }
      }
    } catch (e) {
      debugPrint('⚠️ [ROUTING] $e');
    }
  }

  void _updateDeliveryStatus(int nodeId, DeliveryStatus status) {
    final pending = _pendingDeliveries[nodeId];
    if (pending != null && pending.isNotEmpty) {
      final message = pending.removeAt(0);
      message.deliveryStatus = status;
      debugPrint('📨 [DELIVERY] Nodo $nodeId → $status');
      notifyListeners();
    }
  }

  void _addMessageToHistory(ChatMessage message) {
    if (_messageHistory.any((m) => m.id == message.id)) return;
    _messageHistory.add(message);
    while (_messageHistory.length > _maxMessageHistory) {
      _messageHistory.removeAt(0);
    }
    _saveMessageHistory();
    notifyListeners();
  }

  int? _getNodeBatteryLevel(int nodeId) {
    try {
      return _client?.nodes[nodeId]?.batteryLevel;
    } catch (_) {
      return null;
    }
  }

  double? _getNodeVoltage(int nodeId) {
    try {
      return _client?.nodes[nodeId]?.voltage;
    } catch (_) {
      return null;
    }
  }

  int? get connectedNodeBatteryLevel {
    final myNum = myNodeNum;
    if (myNum == null) return null;
    return _getNodeBatteryLevel(myNum);
  }

  double? get connectedNodeVoltage {
    final myNum = myNodeNum;
    if (myNum == null) return null;
    return _getNodeVoltage(myNum);
  }

  void _updateKnownNode(int nodeId, String nodeName) {
    if (nodeId == 0) return;
    final existing = _knownNodes[nodeId];
    _knownNodes[nodeId] = MeshNode(
      nodeId: nodeId,
      nodeName: nodeName,
      isOnline: true,
      lastSeen: DateTime.now(),
      batteryLevel: _getNodeBatteryLevel(nodeId),
      voltage: _getNodeVoltage(nodeId),
      // Conservar posición GPS si ya la teníamos.
      latitude: existing?.latitude,
      longitude: existing?.longitude,
      altitude: existing?.altitude,
      positionTime: existing?.positionTime,
    );
    notifyListeners();
  }

  /// Actualiza la posición GPS de un nodo y añade un punto al track de sesión.
  /// Llamado desde [_handlePacket] cuando llega un Position packet.
  void _updateNodePosition(int nodeId, double lat, double lon, int? altitude) {
    if (nodeId == 0) return;
    final existing = _knownNodes[nodeId];
    final updated = MeshNode(
      nodeId: nodeId,
      nodeName: existing?.nodeName ?? '',
      isOnline: true,
      lastSeen: DateTime.now(),
      batteryLevel: existing?.batteryLevel,
      voltage: existing?.voltage,
      latitude: lat,
      longitude: lon,
      altitude: altitude,
      positionTime: DateTime.now(),
    );
    _knownNodes[nodeId] = updated;

    final track = _sessionTracks.putIfAbsent(nodeId, () => []);
    track.add(NodePositionPoint(lat, lon, DateTime.now()));
    while (track.length > _maxTrackPoints) {
      track.removeAt(0);
    }

    _nodePositionController.add(updated);
    notifyListeners();
  }

  void _updateStatus(ConnectionStatus status, String message) {
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  // ---------- Items: API pública ----------

  /// Consulta un item específico por número (como CONSULTA de placa).
  /// El gateway responde con ITEM_RESP que incluye status y datos del item
  /// si existen. Mucho más confiable sobre LoRa que la lista completa.
  Future<ItemCheckResult> consultItemWithGateway({
    required String numero,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isConnected || _client == null) {
      return ItemCheckResult(
        status: ItemCheckStatus.error,
        note: 'Sin conexión al nodo',
      );
    }

    final requestId = _newRequestId();
    final completer = Completer<ItemCheckResult>();
    _pendingItemChecks[requestId] = completer;

    final message = 'CONSULTA_ITEM|$requestId|$numero';
    debugPrint('📦 [ITEM] CONSULTA_ITEM → gateway: $message');
    final sent =
        await sendChatMessage(message, destinationId: currentGatewayNodeId);

    if (!sent) {
      _pendingItemChecks.remove(requestId);
      return ItemCheckResult(
        status: ItemCheckStatus.error,
        note: 'No se pudo enviar al gateway',
      );
    }

    Future.delayed(timeout, () {
      final pending = _pendingItemChecks.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        debugPrint('⏰ [ITEM] Timeout consulta $requestId');
        pending.complete(ItemCheckResult(status: ItemCheckStatus.timeout));
      }
    });

    return completer.future;
  }

  /// Pide al gateway la lista de items autorizados y no usados.
  /// El gateway responde con N mensajes LIST_RESP (uno por item).
  /// La UI escucha [itemsUpdatedStream] para repintar cada vez que llega
  /// uno nuevo.
  Future<bool> requestItemsList() async {
    if (!isConnected || _client == null) return false;
    final requestId = _newRequestId();
    _lastItemListRequestId = requestId;
    _lastItemListProgress = 0;
    _lastItemListTotal = -1;
    _pendingItemLists[requestId] = _ItemListInProgress();
    debugPrint('📦 [ITEM] LISTAR_ITEMS req=$requestId');
    final ok = await sendChatMessage(
      'LISTAR_ITEMS|$requestId',
      destinationId: currentGatewayNodeId,
    );
    if (!ok) {
      _pendingItemLists.remove(requestId);
    }
    notifyListeners();
    return ok;
  }

  /// Marca el item como salido. Envía SALIDA_ITEM al gateway.
  /// Actualiza local optimisticamente.
  Future<bool> registerItemExit(String numero) async {
    if (!isConnected || _client == null) return false;
    final item = _knownItems[numero];
    if (item != null) {
      item.usado = true;
      item.fechaSalida = DateTime.now();
      _saveItemsCache();
      notifyListeners();
      _itemsUpdatedController.add(null);
    }
    debugPrint('📦 [ITEM] SALIDA_ITEM numero=$numero');
    return sendChatMessage(
      'SALIDA_ITEM|$numero',
      destinationId: currentGatewayNodeId,
    );
  }

  // ---------- Items: parsers internos ----------

  /// Procesa un mensaje LIST_RESP recibido del gateway.
  /// Formato: LIST_RESP|reqId|seq|total|numero|nombre|concepto|destino|autorizado_por|area
  /// Si total=0, lista vacía (no items).
  void _handleListResp(List<String> parts) {
    if (parts.length < 4) return;
    final reqId = parts[1];
    final seq = int.tryParse(parts[2]) ?? 0;
    final total = int.tryParse(parts[3]) ?? 0;

    final progress = _pendingItemLists.putIfAbsent(
      reqId,
      _ItemListInProgress.new,
    );

    if (total == 0) {
      // Lista vacía: limpiar items pendientes (los que no fueron actualizados).
      debugPrint('📦 [ITEM] LIST_RESP req=$reqId total=0 (sin items)');
      _commitItemList(reqId, []);
      return;
    }

    if (parts.length < 5) return;
    final numero = parts[4];
    final nombre = parts.length > 5 ? parts[5] : '';
    final concepto = parts.length > 6 ? parts[6] : '';
    final destino = parts.length > 7 ? parts[7] : '';
    final autorizadoPor = parts.length > 8 ? parts[8] : '';
    final area = parts.length > 9 ? parts[9] : '';

    progress.total = total;
    progress.items[numero] = Item(
      numero: numero,
      nombre: nombre,
      concepto: concepto.isEmpty ? null : concepto,
      destino: destino.isEmpty ? null : destino,
      autorizadoPor: autorizadoPor.isEmpty ? null : autorizadoPor,
      area: area.isEmpty ? null : area,
      usado: false,
    );
    debugPrint(
      '📦 [ITEM] LIST_RESP req=$reqId seq=$seq/$total → $numero',
    );

    if (reqId == _lastItemListRequestId) {
      _lastItemListTotal = total;
      _lastItemListProgress = progress.items.length;
    }

    if (progress.items.length >= total) {
      _commitItemList(reqId, progress.items.values.toList());
    }
    _itemsUpdatedController.add(null);
    notifyListeners();
  }

  void _commitItemList(String reqId, List<Item> items) {
    _pendingItemLists.remove(reqId);
    // Reemplazo total: si el gateway no devuelve un item que antes teníamos,
    // asumimos que ya fue marcado usado o eliminado.
    _knownItems.clear();
    for (final item in items) {
      _knownItems[item.numero] = item;
    }
    if (reqId == _lastItemListRequestId) {
      _lastItemListProgress = items.length;
      _lastItemListTotal = items.length;
    }
    _saveItemsCache();
    debugPrint('📦 [ITEM] Lista completa: ${items.length} items');
    _itemsUpdatedController.add(null);
    notifyListeners();
  }

  /// Procesa ITEM_RESP del gateway en respuesta a CONSULTA_ITEM.
  /// Formato (los pipes son separadores literales):
  ///
  ///   `ITEM_RESP|reqId|numero|AUTORIZADO|nombre|concepto|destino|autorizado_por|area`
  ///   `ITEM_RESP|reqId|numero|YA_USADO|nombre|concepto|destino|autorizado_por|area`
  ///   `ITEM_RESP|reqId|numero|NO_AUTORIZADO`
  ///   `ITEM_RESP|reqId|numero|NO_EXISTE`
  ///   `ITEM_RESP|reqId|numero|ERROR|motivo`
  void _handleItemResp(List<String> parts) {
    if (parts.length < 4) return;
    final reqId = parts[1];
    final numero = parts[2];
    final status = parts[3];
    final completer = _pendingItemChecks.remove(reqId);
    debugPrint(
      '📦 [ITEM] ITEM_RESP $reqId numero=$numero → $status (pendiente: ${completer != null})',
    );
    if (completer == null || completer.isCompleted) return;

    ItemCheckResult result;
    switch (status) {
      case 'AUTORIZADO':
      case 'YA_USADO':
        final item = Item(
          numero: numero,
          nombre: parts.length > 4 ? parts[4] : '',
          concepto: parts.length > 5 && parts[5].isNotEmpty ? parts[5] : null,
          destino: parts.length > 6 && parts[6].isNotEmpty ? parts[6] : null,
          autorizadoPor:
              parts.length > 7 && parts[7].isNotEmpty ? parts[7] : null,
          area: parts.length > 8 && parts[8].isNotEmpty ? parts[8] : null,
          usado: status == 'YA_USADO',
        );
        // Cache local para que reaparezca en "Salidas recientes" si aplica.
        _knownItems[numero] = item;
        _saveItemsCache();
        result = ItemCheckResult(
          status: status == 'AUTORIZADO'
              ? ItemCheckStatus.authorized
              : ItemCheckStatus.alreadyUsed,
          item: item,
        );
        break;
      case 'NO_AUTORIZADO':
        result = ItemCheckResult(status: ItemCheckStatus.notAuthorized);
        break;
      case 'NO_EXISTE':
        result = ItemCheckResult(status: ItemCheckStatus.notFound);
        break;
      case 'ERROR':
      default:
        result = ItemCheckResult(
          status: ItemCheckStatus.error,
          note: parts.length > 4 ? parts[4] : null,
        );
        break;
    }
    completer.complete(result);
    _itemsUpdatedController.add(null);
    notifyListeners();
  }

  void _handleSalidaItemOk(List<String> parts) {
    if (parts.length < 2) return;
    final numero = parts[1];
    final item = _knownItems[numero];
    if (item != null) {
      item.usado = true;
      item.fechaSalida ??= DateTime.now();
      _saveItemsCache();
      _itemsUpdatedController.add(null);
      notifyListeners();
    }
    debugPrint('📦 [ITEM] SALIDA_ITEM_OK $numero');
  }

  Future<void> _saveItemsCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(_knownItems.values.map((i) => i.toJson()).toList());
      await prefs.setString(_itemsCacheKey, encoded);
    } catch (e) {
      debugPrint('❌ [PERSIST] Error guardando items: $e');
    }
  }

  @override
  void dispose() {
    _stopKeepalive();
    _connectionSubscription?.cancel();
    _packetSubscription?.cancel();
    _messageController.close();
    _vehicleRequestController.close();
    _vehicleResponseController.close();
    _personRequestController.close();
    _personResponseController.close();
    _nodePositionController.close();
    _itemsUpdatedController.close();
    _client?.disconnect();
    super.dispose();
  }
}

/// Helper interno: acumula los LIST_RESP de un requestId hasta tener todos.
class _ItemListInProgress {
  int total = -1;
  final Map<String, Item> items = {};
}
