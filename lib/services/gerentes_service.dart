import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/gerentes_models.dart';
import 'consulta_airtable.dart';
import 'gerentes_airtable.dart';

const String _tokenKey = 'gerentes_airtable_token';
const String _listaKey = 'gerentes_lista_v2';
const String _visitasKey = 'gerentes_visitas_v2';

/// Gerentes de Unidades Externas: ingreso y salida CON o SIN internet.
///
/// Independiente de la malla Meshtastic y del gateway: habla directo con
/// Airtable por HTTPS cuando el teléfono tiene internet (WiFi o datos).
///
/// - La lista de gerentes y el estado de quién está dentro quedan guardados en
///   el teléfono; sin internet el vigilante sigue trabajando con esa copia.
/// - Cada ingreso/salida se guarda al instante con su hora real y entra a una
///   cola que se sube sola, en orden, cuando vuelve la conexión.
/// - Reintentar nunca duplica: si un envío quedó sin respuesta, antes de
///   repetirlo se verifica en Airtable si ya se había guardado.
/// - Nada pendiente se borra: la cola sobrevive cierres de la app y reinicios.
class GerentesService extends ChangeNotifier with WidgetsBindingObserver {
  GerentesService({http.Client? httpClient, bool autoSync = true})
      : _httpClient = httpClient,
        _autoSync = autoSync {
    _cargado = _load();
    if (autoSync) {
      WidgetsBinding.instance.addObserver(this);
      _ticker = Timer.periodic(const Duration(seconds: 30), (_) => sincronizar());
      _cargado.then((_) => sincronizar());
    }
  }

  /// Instancia de la app (se crea al abrir la pestaña por primera vez).
  static final GerentesService instance = GerentesService();

  final http.Client? _httpClient;
  final bool _autoSync;
  late final Future<void> _cargado;
  Timer? _ticker;

  // ---------- Conexión a Airtable ----------

  String? _token;
  GerentesAirtable? _apiCache;

  GerentesAirtable? get _api {
    final t = _token;
    if (t == null || t.isEmpty) return null;
    return _apiCache ??= GerentesAirtable(token: t, client: _httpClient);
  }

  bool get configurado => _api != null;

  /// Últimos 4 caracteres del token guardado (nunca se muestra completo).
  String? get tokenFinal =>
      configurado ? _token!.substring(_token!.length - 4) : null;

  ConsultaAirtable? _consultasCache;

  /// Cliente para consultar placas y personas directo en Airtable con este
  /// mismo token: el respaldo de portería cuando el gateway no responde.
  /// Null si no hay token configurado.
  Future<ConsultaAirtable?> clienteConsultas() async {
    await _cargado;
    final t = _token;
    if (t == null || t.isEmpty) return null;
    if (_consultasCache?.token != t) {
      _consultasCache = ConsultaAirtable(token: t, client: _httpClient);
    }
    return _consultasCache;
  }

  // ---------- Datos locales ----------

  /// Gerentes por recordId de Airtable.
  final Map<String, Gerente> _gerentes = {};
  DateTime? _listaActualizada;
  final List<GerenteVisita> _visitas = [];

  List<Gerente> get gerentes =>
      _gerentes.values.toList()..sort((a, b) => a.nombre.compareTo(b.nombre));

  DateTime? get listaActualizada => _listaActualizada;

  /// La lista se ve vieja para el vigilante (aviso en pantalla).
  bool get listaVieja =>
      _listaActualizada != null &&
      DateTime.now().difference(_listaActualizada!) > const Duration(days: 2);

  List<GerenteVisita> get visitas => List.unmodifiable(_visitas);

  /// Gerentes que están dentro ahora, más recientes primero.
  List<GerenteVisita> get dentro => _visitas.where((v) => v.dentro).toList()
    ..sort((a, b) => b.ingreso!.compareTo(a.ingreso!));

  /// Historial completo, más reciente primero.
  List<GerenteVisita> get historial => List.of(_visitas)
    ..sort((a, b) => b.ultimaHora.compareTo(a.ultimaHora));

  /// Eventos (ingresos + salidas) aún no subidos a Airtable.
  int get pendientesSync => _visitas.fold(
      0,
      (n, v) => n + (v.ingresoPendiente ? 1 : 0) + (v.salidaPendiente ? 1 : 0));

