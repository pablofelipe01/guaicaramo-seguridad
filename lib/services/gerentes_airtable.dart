import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;
import 'package:http/http.dart' as http;
import '../models/gerentes_models.dart';

/// Qué salió mal al hablar con Airtable. Decide qué hace la cola.
enum FalloAirtable {
  /// No hubo respuesta: sin red, DNS, corte o timeout. Reintentar luego.
  sinInternet,

  /// 401/403: token inválido o sin acceso. No reintentar hasta reconfigurar.
  credenciales,

  /// Cambió la estructura de la tabla (fórmula/campo inválido). Igual que
  /// credenciales: requiere que alguien lo corrija.
  esquema,

  /// 429: Airtable pide esperar 30 s.
  limite,

  /// 5xx: falla temporal de Airtable.
  servidor,

  /// 422 u otro 4xx sobre UN registro: Airtable rechazó ese dato.
  datos,
}

class AirtableException implements Exception {
  final FalloAirtable tipo;
  final String mensaje;

  /// La petición pudo haberse aplicado aunque no llegó respuesta (corte a
  /// mitad de un POST). Quien llama debe verificar antes de repetirla.
  final bool incierta;

  const AirtableException(this.tipo, this.mensaje, {this.incierta = false});

  @override
  String toString() => 'AirtableException($tipo): $mensaje';
}

/// Fila de `Ingresos Gerentes Unidades Externas` tal como está en Airtable.
class IngresoRemoto {
  final String id;
  final String? gerenteId;
  final DateTime? ingreso;
  final DateTime? salida;
  final String placa;
  final String nota;

  const IngresoRemoto({
    required this.id,
    this.gerenteId,
    this.ingreso,
    this.salida,
    this.placa = '',
    this.nota = '',
  });
}

