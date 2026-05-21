import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../models/data_models.dart';
import '../services/meshtastic_service.dart';
import '../widgets/battery_indicator.dart';
import '../widgets/node_marker.dart';

/// Centro aproximado de la mesh de Guaicaramo (cluster real de nodos).
const _guaicaramoCenter = LatLng(4.466, -73.058);
const _initialZoom = 13.0;
const _minZoom = 6.0;
const _maxZoom = 19.0;

/// Tope de zoom de las MBTiles offline (las descargamos hasta 16).
const _offlineMaxNativeZoom = 16;

const _mbtilesAsset = 'assets/maps/guaicaramo.mbtiles';
const _mbtilesFilename = 'guaicaramo.mbtiles';

const _osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _userAgent = 'com.guaicaramo.guaicaramo_control';

class MapScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;
  final void Function(ChatDestination destination)? onOpenChat;

  const MapScreen({
    super.key,
    required this.meshtasticService,
    this.onOpenChat,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  StreamSubscription<MeshNode>? _positionSubscription;

  /// Ruta al MBTiles offline (si existe). Solo se usa cuando _useOffline=true.
  String? _mbtilesPath;
  bool _autoFollowMe = false;

  /// Default online OSM. El usuario puede cambiar al offline (MBTiles) con
  /// el botón del AppBar. Si no hay MBTiles disponible, el toggle queda
  /// deshabilitado.
  bool _useOffline = false;

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _positionSubscription =
        _service.nodePositionStream.listen(_onNodePosition);
    _initMbtiles();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    _positionSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) setState(() {});
  }

  void _onNodePosition(MeshNode node) {
    if (!mounted) return;
    if (_autoFollowMe && node.nodeId == _service.myNodeNum) {
      _mapController.move(
        LatLng(node.latitude!, node.longitude!),
        _mapController.camera.zoom,
      );
    }
    setState(() {});
  }

  /// Carga el MBTiles en background (no bloquea el render del mapa online).
  /// Si falla, _mbtilesPath queda en null y el toggle a offline queda
  /// deshabilitado.
  Future<void> _initMbtiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final destPath = '${dir.path}/$_mbtilesFilename';
      final destFile = File(destPath);

      if (!await destFile.exists()) {
        final data = await rootBundle.load(_mbtilesAsset);
        await destFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }

      if (!mounted) return;
      setState(() => _mbtilesPath = destPath);
      debugPrint('🗺️ [MAP] MBTiles offline disponible: $destPath');
    } catch (e) {
      debugPrint('🗺️ [MAP] MBTiles offline no disponible: $e');
      // No es error fatal — solo significa que no hay fallback offline.
    }
  }

  void _toggleOfflineMap() {
    if (_mbtilesPath == null && !_useOffline) {
      _showSnack('No hay mapa offline disponible.');
      return;
    }
    setState(() => _useOffline = !_useOffline);
    _showSnack(_useOffline ? 'Mapa offline (MBTiles).' : 'Mapa online (OSM).');
  }

  void _centerOnMyNode() {
    final myId = _service.myNodeNum;
    if (myId == null) {
      _showSnack('Aún no se conoce el nodo local');
      return;
    }
    final me = _service.nodesWithPosition.cast<MeshNode?>().firstWhere(
          (n) => n?.nodeId == myId,
          orElse: () => null,
        );
    if (me == null) {
      _showSnack('Tu nodo aún no ha reportado posición GPS');
      return;
    }
    _mapController.move(
      LatLng(me.latitude!, me.longitude!),
      _mapController.camera.zoom < 14 ? 14 : _mapController.camera.zoom,
    );
  }

  void _fitAllNodes() {
    final nodes = _service.nodesWithPosition;
    if (nodes.isEmpty) {
      _showSnack('Aún no hay nodos con posición GPS');
      return;
    }
    if (nodes.length == 1) {
      final n = nodes.first;
      _mapController.move(LatLng(n.latitude!, n.longitude!), 15);
      return;
    }
    final points =
        nodes.map((n) => LatLng(n.latitude!, n.longitude!)).toList();
    final bounds = LatLngBounds.fromPoints(points);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(48),
      ),
    );
  }

  void _toggleAutoFollow() {
    setState(() => _autoFollowMe = !_autoFollowMe);
    if (_autoFollowMe) _centerOnMyNode();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showNodeSheet(MeshNode node) {
    final isGateway = node.nodeId == _service.currentGatewayNodeId;
    final isMe = node.nodeId == _service.myNodeNum;

    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isGateway ? Icons.cell_tower : Icons.location_on,
                    color: isGateway ? Colors.teal : Colors.green,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          node.displayName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${node.shortId}'
                          '${isGateway ? " • Gateway" : ""}'
                          '${isMe ? " • Este dispositivo" : ""}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  BatteryIndicator(
                    batteryLevel: node.batteryLevel,
                    voltage: node.voltage,
                    iconSize: 22,
                  ),
                ],
              ),
              const Divider(height: 24),
              _sheetRow(
                icon: Icons.gps_fixed,
                label: 'Coordenadas',
                value:
                    '${node.latitude!.toStringAsFixed(5)}, ${node.longitude!.toStringAsFixed(5)}',
              ),
              if (node.altitude != null)
                _sheetRow(
                  icon: Icons.terrain,
                  label: 'Altitud',
                  value: '${node.altitude} m',
                ),
              if (node.positionTime != null)
                _sheetRow(
                  icon: Icons.update,
                  label: 'Última actualización',
                  value: _formatTimeAgo(node.positionTime!),
                ),
              const SizedBox(height: 16),
              if (!isMe)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onOpenChat
                          ?.call(ChatDestination.directMessage(node));
                    },
                    icon: const Icon(Icons.chat),
                    label: const Text('Enviar mensaje'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _sheetRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: Colors.grey.shade600)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  String _formatTimeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'hace ${diff.inSeconds}s';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'hace ${diff.inHours} h';
    return 'hace ${diff.inDays} d';
  }

  List<Marker> _buildMarkers() {
    final myId = _service.myNodeNum;
    return _service.nodesWithPosition.map((node) {
      final isGateway = node.nodeId == _service.currentGatewayNodeId;
      final isMe = myId != null && node.nodeId == myId;
      return Marker(
        point: LatLng(node.latitude!, node.longitude!),
        width: 140,
        height: 70,
        alignment: Alignment.topCenter,
        child: NodeMarker(
          node: node,
          isGateway: isGateway,
          isMe: isMe,
          onTap: () => _showNodeSheet(node),
        ),
      );
    }).toList();
  }

  List<Polyline> _buildTracks() {
    final polylines = <Polyline>[];
    for (final node in _service.nodesWithPosition) {
      final track = _service.getTrackFor(node.nodeId);
      if (track.length < 2) continue;
      polylines.add(
        Polyline(
          points: track.map((p) => LatLng(p.latitude, p.longitude)).toList(),
          color: node.nodeId == _service.currentGatewayNodeId
              ? Colors.teal.withValues(alpha: 0.6)
              : Colors.blueAccent.withValues(alpha: 0.6),
          strokeWidth: 3,
        ),
      );
    }
    return polylines;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mapa de nodos'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: _useOffline ? 'Cambiar a mapa online' : 'Cambiar a mapa offline',
            icon: Icon(
              _useOffline ? Icons.wifi_off : Icons.wifi,
              color: _useOffline ? Colors.orange : null,
            ),
            onPressed: _toggleOfflineMap,
          ),
          IconButton(
            tooltip: _autoFollowMe ? 'Detener seguimiento' : 'Seguir mi nodo',
            icon: Icon(
              _autoFollowMe ? Icons.gps_fixed : Icons.gps_not_fixed,
              color: _autoFollowMe ? Colors.green : null,
            ),
            onPressed: _toggleAutoFollow,
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: _guaicaramoCenter,
              initialZoom: _initialZoom,
              minZoom: _minZoom,
              maxZoom: _maxZoom,
              interactionOptions: InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              if (_useOffline && _mbtilesPath != null)
                TileLayer(
                  tileProvider:
                      MbTilesTileProvider.fromPath(path: _mbtilesPath!),
                  maxNativeZoom: _offlineMaxNativeZoom,
                )
              else
                TileLayer(
                  urlTemplate: _osmTileUrl,
                  userAgentPackageName: _userAgent,
                  maxNativeZoom: 19,
                ),
              PolylineLayer(polylines: _buildTracks()),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: Column(
                children: [
                  FloatingActionButton(
                    heroTag: 'fitAll',
                    mini: true,
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    tooltip: 'Ver todos los nodos',
                    onPressed: _fitAllNodes,
                    child: const Icon(Icons.fullscreen),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton(
                    heroTag: 'centerMe',
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                    tooltip: 'Centrar en mi nodo',
                    onPressed: _centerOnMyNode,
                    child: const Icon(Icons.my_location),
                  ),
                ],
              ),
            ),
          if (_service.nodesWithPosition.isEmpty)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Card(
                color: Colors.orange.shade50,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Aún no se han recibido posiciones GPS. Espera a que los nodos transmitan su ubicación.',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
