import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/data_models.dart';
import 'gerentes_airtable.dart';

/// Consulta directa a Airtable de placas, personas y fin de semana: el
/// respaldo por internet cuando el gateway no responde por la malla.
///
/// Replica `handle_consulta*` del gateway (gateway/gateway.py) para que el
/// portero vea el mismo resultado venga por donde venga, incluida la alerta a
/// recepción del Caso 1. Usa el token del módulo de Gerentes (misma base).
class ConsultaAirtable {
  ConsultaAirtable({
    required this.token,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final String token;
  final Duration timeout;
  final http.Client _client;

  static const String tablaPlacas = 'tbl4RxLK2q6RxtgZl';
  static const String tablaPersonas = 'tblQk550oa6JDBQ12';
  static const String tablaFinDeSemana = 'tblvyytm4SraskGOL';

  // Placas
  static const String _pConductor = 'fldmGgGbio6vNBEsq';
  static const String _pAutorizado = 'fldjJ7Kfb2lf6hZHQ';
  static const String _pVence = 'fldHvJqZEmYIfOLqB';
  static const String _pEstado = 'fldb2cefOrqgc4j20';
  static const String _pNodo = 'fldsEEag2QU6LKx9w';
  static const String _pNotificado = 'fldzjmFvr17ZAue4S';

  // Personas
  static const String _eNombre = 'fldwq6QE6HTEY3bUg';
  static const String _eAutorizado = 'fldZPZd0y8SrgVcC4';
  static const String _eVence = 'fld31y2GVkApsr3jG';
  static const String _eEstado = 'fld8hbtySIVMimW5g';
  static const String _eNodo = 'fld8V6wD74AHjyHYN';
  static const String _eNotificado = 'fld7asEW9h5vgFTAm';

  // FinDeSemana
  static const String _fNombre = 'fldm0UoeANFbWz0DM';
  static const String _fArea = 'fldnjUUAySUdWpCOD';
  static const String _fFechaFin = 'fld1WelP2ud7QzD7U';
  static const String _fEstado = 'fldMCGs10ZL3IALqK';
  static const String _fNodo = 'fldzBlSSGjqFlTqU5';
  static const String _fNotificado = 'fld0gaJRImwmqeHDK';

  // ---------- Consultas ----------

  /// Igual que CONSULTA del gateway. [nodoOrigen] (`!xxxxxxxx`) es el nodo
  /// del portero: con él el gateway le avisa cuando recepción resuelva.
  Future<PlateCheckResult> placa(String placa, {String? nodoOrigen}) async {
    final p = _limpiar(placa).toUpperCase();
    final recs = await _buscar(tablaPlacas, "UPPER({placa}) = '$p'", _pVence);
    if (recs.isEmpty) {
      return PlateCheckResult(status: PlateCheckStatus.notRegistered);
    }
    // Varias filas por placa: se prefiere una vigente (como el gateway).
    final rec = recs.firstWhere(
        (r) => _vigente(_campos(r), _pAutorizado, _pVence),
        orElse: () => recs.first);
    final f = _campos(rec);
    final conductor = _str(f[_pConductor]);
    if (_vigente(f, _pAutorizado, _pVence)) {
      return PlateCheckResult(
          status: PlateCheckStatus.approved, driverName: conductor);
    }
    final estado = _str(f[_pEstado]).toUpperCase();
    if (estado == 'RECHAZADO') {
      return PlateCheckResult(
          status: PlateCheckStatus.rejected, driverName: conductor);
    }
    _alertarRecepcion(tablaPlacas, rec['id'] as String, estado, nodoOrigen,
        campoEstado: _pEstado, campoNodo: _pNodo, campoNotificado: _pNotificado);
    return PlateCheckResult(
        status: PlateCheckStatus.registeredUnauthorized, driverName: conductor);
  }

  /// Igual que CONSULTA_P del gateway.
  Future<PersonCheckResult> persona(String cedula, {String? nodoOrigen}) async {
    final cc = _limpiar(cedula);
    final recs = await _buscar(tablaPersonas, "{cedula} = '$cc'", _eVence);
    if (recs.isEmpty) {
      return PersonCheckResult(status: PlateCheckStatus.notRegistered);
    }
    final rec = recs.firstWhere(
        (r) => _vigente(_campos(r), _eAutorizado, _eVence),
        orElse: () => recs.first);
    final f = _campos(rec);
    final nombre = _str(f[_eNombre]);
    if (_vigente(f, _eAutorizado, _eVence)) {
      return PersonCheckResult(
          status: PlateCheckStatus.approved, personName: nombre);
    }
    final estado = _str(f[_eEstado]).toUpperCase();
    if (estado == 'RECHAZADO') {
      return PersonCheckResult(
          status: PlateCheckStatus.rejected, personName: nombre);
    }
    _alertarRecepcion(tablaPersonas, rec['id'] as String, estado, nodoOrigen,
        campoEstado: _eEstado, campoNodo: _eNodo, campoNotificado: _eNotificado);
    return PersonCheckResult(
        status: PlateCheckStatus.registeredUnauthorized, personName: nombre);
  }

  /// Igual que CONSULTA_F del gateway: aquí manda `estado` (vacío o
  /// AUTORIZADO = puede entrar), no hay checkbox ni vencimiento.
  Future<PersonCheckResult> finDeSemana(String cedula,
      {String? nodoOrigen}) async {
    final cc = _limpiar(cedula);
    final recs =
        await _buscar(tablaFinDeSemana, "{cedula} = '$cc'", _fFechaFin);
    if (recs.isEmpty) {
      return PersonCheckResult(status: PlateCheckStatus.notRegistered);
    }
    bool utilizable(Map<String, dynamic> f) =>
        const {'', 'AUTORIZADO'}.contains(_str(f[_fEstado]).toUpperCase());
    final rec = recs.firstWhere((r) => utilizable(_campos(r)),
        orElse: () => recs.first);
    final f = _campos(rec);
    final nombre = _str(f[_fNombre]);
    final area = _str(f[_fArea]);
    final estado = _str(f[_fEstado]).toUpperCase();
    if (utilizable(f)) {
      return PersonCheckResult(
          status: PlateCheckStatus.approved, personName: nombre, area: area);
    }
    if (estado == 'RECHAZADO') {
      return PersonCheckResult(
          status: PlateCheckStatus.rejected, personName: nombre, area: area);
    }
    _alertarRecepcion(tablaFinDeSemana, rec['id'] as String, estado, nodoOrigen,
        campoEstado: _fEstado, campoNodo: _fNodo, campoNotificado: _fNotificado);
    return PersonCheckResult(
        status: PlateCheckStatus.registeredUnauthorized,
        personName: nombre,
        area: area);
  }

  /// Caso 1 (existe pero sin autorización activa): marca la fila PENDIENTE
  /// para la cola de recepción, como `_flag_pendiente_alerta` del gateway.
  /// No bloquea la respuesta al portero; si falla solo queda en el log.
  void _alertarRecepcion(
    String tabla,
    String id,
    String estado,
    String? nodoOrigen, {
    required String campoEstado,
    required String campoNodo,
    required String campoNotificado,
  }) {
    final fields = <String, dynamic>{
      if (estado != 'PENDIENTE') campoEstado: 'PENDIENTE',
      if (nodoOrigen != null) ...{campoNodo: nodoOrigen, campoNotificado: false},
    };
    if (fields.isEmpty) return;
    unawaited(_send('PATCH', _uri('$tabla/$id'), {'fields': fields}).then(
      (_) => debugPrint('🔔 [AIRTABLE] Fila $id marcada PENDIENTE (alerta a recepción)'),
      onError: (Object e) => debugPrint('❌ [AIRTABLE] No se pudo alertar a recepción: $e'),
    ));
  }

  // ---------- HTTP ----------

  Uri _uri(String path, [Map<String, String>? query]) => Uri.https(
      'api.airtable.com', '/v0/${GerentesAirtable.baseGuaicaramo}/$path', query);

  /// Primera página (100 filas) ordenada por [ordenarPor] descendente; el
  /// gateway tampoco mira más allá.
  Future<List<Map<String, dynamic>>> _buscar(
      String tabla, String formula, String ordenarPor) async {
    final body = await _send('GET', _uri(tabla, {
      'pageSize': '100',
      'returnFieldsByFieldId': 'true',
      'filterByFormula': formula,
      'sort[0][field]': ordenarPor,
      'sort[0][direction]': 'desc',
    }));
    return (body['records'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> _send(String method, Uri uri,
      [Map<String, dynamic>? body]) async {
    final req = http.Request(method, uri)
      ..headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }

    final http.Response resp;
    try {
      final streamed = await _client.send(req).timeout(timeout);
      resp = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const AirtableException(
          FalloAirtable.sinInternet, 'Airtable no respondió a tiempo');
    } on Exception {
      throw const AirtableException(
          FalloAirtable.sinInternet, 'Sin conexión a internet');
    }

    final status = resp.statusCode;
    if (status >= 200 && status < 300) {
      return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    }
    if (status == 401 || status == 403 || status == 404) {
      throw AirtableException(FalloAirtable.credenciales,
          'El token no tiene acceso a la tabla (HTTP $status)');
    }
    if (status == 429) {
      throw const AirtableException(
          FalloAirtable.limite, 'Airtable pidió esperar unos segundos');
    }
    if (status >= 500) {
      throw AirtableException(FalloAirtable.servidor, 'Airtable falló (HTTP $status)');
    }
    throw AirtableException(FalloAirtable.datos, 'HTTP $status');
  }

  // ---------- Conversión ----------

  static Map<String, dynamic> _campos(Map<String, dynamic> r) =>
      r['fields'] as Map<String, dynamic>? ?? const {};

  static String _str(Object? v) => (v ?? '').toString().trim();

  /// Quita lo que rompería la fórmula de Airtable (comillas y barras).
  static String _limpiar(String s) => s.replaceAll(RegExp(r"['\\]"), '').trim();

  /// `autorizado` marcado y no vencida (`_registro_vigente` del gateway).
  static bool _vigente(Map<String, dynamic> f, String autorizado, String vence) =>
      f[autorizado] == true && !vencida(f[vence]);

  /// Misma regla que `_is_expired` del gateway: dateTime se compara al
  /// segundo; una fecha sola vale hasta el fin de ese día (UTC). Un valor
  /// ilegible no se toma como vencido.
  @visibleForTesting
  static bool vencida(Object? vence, {DateTime? ahora}) {
    if (vence is! String || vence.isEmpty) return false;
    final now = (ahora ?? DateTime.now()).toUtc();
    if (vence.contains('T')) {
      final dt = DateTime.tryParse(vence);
      return dt != null && dt.isBefore(now);
    }
    final d = DateTime.tryParse(vence.length >= 10 ? vence.substring(0, 10) : vence);
    if (d == null) return false;
    return DateTime.utc(d.year, d.month, d.day, 23, 59, 59).isBefore(now);
  }
}