  GerenteVisita? visitaAbierta(String gerenteId) {
    for (final v in _visitas) {
      if (v.gerenteId == gerenteId && v.dentro) return v;
    }
    return null;
  }

  // ---------- Estado de la sincronización ----------

  bool _sincronizando = false;
  bool _otraVuelta = false;

  /// null = todavía no se ha intentado; false = el último intento no tuvo
  /// internet; true = el último intento llegó a Airtable.
  bool? _enLinea;
  DateTime? _ultimaConexion;
  String? _error;

  /// Token o tablas mal configurados: no se reintenta solo hasta que cambie la
  /// configuración o el vigilante lo pida.
  bool _errorConfiguracion = false;
  DateTime? _proximoIntento;
  int _fallosSeguidos = 0;
  DateTime? _estadoActualizado;

  static const List<Duration> _backoff = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
  ];

  /// Cada cuánto se refresca de Airtable quién está dentro (otras porterías).
  static const Duration _intervaloEstado = Duration(minutes: 2);

  /// Cada cuánto se refresca la lista de gerentes.
  static const Duration _intervaloLista = Duration(minutes: 30);

  /// Visitas cerradas y ya sincronizadas se conservan este tiempo.
  static const Duration _retencion = Duration(days: 7);

  /// Tope de la observación del vigilante (escrita o dictada).
  static const int maxNota = 300;

  bool get sincronizando => _sincronizando;
  bool? get enLinea => _enLinea;
  DateTime? get ultimaConexion => _ultimaConexion;
  String? get error => _error;
  bool get errorConfiguracion => _errorConfiguracion;
  DateTime? get proximoIntento => _proximoIntento;

  // ---------- Registro (funciona sin internet) ----------

  int _seq = 0;

  String _nuevoId() {
    _seq = (_seq + 1) % 1296;
    return DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
        _seq.toRadixString(36).padLeft(2, '0');
  }

  /// Hora sin milisegundos: así se puede reconocer la fila en Airtable al segundo.
  static DateTime _ahora() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, n.hour, n.minute, n.second);
  }

  static String? _limpiarNota(String? raw) {
    if (raw == null) return null;
    var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > maxNota) s = s.substring(0, maxNota);
    return s.isEmpty ? null : s;
  }

  static String _limpiarPlaca(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Registra el ingreso. Devuelve null si el gerente ya figura dentro.
  GerenteVisita? registrarIngreso(Gerente g, {required String placa, String? nota}) {
    if (visitaAbierta(g.recordId) != null) return null;
    final v = GerenteVisita(
      id: _nuevoId(),
      gerenteId: g.recordId,
      cedula: g.cedula,
      nombre: g.nombre,
      uea: g.uea,
      placa: _limpiarPlaca(placa),
      ingreso: _ahora(),
      notaIngreso: _limpiarNota(nota),
    );
    _visitas.add(v);
    debugPrint('👔 [GERENTES] Ingreso local ${g.nombre} (${v.id})');
    _cambioLocal();
    return v;
  }

  /// Registra la salida de una visita abierta.
  void registrarSalida(GerenteVisita v, {String? nota}) {
    if (!v.dentro) return;
    v.salida = _ahora();
    v.notaSalida = _limpiarNota(nota);
    v.salidaSync = SyncState.pendiente;
    debugPrint('👔 [GERENTES] Salida local ${v.nombre} (${v.id})');
    _cambioLocal();
  }

  /// Salida de un gerente que no figura dentro en este teléfono (entró por otra
  /// portería sin que este teléfono se enterara). Al sincronizar se cierra su
  /// ingreso abierto en Airtable, o se crea una fila "salida sin ingreso".
  void registrarSalidaSinIngreso(Gerente g, {required String placa, String? nota}) {
    final v = GerenteVisita(
      id: _nuevoId(),
      gerenteId: g.recordId,
      cedula: g.cedula,
      nombre: g.nombre,
      uea: g.uea,
      placa: _limpiarPlaca(placa),
      ingreso: null,
      salida: _ahora(),
      notaSalida: _limpiarNota(nota),
      ingresoSync: SyncState.sincronizado, // no hay ingreso que subir
      salidaSync: SyncState.pendiente,
    );
    _visitas.add(v);
    debugPrint('👔 [GERENTES] Salida sin ingreso local ${g.nombre} (${v.id})');
    _cambioLocal();
  }

  /// Quita una visita que Airtable rechazó definitivamente.
  void descartarRechazada(GerenteVisita v) {
    if (!v.rechazada) return;
    _visitas.remove(v);
    _guardarVisitas();
    notifyListeners();
  }

  void _cambioLocal() {
    _guardarVisitas();
    notifyListeners();
    // Intento inmediato (si no hay internet falla rápido y queda en cola).
    _proximoIntento = null;
    if (_autoSync) sincronizar();
  }

  // ---------- Configuración ----------

  /// Guarda el token y prueba la conexión descargando la lista de gerentes.
  Future<({bool ok, String mensaje})> configurarToken(String token) async {
    await _cargado;
    token = token.trim();
    if (token.isEmpty) return (ok: false, mensaje: 'Pegue el token de Airtable.');
    _token = token;
    _apiCache = null;
    _errorConfiguracion = false;
    _error = null;
    _proximoIntento = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
    } catch (e) {
      debugPrint('❌ [GERENTES] Error guardando token: $e');
    }
    notifyListeners();

    await sincronizar(manual: true, forzarLista: true);
    if (_errorConfiguracion) return (ok: false, mensaje: _error ?? 'Error de configuración');
    if (_enLinea != true) {
      return (
        ok: false,
        mensaje: 'Token guardado, pero no hay internet para probarlo. '
            'Se probará solo cuando vuelva la conexión.',
      );
    }
    if (_error != null) return (ok: false, mensaje: _error!);
    return (ok: true, mensaje: 'Conexión correcta: ${_gerentes.length} gerentes descargados.');
  }

  Future<void> quitarToken() async {
    await _cargado;
    _token = null;
    _apiCache = null;
    _errorConfiguracion = false;
    _error = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
    } catch (_) {}
    notifyListeners();
  }

  // ---------- Sincronización ----------

  bool get _listaVencida =>
      _listaActualizada == null ||
      DateTime.now().difference(_listaActualizada!) > _intervaloLista;

  bool get _estadoVencido =>
      _estadoActualizado == null ||
      DateTime.now().difference(_estadoActualizado!) > _intervaloEstado;

  Future<void>? _enCurso;
  bool _pedidoManual = false;
  bool _pedidoLista = false;

  /// Sube lo pendiente y refresca lista y estado si toca.
  ///
  /// [manual]: lo pidió el vigilante (ignora esperas y errores de config).
  /// Si ya hay un ciclo en curso, este hace una vuelta más con lo pedido y
  /// quien llama espera a que termine.
  Future<void> sincronizar({bool manual = false, bool forzarLista = false}) async {
    await _cargado;
    if (_api == null) return;
    if (manual) _pedidoManual = true;
    if (forzarLista) _pedidoLista = true;
    final enCurso = _enCurso;
    if (enCurso != null) {
      _otraVuelta = true;
      return enCurso;
    }
    if (!_pedidoManual) {
      if (_errorConfiguracion) return;
      if (_proximoIntento != null && DateTime.now().isBefore(_proximoIntento!)) return;
      if (pendientesSync == 0 && !_listaVencida && !_estadoVencido) return;
    }
    final ciclo = _enCurso = _ciclo();
    try {
      await ciclo;
    } finally {
      _enCurso = null;
    }
  }

  Future<void> _ciclo() async {
    _sincronizando = true;
    notifyListeners();
    var contacto = false;
    try {
      do {
        _otraVuelta = false;
        final manual = _pedidoManual;
        final lista = _pedidoLista;
        _pedidoManual = false;
        _pedidoLista = false;
        final api = _api;
        if (api == null) break; // quitaron el token a mitad de camino
        contacto |= await _subirPendientes(api);
        if (lista || _listaVencida) {
          await _bajarLista(api);
          contacto = true;
        }
        if (manual || _estadoVencido) {
          await _bajarEstado(api);
          contacto = true;
        }
      } while (_otraVuelta);
      if (contacto) {
        _enLinea = true;
        _ultimaConexion = DateTime.now();
      }
      _error = null;
      _errorConfiguracion = false;
      _fallosSeguidos = 0;
      _proximoIntento = null;
    } on AirtableException catch (e) {
      _registrarFallo(e);
    } catch (e, st) {
      debugPrint('❌ [GERENTES] Error inesperado: $e\n$st');
      _error = 'Error inesperado: $e';
      _esperar();
    } finally {
      _sincronizando = false;
      notifyListeners();
    }
  }

  void _registrarFallo(AirtableException e) {
    debugPrint('⏳ [GERENTES] ${e.tipo}: ${e.mensaje}');
    switch (e.tipo) {
      case FalloAirtable.sinInternet:
        _enLinea = false;
        _error = null; // sin internet es un estado normal, no un error
        _esperar();
      case FalloAirtable.credenciales:
      case FalloAirtable.esquema:
        _enLinea = true;
        _error = e.mensaje;
        _errorConfiguracion = true;
      case FalloAirtable.limite:
        _enLinea = true;
        _error = e.mensaje;
        _proximoIntento = DateTime.now().add(const Duration(seconds: 30));
      case FalloAirtable.servidor:
      case FalloAirtable.datos:
        _enLinea = true;
        _error = e.mensaje;
        _esperar();
    }
  }

  void _esperar() {
    final espera = _backoff[_fallosSeguidos.clamp(0, _backoff.length - 1)];
    _fallosSeguidos++;
    _proximoIntento = DateTime.now().add(espera);
  }

  /// Próximo evento a subir: el pendiente más antiguo. La salida de una visita
  /// sube después de su ingreso (necesita la fila ya creada).
  ({GerenteVisita visita, bool esIngreso})? _siguiente() {
    ({GerenteVisita visita, bool esIngreso})? mejor;
    DateTime? mejorHora;
    for (final v in _visitas) {
      final ({GerenteVisita visita, bool esIngreso}) cand;
      final DateTime hora;
      if (v.ingresoPendiente) {
        cand = (visita: v, esIngreso: true);
        hora = v.ingreso!;
      } else if (v.salidaPendiente) {
        cand = (visita: v, esIngreso: false);
        hora = v.salida!;
      } else {
        continue;
      }
      if (mejorHora == null || hora.isBefore(mejorHora)) {
        mejor = cand;
        mejorHora = hora;
      }
    }
    return mejor;
  }

  /// Sube la cola en orden. Devuelve true si contactó a Airtable.
  Future<bool> _subirPendientes(GerentesAirtable api) async {
    final vistos = <String>{};
    var contacto = false;
    while (true) {
      final sig = _siguiente();
      if (sig == null) return contacto;
      // Salvaguarda: un evento que no cambió de estado no se reintenta en bucle.
      if (!vistos.add('${sig.visita.id}${sig.esIngreso}')) return contacto;
      contacto = true;
      if (sig.esIngreso) {
        await _subirIngreso(api, sig.visita);
      } else {
        await _subirSalida(api, sig.visita);
      }
      _guardarVisitas();
      notifyListeners();
    }
  }

  /// Busca la fila que un POST sin respuesta pudo haber creado.
  Future<String?> _buscarCreada(GerentesAirtable api, GerenteVisita v,
      {required bool salida}) async {
    final filas = await api.buscarPorHora(
        salida: salida, hora: salida ? v.salida! : v.ingreso!);
    for (final f in filas) {
      if (f.gerenteId == v.gerenteId) return f.id;
    }
    return null;
  }

  Future<void> _subirIngreso(GerentesAirtable api, GerenteVisita v) async {
    try {
      String? id;
      if (v.creacionIncierta) id = await _buscarCreada(api, v, salida: false);
      if (id == null) {
        v.creacionIncierta = false;
        id = await api.crear(
          gerenteId: v.gerenteId,
          ingreso: v.ingreso,
          placa: v.placa,
          nota: v.notaIngreso != null ? 'Ingreso: ${v.notaIngreso}' : null,
        );
      } else {
        debugPrint('↺ [GERENTES] Ingreso ${v.id} ya estaba en Airtable ($id)');
      }
      v.airtableId = id;
      v.creacionIncierta = false;
      v.ingresoSync = SyncState.sincronizado;
      v.ultimoError = null;
    } on AirtableException catch (e) {
      if (e.incierta) v.creacionIncierta = true;
      if (e.tipo == FalloAirtable.datos) {
        v.ingresoSync = SyncState.rechazado;
        v.ultimoError = 'Airtable rechazó el ingreso: ${e.mensaje}';
        return; // definitivo: la cola sigue con lo demás
      }
      v.ultimoError = e.tipo == FalloAirtable.sinInternet ? null : e.mensaje;
      rethrow;
    }
  }

  Future<void> _subirSalida(GerentesAirtable api, GerenteVisita v) async {
    if (v.ingresoSync == SyncState.rechazado) {
      v.salidaSync = SyncState.rechazado;
      v.ultimoError ??= 'El ingreso no se pudo guardar en Airtable';
      return;
    }
    try {
      IngresoRemoto? fila;
      if (v.airtableId != null) {
        fila = await api.obtener(v.airtableId!); // null si la borraron
      } else {
        // Salida sin ingreso en este teléfono: cerrar su ingreso abierto en
        // Airtable (registrado en otra portería), el más reciente anterior.
        for (final r in await api.ingresosAbiertos()) {
          if (r.gerenteId != v.gerenteId || r.ingreso == null) continue;
          if (r.ingreso!.isAfter(v.salida!)) continue;
          if (fila == null || r.ingreso!.isAfter(fila.ingreso!)) fila = r;
        }
      }

      if (fila != null) {
        if (fila.salida == null) {
          await api.actualizar(fila.id,
              salida: v.salida!, nota: _notaConSalida(fila.nota, v.notaSalida));
        } else if (!_mismoSegundo(fila.salida!, v.salida!)) {
          // Otra portería ya cerró esta visita: se respeta lo que hay.
          v.aviso = 'La salida ya figuraba en Airtable (${_hhmm(fila.salida!)}).';
        }
        v.airtableId = fila.id;
      } else {
        // No hay fila que cerrar: se deja constancia de la salida.
        String? id;
        if (v.creacionIncierta) id = await _buscarCreada(api, v, salida: true);
        if (id == null) {
          v.creacionIncierta = false;
          id = await api.crear(
            gerenteId: v.gerenteId,
            salida: v.salida,
            placa: v.placa,
            nota: [
              'Salida sin ingreso registrado.',
              if (v.notaSalida != null) 'Salida: ${v.notaSalida}',
            ].join('\n'),
          );
        }
        v.airtableId = id;
        v.creacionIncierta = false;
      }
      v.salidaSync = SyncState.sincronizado;
      v.ultimoError = null;
    } on AirtableException catch (e) {
      if (e.incierta) v.creacionIncierta = true;
      if (e.tipo == FalloAirtable.datos) {
        v.salidaSync = SyncState.rechazado;
        v.ultimoError = 'Airtable rechazó la salida: ${e.mensaje}';
        return;
      }
      v.ultimoError = e.tipo == FalloAirtable.sinInternet ? null : e.mensaje;
      rethrow;
    }
  }

  /// Nota de la fila con la línea de salida agregada; null si no hay que
  /// cambiarla (sin nota, o ya agregada en un intento anterior).
  static String? _notaConSalida(String actual, String? notaSalida) {
    if (notaSalida == null) return null;
    final linea = 'Salida: $notaSalida';
    if (actual.contains(linea)) return null;
    return [if (actual.isNotEmpty) actual, linea].join('\n');
  }

  static bool _mismoSegundo(DateTime a, DateTime b) =>
      a.millisecondsSinceEpoch ~/ 1000 == b.millisecondsSinceEpoch ~/ 1000;

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _bajarLista(GerentesAirtable api) async {
    final lista = await api.listarGerentes();
    _gerentes
      ..clear()
      ..addEntries(lista.map((g) => MapEntry(g.recordId, g)));
    _listaActualizada = DateTime.now();
    debugPrint('👔 [GERENTES] Lista actualizada: ${_gerentes.length} gerentes');
    await _guardarLista();
  }

  /// Trae de Airtable quién está dentro (incluye lo registrado en otras
  /// porterías) y lo guarda en el teléfono para consultarlo sin internet.
  Future<void> _bajarEstado(GerentesAirtable api) async {
    final abiertas = await api.ingresosAbiertos();
    final idsAbiertas = {for (final r in abiertas) r.id};
    final limite = DateTime.now().subtract(GerentesAirtable.ventanaAbiertos);

    // 1) Visitas abiertas en Airtable que este teléfono no conoce.
    for (final r in abiertas) {
      final gid = r.gerenteId;
      if (gid == null || r.ingreso == null) continue;
      if (_visitas.any((v) => v.airtableId == r.id)) continue;
      // Ya figura dentro aquí (p. ej. su ingreso local aún no se ha subido).
      if (visitaAbierta(gid) != null) continue;
      final g = _gerentes[gid];
      _visitas.add(GerenteVisita(
        id: 'r${r.id}',
        gerenteId: gid,
        cedula: g?.cedula ?? '',
        nombre: g?.nombre ?? 'Gerente',
        uea: g?.uea ?? '',
        placa: r.placa,
        ingreso: r.ingreso,
        airtableId: r.id,
        ingresoSync: SyncState.sincronizado,
        remota: true,
      ));
    }

    // 2) Visitas que aquí siguen abiertas, ya subidas, pero que en Airtable ya
    //    no figuran abiertas: otra portería registró la salida, o la borraron.
    final revisar = _visitas
        .where((v) =>
            v.dentro &&
            v.airtableId != null &&
            !v.ingresoPendiente &&
            !idsAbiertas.contains(v.airtableId) &&
            v.ingreso!.isAfter(limite))
        .toList();
    for (final v in revisar) {
      final r = await api.obtener(v.airtableId!);
      if (r == null) {
        _visitas.remove(v);
      } else if (r.salida != null) {
        v.salida = r.salida;
        v.salidaSync = SyncState.sincronizado;
        v.aviso = 'Salida registrada en otra portería.';
      }
    }

    // 3) Copias remotas que salieron de la ventana: eran olvidos de salida.
    _visitas.removeWhere((v) => v.remota && v.dentro && v.ingreso!.isBefore(limite));

    _estadoActualizado = DateTime.now();
    await _guardarVisitas();
  }

  // ---------- Disparadores ----------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Al volver a la app: intentar ya, sin esperar el backoff acumulado.
      _proximoIntento = null;
      _fallosSeguidos = 0;
      sincronizar();
    }
  }

  // ---------- Persistencia ----------

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _token = prefs.getString(_tokenKey);

      final listaJson = prefs.getString(_listaKey);
      if (listaJson != null) {
        final decoded = jsonDecode(listaJson) as Map<String, dynamic>;
        final at = decoded['actualizada'] as String?;
        _listaActualizada = at != null ? DateTime.parse(at) : null;
        _gerentes.clear();
        for (final raw in decoded['gerentes'] as List<dynamic>) {
          final g = Gerente.fromJson(raw as Map<String, dynamic>);
          _gerentes[g.recordId] = g;
        }
      }

      final visitasJson = prefs.getString(_visitasKey);
      if (visitasJson != null) {
        final guardadas = (jsonDecode(visitasJson) as List<dynamic>)
            .map((e) => GerenteVisita.fromJson(e as Map<String, dynamic>))
            .toList();
        // Se conservan (como los mismos objetos) las visitas registradas antes
        // de que terminara esta carga.
        _visitas.insertAll(0, guardadas.where((g) => !_visitas.any((m) => m.id == g.id)));
      }

      // Limpieza: solo visitas cerradas, ya sincronizadas y viejas. Lo pendiente
      // y lo que sigue dentro NUNCA se borra.
      final limite = DateTime.now().subtract(_retencion);
      _visitas.removeWhere((v) =>
          !v.dentro && !v.pendienteSync && !v.rechazada && v.salida!.isBefore(limite));
      await _escribirVisitas();

      debugPrint(
        '✅ [GERENTES] Cargado — ${_gerentes.length} gerentes, '
        '${_visitas.length} visitas, $pendientesSync por subir, '
        'token ${configurado ? 'configurado' : 'NO configurado'}',
      );
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ [GERENTES] Error cargando: $e\n$st');
    }
  }

  Future<void> _guardarLista() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _listaKey,
        jsonEncode({
          'actualizada': _listaActualizada?.toIso8601String(),
          'gerentes': _gerentes.values.map((g) => g.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('❌ [GERENTES] Error guardando lista: $e');
    }
  }

  /// Guarda las visitas. Espera a que termine la carga inicial: escribir antes
  /// pisaría lo que había en el teléfono (y se perderían registros pendientes).
  Future<void> _guardarVisitas() async {
    await _cargado;
    await _escribirVisitas();
  }

  Future<void> _escribirVisitas() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _visitasKey,
        jsonEncode(_visitas.map((v) => v.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('❌ [GERENTES] Error guardando visitas: $e');
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_autoSync) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
