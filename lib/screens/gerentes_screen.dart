import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/gerentes_models.dart';
import '../services/gerentes_service.dart';
import '../widgets/campo_observacion.dart';
import '../widgets/clave_dialog.dart';

/// Pestaña Gerentes — ingreso y salida de Gerentes de Unidades Externas.
///
/// Independiente de la malla y del gateway. Funciona con o sin internet: busca
/// en la lista guardada en el teléfono y registra al instante con la hora
/// real. Los movimientos se suben solos a Airtable cuando hay conexión; el
/// panel superior muestra siempre cuántos faltan.
class GerentesScreen extends StatefulWidget {
  final GerentesService? service;

  const GerentesScreen({super.key, this.service});

  @override
  State<GerentesScreen> createState() => _GerentesScreenState();
}

class _GerentesScreenState extends State<GerentesScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  late final GerentesService _svc = widget.service ?? GerentesService.instance;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    _searchController.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _showSnack(String message, {Color? color}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  String get _sufijoSync => _svc.enLinea == true
      ? 'Subiendo a Airtable…'
      : 'Guardado en el teléfono; se subirá cuando haya internet.';

  // ---------- Acciones ----------

  Future<void> _abrirGerente(Gerente g) async {
    final abierta = _svc.visitaAbierta(g.recordId);
    if (abierta != null) {
      await _confirmarSalida(abierta);
      return;
    }
    final res = await showModalBottomSheet<_IngresoResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _IngresoSheet(gerente: g),
    );
    if (res == null || !mounted) return;

    if (res.soloSalida) {
      _svc.registrarSalidaSinIngreso(g, placa: res.placa, nota: res.nota);
      _showSnack('Salida de ${g.nombre} registrada. $_sufijoSync');
    } else {
      final v = _svc.registrarIngreso(g, placa: res.placa, nota: res.nota);
      if (v == null) {
        _showSnack('${g.nombre} ya figura dentro.', color: Colors.orange);
        return;
      }
      _showSnack('Ingreso de ${g.nombre} registrado. $_sufijoSync');
    }
    _searchController.clear();
    setState(() => _query = '');
  }

  Future<void> _confirmarSalida(GerenteVisita v) async {
    // null = canceló; '' = sin observación.
    final nota = await showDialog<String>(
      context: context,
      builder: (_) => _SalidaDialog(visita: v),
    );
    if (nota == null || !mounted) return;
    _svc.registrarSalida(v, nota: nota);
    _showSnack('Salida de ${v.nombre} registrada. $_sufijoSync');
  }

  void _sincronizarAhora() {
    _svc.sincronizar(manual: true, forzarLista: true);
  }

  Future<void> _abrirConfiguracion() async {
    await showDialog<void>(
      context: context,
      builder: (_) => ClaveDialog(
        titulo: 'Conexión a Airtable',
        descripcion: 'Token personal de Airtable con permisos data.records:read '
            'y data.records:write sobre la base Guaicaramo. Queda guardado solo '
            'en este teléfono.',
        hint: 'pat…',
        sufijoActual: () => _svc.tokenFinal,
        guardar: _svc.configurarToken,
        quitar: _svc.quitarToken,
        advertenciaQuitar: 'Los registros guardados se conservan, pero no se '
            'subirán a Airtable hasta configurar un token de nuevo.',
      ),
    );
  }

  // ---------- Formato ----------

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _fmtHora(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
  static String _fmtFecha(DateTime d) => '${_two(d.day)}/${_two(d.month)}';

  static String _fmtFechaHora(DateTime d) {
    final hoy = DateTime.now();
    final esHoy = d.year == hoy.year && d.month == hoy.month && d.day == hoy.day;
    return esHoy ? _fmtHora(d) : '${_fmtFecha(d)} ${_fmtHora(d)}';
  }

  static String _fmtDuracion(Duration d) {
    if (d.inMinutes < 1) return 'menos de 1 min';
    if (d.inHours < 1) return '${d.inMinutes} min';
    if (d.inDays >= 1) return '${d.inDays} d ${d.inHours % 24} h';
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} h' : '${d.inHours} h $m min';
  }

  static String _iniciales(String nombre) {
    final p = nombre.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    return p.take(2).map((s) => s[0]).join().toUpperCase();
  }

  // ---------- Panel de sincronización ----------

  Widget _buildSyncPanel() {
    final pendientes = _svc.pendientesSync;
    final enLinea = _svc.enLinea;
    final porSubir = '$pendientes por subir';

    IconData icon;
    Color color;
    String texto;
    Widget? accion;
    if (!_svc.configurado) {
      icon = Icons.key_off;
      color = Colors.red.shade700;
      texto = 'Falta configurar la conexión a Airtable';
      accion = TextButton(onPressed: _abrirConfiguracion, child: const Text('Configurar'));
    } else if (_svc.errorConfiguracion) {
      icon = Icons.error_outline;
      color = Colors.red.shade700;
      texto = _svc.error ?? 'Error de configuración';
      accion = TextButton(onPressed: _abrirConfiguracion, child: const Text('Revisar'));
    } else if (_svc.sincronizando) {
      icon = Icons.cloud_sync;
      color = Colors.blue.shade700;
      texto = pendientes > 0
          ? 'Sincronizando con Airtable… $porSubir'
          : 'Sincronizando con Airtable…';
    } else if (pendientes > 0 && enLinea == false) {
      icon = Icons.cloud_off;
      color = Colors.orange.shade800;
      texto = '$porSubir · sin internet. Se subirán solos al volver la conexión.';
    } else if (pendientes > 0) {
      icon = Icons.cloud_queue;
      color = Colors.orange.shade800;
      final prox = _svc.proximoIntento;
      texto = [
        porSubir,
        if (_svc.error != null) _svc.error!,
        if (prox != null) 'reintento ${_fmtHora(prox)}',
      ].join(' · ');
      accion = TextButton(onPressed: _sincronizarAhora, child: const Text('Reintentar'));
    } else if (enLinea == false) {
      icon = Icons.cloud_off;
      color = Colors.grey.shade700;
      texto = 'Sin internet · trabajando con los datos guardados';
    } else if (enLinea == true) {
      icon = Icons.cloud_done;
      color = Colors.green.shade700;
      final ult = _svc.ultimaConexion;
      texto = ult != null
          ? 'Todo al día con Airtable · ${_fmtHora(ult)}'
          : 'Todo al día con Airtable';
    } else {
      icon = Icons.cloud_outlined;
      color = Colors.grey.shade700;
      texto = 'Conectando con Airtable…';
    }

    final String listaTexto;
    Color listaColor = Colors.grey.shade700;
    final act = _svc.listaActualizada;
    if (act == null) {
      listaTexto = 'Sin lista de gerentes guardada en el teléfono';
      listaColor = Colors.red.shade700;
    } else {
      listaTexto = 'Lista: ${_svc.gerentes.length} gerentes · '
          'actualizada ${_fmtFecha(act)} ${_fmtHora(act)}';
      if (_svc.listaVieja) listaColor = Colors.orange.shade800;
    }

    return Material(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 2),
        child: Column(
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    texto,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_svc.sincronizando)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ?accion,
              ],
            ),
            Row(
              children: [
                Icon(Icons.people_alt_outlined, size: 20, color: listaColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    listaTexto,
                    style: TextStyle(fontSize: 13, color: listaColor),
                  ),
                ),
                IconButton(
                  tooltip: 'Sincronizar ahora',
                  onPressed: _svc.configurado && !_svc.sincronizando
                      ? _sincronizarAhora
                      : null,
                  icon: const Icon(Icons.sync),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Pestaña Registrar ----------

  Widget _buildRegistrar() {
    final todos = _svc.gerentes;
    if (todos.isEmpty) {
      if (!_svc.configurado) {
        return _EmptyState(
          icon: Icons.key,
          titulo: 'Configure la conexión a Airtable',
          detalle: 'Se hace una sola vez por teléfono y con internet. Después '
              'puede registrar ingresos y salidas aunque no haya conexión.',
          accion: FilledButton.icon(
            onPressed: _abrirConfiguracion,
            icon: const Icon(Icons.key),
            label: const Text('Configurar'),
          ),
        );
      }
      if (_svc.sincronizando) {
        return const _EmptyState(
          icon: Icons.cloud_download_outlined,
          titulo: 'Descargando la lista de gerentes…',
          detalle: 'Quedará guardada en el teléfono para usarla sin internet.',
        );
      }
      return _EmptyState(
        icon: Icons.cloud_off,
        titulo: 'No hay gerentes guardados',
        detalle: _svc.error ??
            'Conéctese a WiFi o datos una vez para descargar la lista. '
                'Después funciona sin conexión.',
        accion: FilledButton.icon(
          onPressed: _sincronizarAhora,
          icon: const Icon(Icons.download),
          label: const Text('Descargar lista'),
        ),
      );
    }

    final q = _query.trim().toLowerCase();
    final filtrados =
        q.isEmpty ? todos : todos.where((g) => g.searchText.contains(q)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _query = v),
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: 'Buscar por nombre, cédula, placa o empresa',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
        ),
        Expanded(
          child: filtrados.isEmpty
              ? _EmptyState(
                  icon: Icons.person_search,
                  titulo: 'Sin resultados para "$_query"',
                  detalle: 'Si es un gerente nuevo, sincronice con internet. '
                      'Si no aparece, llame a recepción.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: filtrados.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                  itemBuilder: (_, i) => _gerenteTile(filtrados[i]),
                ),
        ),
      ],
    );
  }

  Widget _gerenteTile(Gerente g) {
    final dentro = _svc.visitaAbierta(g.recordId) != null;
    final Color avatarColor = !g.autorizado
        ? Colors.red
        : dentro
            ? Colors.green
            : Colors.blueGrey;
    Widget trailing;
    if (dentro) {
      trailing = const _Etiqueta('DENTRO', Colors.green);
    } else if (!g.autorizado) {
      trailing = const _Etiqueta('NO AUTORIZADO', Colors.red);
    } else {
      trailing = Icon(Icons.login, color: Theme.of(context).colorScheme.primary);
    }
    return ListTile(
      onTap: () => _abrirGerente(g),
      leading: CircleAvatar(
        backgroundColor: avatarColor.withValues(alpha: 0.15),
        foregroundColor: avatarColor,
        child: Text(_iniciales(g.nombre)),
      ),
      title: Text(g.nombre, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${g.uea}\nCC ${g.cedula}'
        '${g.placas.isNotEmpty ? ' · ${g.placas.join(', ')}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: trailing,
    );
  }

  // ---------- Pestaña Dentro ----------

  Widget _buildDentro() {
    final dentro = _svc.dentro;
    if (dentro.isEmpty) {
      return const _EmptyState(
        icon: Icons.meeting_room_outlined,
        titulo: 'No hay gerentes dentro',
        detalle: 'Aquí aparecen los ingresos hasta su salida, incluidos los de '
            'otras porterías (cuando hay internet).',
      );
    }
    final ahora = DateTime.now();
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: dentro.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (_, i) {
        final v = dentro[i];
        final lleva = ahora.difference(v.ingreso!);
        return ListTile(
          title: Text(v.nombre, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (v.uea.isNotEmpty)
                Text(v.uea, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                'Desde ${_fmtFechaHora(v.ingreso!)} (${_fmtDuracion(lleva)})'
                '${v.placa.isNotEmpty ? ' · ${v.placa}' : ''}',
                style: lleva > const Duration(hours: 24)
                    ? TextStyle(color: Colors.orange.shade800)
                    : null,
              ),
              if (v.remota)
                Text('Registrado en otra portería',
                    style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade600)),
            ],
          ),
          leading: _SyncIcon(v.ingresoSync),
          trailing: FilledButton.tonalIcon(
            onPressed: () => _confirmarSalida(v),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Salida'),
          ),
        );
      },
    );
  }

  // ---------- Pestaña Historial ----------

  Widget _buildHistorial() {
    final hist = _svc.historial;
    if (hist.isEmpty) {
      return const _EmptyState(
        icon: Icons.history,
        titulo: 'Sin movimientos',
        detalle: 'Aquí verá cada ingreso y salida con su estado de sincronización.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: hist.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (_, i) {
        final v = hist[i];
        return ListTile(
          title: Text(v.nombre, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (v.uea.isNotEmpty)
                Text(v.uea, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              if (v.ingreso != null)
                _eventoRow(
                  v.remota ? 'Ingreso (otra portería)' : 'Ingreso',
                  v.ingreso!,
                  v.ingresoSync,
                  v.notaIngreso,
                ),
              if (v.salida != null)
                _eventoRow(
                  v.ingreso == null ? 'Salida (sin ingreso aquí)' : 'Salida',
                  v.salida!,
                  v.salidaSync ?? SyncState.pendiente,
                  v.notaSalida,
                ),
              if (v.placa.isNotEmpty) Text('Placa ${v.placa}'),
              if (v.aviso != null)
                Text(v.aviso!,
                    style: TextStyle(color: Colors.blueGrey.shade700, fontSize: 12)),
              if (v.ultimoError != null && (v.pendienteSync || v.rechazada))
                Text(
                  v.ultimoError!,
                  style: TextStyle(
                    color: v.rechazada ? Colors.red.shade700 : Colors.orange.shade800,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          trailing: v.rechazada
              ? IconButton(
                  tooltip: 'Descartar',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _svc.descartarRechazada(v),
                )
              : null,
        );
      },
    );
  }

  Widget _eventoRow(String label, DateTime hora, SyncState sync, String? nota) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SyncIcon(sync, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$label ${_fmtFechaHora(hora)}${nota != null ? ' — $nota' : ''}',
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Build ----------

  Widget _buildInternetIcon() {
    final (IconData icon, Color color, String tip) = switch (_svc.enLinea) {
      true => (Icons.cloud_done, Colors.green, 'Con internet'),
      false => (Icons.cloud_off, Colors.orange.shade800, 'Sin internet'),
      null => (Icons.cloud_outlined, Colors.grey, 'Sin verificar'),
    };
    return Tooltip(message: tip, child: Icon(icon, color: color, size: 22));
  }

  @override
  Widget build(BuildContext context) {
    final nDentro = _svc.dentro.length;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Gerentes UEA'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          actions: [
            _buildInternetIcon(),
            PopupMenuButton<void Function()>(
              tooltip: 'Configuración',
              icon: const Icon(Icons.settings),
              onSelected: (accion) => accion(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _abrirConfiguracion,
                  child: const ListTile(
                    leading: Icon(Icons.key),
                    title: Text('Conexión a Airtable'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: () => mostrarClaveOpenAI(context),
                  child: const ListTile(
                    leading: Icon(Icons.mic),
                    title: Text('Dictado por voz (OpenAI)'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(text: 'Registrar'),
              Tab(text: nDentro > 0 ? 'Dentro ($nDentro)' : 'Dentro'),
              const Tab(text: 'Historial'),
            ],
          ),
        ),
        body: Column(
          children: [
            _buildSyncPanel(),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  _buildRegistrar(),
                  _buildDentro(),
                  _buildHistorial(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Diálogo de salida
// ============================================================================

/// Confirma la salida. Devuelve la observación ('' si no hay) o null si se
/// canceló. Tiene su propio controlador: así no se destruye mientras el
/// diálogo todavía se está cerrando.
class _SalidaDialog extends StatefulWidget {
  final GerenteVisita visita;

  const _SalidaDialog({required this.visita});

  @override
  State<_SalidaDialog> createState() => _SalidaDialogState();
}

class _SalidaDialogState extends State<_SalidaDialog> {
  final _notaCtrl = TextEditingController();
  bool _dictando = false;

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.visita;
    return AlertDialog(
      title: const Text('Registrar salida'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(v.nombre,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            if (v.uea.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(v.uea, style: TextStyle(color: Colors.grey.shade700)),
            ],
            const SizedBox(height: 4),
            Text(
              'Ingresó ${_GerentesScreenState._fmtFechaHora(v.ingreso!)}'
              '${v.placa.isNotEmpty ? ' · ${v.placa}' : ' · sin vehículo'}'
              ' · lleva ${_GerentesScreenState._fmtDuracion(DateTime.now().difference(v.ingreso!))}',
            ),
            if (v.remota) ...[
              const SizedBox(height: 4),
              Text('Ingreso registrado en otra portería.',
                  style: TextStyle(color: Colors.blueGrey.shade700)),
            ],
            const SizedBox(height: 12),
            CampoObservacion(
              controller: _notaCtrl,
              maxLength: GerentesService.maxNota,
              onOcupado: (ocupado) => setState(() => _dictando = ocupado),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: _dictando ? null : () => Navigator.of(context).pop(_notaCtrl.text),
          icon: const Icon(Icons.logout),
          label: const Text('Registrar salida'),
        ),
      ],
    );
  }
}


// ============================================================================
// Hoja de ingreso
// ============================================================================

class _IngresoResult {
  final String placa;
  final String? nota;
  final bool soloSalida;

  const _IngresoResult({required this.placa, this.nota, this.soloSalida = false});
}

class _IngresoSheet extends StatefulWidget {
  final Gerente gerente;

  const _IngresoSheet({required this.gerente});

  @override
  State<_IngresoSheet> createState() => _IngresoSheetState();
}

class _IngresoSheetState extends State<_IngresoSheet> {
  static const String _otra = '__otra__';
  static const String _sinVehiculo = '';

  late String _placaSel;
  final _otraCtrl = TextEditingController();
  final _notaCtrl = TextEditingController();

  /// Hay un dictado en curso: no se puede registrar hasta que termine.
  bool _dictando = false;

  Gerente get _g => widget.gerente;

  @override
  void initState() {
    super.initState();
    _placaSel = _g.placas.isNotEmpty ? _g.placas.first : _sinVehiculo;
  }

  @override
  void dispose() {
    _otraCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  String get _placa => _placaSel == _otra ? _otraCtrl.text.trim() : _placaSel;

  bool get _placaValida => _placaSel != _otra || _placa.length >= 5;

  bool get _puedeRegistrar => _placaValida && !_dictando;

  void _pop({bool soloSalida = false}) {
    Navigator.of(context).pop(_IngresoResult(
      placa: _placa,
      nota: _notaCtrl.text,
      soloSalida: soloSalida,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_g.nombre,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(_g.uea, style: TextStyle(color: Colors.grey.shade700)),
            Text('CC ${_g.cedula}', style: TextStyle(color: Colors.grey.shade700)),
            const SizedBox(height: 16),
            if (!_g.autorizado) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  border: Border.all(color: Colors.red.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.block, color: Colors.red.shade700),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Este gerente NO está autorizado para ingresar. '
                        'No registre el ingreso; llame a recepción.',
                        style: TextStyle(color: Colors.red.shade900),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _pop(soloSalida: true),
                icon: const Icon(Icons.logout),
                label: const Text('Solo registrar su salida'),
              ),
            ] else ...[
              const Text('Vehículo', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final p in _g.placas)
                    ChoiceChip(
                      label: Text(p),
                      selected: _placaSel == p,
                      onSelected: (_) => setState(() => _placaSel = p),
                    ),
                  ChoiceChip(
                    label: const Text('Otra placa'),
                    selected: _placaSel == _otra,
                    onSelected: (_) => setState(() => _placaSel = _otra),
                  ),
                  ChoiceChip(
                    label: const Text('Sin vehículo'),
                    selected: _placaSel == _sinVehiculo,
                    onSelected: (_) => setState(() => _placaSel = _sinVehiculo),
                  ),
                ],
              ),
              if (_placaSel == _otra) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _otraCtrl,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(8),
                  ],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Placa',
                    hintText: 'Ej: ABC123',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              CampoObservacion(
                controller: _notaCtrl,
                maxLength: GerentesService.maxNota,
                onOcupado: (ocupado) => setState(() => _dictando = ocupado),
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: _puedeRegistrar ? () => _pop() : null,
                icon: const Icon(Icons.login),
                label: const Text('Registrar ingreso'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _puedeRegistrar ? () => _pop(soloSalida: true) : null,
                child: const Text('Ya estaba dentro: solo registrar salida'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Widgets auxiliares
// ============================================================================

class _SyncIcon extends StatelessWidget {
  final SyncState state;
  final double size;

  const _SyncIcon(this.state, {this.size = 24});

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color, String tip) = switch (state) {
      SyncState.pendiente => (
          Icons.cloud_upload_outlined,
          Colors.orange.shade800,
          'Pendiente de subir a Airtable'
        ),
      SyncState.sincronizado => (
          Icons.cloud_done,
          Colors.green.shade700,
          'Guardado en Airtable'
        ),
      SyncState.rechazado => (
          Icons.error_outline,
          Colors.red.shade700,
          'Rechazado por Airtable'
        ),
    };
    return Tooltip(message: tip, child: Icon(icon, color: color, size: size));
  }
}

class _Etiqueta extends StatelessWidget {
  final String texto;
  final Color color;

  const _Etiqueta(this.texto, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        texto,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String titulo;
  final String detalle;
  final Widget? accion;

  const _EmptyState({
    required this.icon,
    required this.titulo,
    required this.detalle,
    this.accion,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              detalle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700),
            ),
            if (accion != null) ...[const SizedBox(height: 16), accion!],
          ],
        ),
      ),
    );
  }
}