/// Cliente REST mínimo de Airtable para las dos tablas del módulo de gerentes.
///
/// Lee y escribe por ID de tabla y de campo (`returnFieldsByFieldId`), así un
/// cambio de nombre de columna en Airtable no rompe la app. Solo las fórmulas
/// de búsqueda (`filterByFormula`) necesitan los nombres de los campos.
class GerentesAirtable {
  GerentesAirtable({
    required this.token,
    this.baseId = baseGuaicaramo,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final String token;
  final String baseId;
  final Duration timeout;
  final http.Client _client;

  static const String baseGuaicaramo = 'apptwIqTras1uPNOc';
  static const String tablaGerentes = 'tblboorl2mhwQUCZL';
  static const String tablaIngresos = 'tblZWDmWH5dc9ZwJ9';

  // Gerentes Unidades Externas
  static const String _gNombre = 'fldAc3gOPZfNDYpKt';
  static const String _gCedula = 'fldojIMV6ZiwpwZTV';
  static const String _gUea = 'fldUv7a4Vcxro135J';
  static const String _gPlacas = 'fldmikvgBBpVV0Xim';
  static const String _gAutorizado = 'fldKnvJeTysGrcNtw';

  // Ingresos Gerentes Unidades Externas
  static const String _iGerente = 'fld6OMPw2pMS5GFuK';
  static const String _iIngreso = 'fldp9gFetPvkr07e9';
  static const String _iSalida = 'fldLtWo5AkTLWBHUY';
  static const String _iNota = 'fldYaenmbqZFOyFY7';
  static const String _iPlaca = 'fldG8vof6Dil2CFNj';

  // Nombres (solo para filterByFormula).
  static const String _nIngreso = 'fecha_hora_ingreso';
  static const String _nSalida = 'fecha_hora_salida';

  /// Ventana de "quién está dentro": ingresos abiertos más viejos que esto se
  /// consideran olvidos de salida y no se descargan.
  static const Duration ventanaAbiertos = Duration(days: 7);

  // ---------- Lecturas ----------

  /// Todos los gerentes (pagina de a 100).
  Future<List<Gerente>> listarGerentes() async {
    final records = await _listarTodo(tablaGerentes);
    return records.map((r) {
      final f = r['fields'] as Map<String, dynamic>? ?? const {};
      return Gerente(
        recordId: r['id'] as String,
        cedula: _str(f[_gCedula]),
        nombre: _str(f[_gNombre]),
        uea: _str(f[_gUea]),
        placas: Gerente.parsePlacas(_str(f[_gPlacas])),
        autorizado: f[_gAutorizado] == true,
      );
    }).toList();
  }

  /// Visitas abiertas (con ingreso y sin salida) de los últimos 7 días.
  Future<List<IngresoRemoto>> ingresosAbiertos() async {
    final formula = 'AND({$_nSalida} = BLANK(), {$_nIngreso} != BLANK(), '
        "IS_AFTER({$_nIngreso}, DATEADD(NOW(), -${ventanaAbiertos.inDays}, 'days')))";
    final records = await _listarTodo(tablaIngresos, formula: formula);
    return records.map(_ingreso).toList();
  }

  /// Filas cuyo ingreso (o salida) es exactamente [hora], al segundo. Sirve
  /// para saber si un POST sin respuesta alcanzó a crear la fila.
  Future<List<IngresoRemoto>> buscarPorHora({
    required bool salida,
    required DateTime hora,
  }) async {
    final campo = salida ? _nSalida : _nIngreso;
    final epoch = hora.millisecondsSinceEpoch ~/ 1000;
    final records = await _listarTodo(
      tablaIngresos,
      formula: "DATETIME_FORMAT({$campo}, 'X') = '$epoch'",
    );
    return records.map(_ingreso).toList();
  }

  /// Una fila por ID. Null si fue borrada.
  Future<IngresoRemoto?> obtener(String id) async {
    try {
      final r = await _send('GET', _uri('$tablaIngresos/$id', {
        'returnFieldsByFieldId': 'true',
      }), registro: true);
      return _ingreso(r);
    } on _NoExiste {
      return null;
    }
  }

  // ---------- Escrituras ----------

  /// Crea una fila de visita. Devuelve su ID.
  Future<String> crear({
    required String gerenteId,
    DateTime? ingreso,
    DateTime? salida,
    String placa = '',
    String? nota,
  }) async {
    final fields = <String, dynamic>{
      _iGerente: [gerenteId],
      if (ingreso != null) _iIngreso: _iso(ingreso),
      if (salida != null) _iSalida: _iso(salida),
      if (placa.isNotEmpty) _iPlaca: placa,
      if (nota != null && nota.isNotEmpty) _iNota: nota,
    };
    final r = await _send('POST', _uri(tablaIngresos), body: {'fields': fields});
    return r['id'] as String;
  }

  /// Registra la salida en una fila existente (y opcionalmente la nota).
  /// Idempotente: repetirla deja el mismo resultado.
  Future<void> actualizar(String id, {required DateTime salida, String? nota}) async {
    final fields = <String, dynamic>{
      _iSalida: _iso(salida),
      _iNota: ?nota,
    };
    try {
      await _send('PATCH', _uri('$tablaIngresos/$id'),
          body: {'fields': fields}, registro: true);
    } on _NoExiste {
      // La borraron entre la lectura y esta escritura: al reintentar, la
      // lectura dará null y la salida quedará como fila propia.
      throw const AirtableException(
          FalloAirtable.servidor, 'La fila cambió en Airtable; se reintentará');
    }
  }

  // ---------- HTTP ----------

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.https('api.airtable.com', '/v0/$baseId/$path', query);

  Future<List<Map<String, dynamic>>> _listarTodo(String tabla, {String? formula}) async {
    final out = <Map<String, dynamic>>[];
    String? offset;
    do {
      final body = await _send('GET', _uri(tabla, {
        'pageSize': '100',
        'returnFieldsByFieldId': 'true',
        'filterByFormula': ?formula,
        'offset': ?offset,
      }));
      out.addAll((body['records'] as List<dynamic>).cast<Map<String, dynamic>>());
      offset = body['offset'] as String?;
    } while (offset != null);
    return out;
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
    bool registro = false,
  }) async {
    final req = http.Request(method, uri)
      ..headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    // Sin respuesta, un GET nunca cambió nada; un POST/PATCH quizá sí.
    final incierta = method != 'GET';

    final http.Response resp;
    try {
      final streamed = await _client.send(req).timeout(timeout);
      resp = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw AirtableException(FalloAirtable.sinInternet,
          'Airtable no respondió a tiempo', incierta: incierta);
    } on SocketException {
      throw AirtableException(FalloAirtable.sinInternet, 'Sin conexión a internet',
          incierta: incierta);
    } on HandshakeException {
      throw AirtableException(FalloAirtable.sinInternet, 'Sin conexión segura',
          incierta: incierta);
    } on http.ClientException {
      throw AirtableException(FalloAirtable.sinInternet, 'Sin conexión a internet',
          incierta: incierta);
    }

    final status = resp.statusCode;
    if (status >= 200 && status < 300) {
      return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    }
    final (tipoError, detalle) = _error(resp);
    if (status == 401) {
      throw const AirtableException(
          FalloAirtable.credenciales, 'Token de Airtable inválido o vencido');
    }
    if (status == 403) {
      throw const AirtableException(FalloAirtable.credenciales,
          'El token no tiene permiso sobre la base de Guaicaramo');
    }
    if (status == 404) {
      if (registro) throw const _NoExiste();
      throw const AirtableException(FalloAirtable.credenciales,
          'No se encontró la base o la tabla (¿el token tiene acceso?)');
    }
    if (status == 429) {
      throw const AirtableException(
          FalloAirtable.limite, 'Airtable pidió esperar unos segundos');
    }
    if (status >= 500) {
      throw AirtableException(FalloAirtable.servidor, 'Airtable falló (HTTP $status)');
    }
    if (tipoError == 'INVALID_FILTER_BY_FORMULA' || tipoError == 'UNKNOWN_FIELD_NAME') {
      throw AirtableException(FalloAirtable.esquema,
          'Cambió la estructura de la tabla en Airtable: $detalle');
    }
    throw AirtableException(FalloAirtable.datos, detalle);
  }

  /// Extrae `error.type` y `error.message` del cuerpo de error de Airtable.
  static (String?, String) _error(http.Response resp) {
    try {
      final err = (jsonDecode(resp.body) as Map<String, dynamic>)['error'];
      if (err is Map<String, dynamic>) {
        return (err['type'] as String?, (err['message'] ?? err['type']).toString());
      }
      if (err is String) return (err, err);
    } catch (_) {}
    return (null, 'HTTP ${resp.statusCode}');
  }

  // ---------- Conversión ----------

  static String _iso(DateTime d) => d.toUtc().toIso8601String();

  static String _str(Object? v) => (v ?? '').toString().trim();

  static DateTime? _fecha(Object? v) =>
      v is String && v.isNotEmpty ? DateTime.parse(v).toLocal() : null;

  static IngresoRemoto _ingreso(Map<String, dynamic> r) {
    final f = r['fields'] as Map<String, dynamic>? ?? const {};
    final links = f[_iGerente];
    return IngresoRemoto(
      id: r['id'] as String,
      gerenteId: links is List && links.isNotEmpty ? links.first as String : null,
      ingreso: _fecha(f[_iIngreso]),
      salida: _fecha(f[_iSalida]),
      placa: _str(f[_iPlaca]),
      nota: _str(f[_iNota]),
    );
  }
}

/// 404 sobre un registro puntual (fue borrado): se traduce a `null`.
class _NoExiste implements Exception {
  const _NoExiste();
}
