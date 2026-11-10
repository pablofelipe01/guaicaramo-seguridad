import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/data_models.dart';
import 'gerentes_airtable.dart';

/// Alguien que puede entrar según la última descarga de Airtable.
class Autorizado {
  const Autorizado({required this.nombre, this.area = '', this.vence});

  final String nombre;
  final String area;

  /// Vencimiento tal como viene de Airtable (ISO 8601); null = no vence.
  final String? vence;

  Map<String, dynamic> toJson() => {
        'n': nombre,
        if (area.isNotEmpty) 'a': area,
        if (vence != null) 'v': vence,
      };

  factory Autorizado.fromJson(Map<String, dynamic> j) => Autorizado(
      nombre: j['n'] as String? ?? '',
      area: j['a'] as String? ?? '',
      vence: j['v'] as String?);
}

/// Todos los autorizados vigentes, por placa o por cédula (ver
/// [ConsultaAirtable.clavePlaca] y [ConsultaAirtable.claveCedula]).
class ListasVigentes {
  const ListasVigentes({
    this.placas = const {},
    this.personas = const {},
    this.finDeSemana = const {},
  });

  final Map<String, Autorizado> placas;
  final Map<String, Autorizado> personas;
  final Map<String, Autorizado> finDeSemana;

  Map<String, dynamic> toJson() =>
      {'placas': placas, 'personas': personas, 'finDeSemana': finDeSemana};

  factory ListasVigentes.fromJson(Map<String, dynamic> j) {
    Map<String, Autorizado> mapa(Object? raw) => {
          for (final e in (raw as Map<String, dynamic>? ?? const {}).entries)
            e.key: Autorizado.fromJson(e.value as Map<String, dynamic>),
        };
    return ListasVigentes(
        placas: mapa(j['placas']),
        personas: mapa(j['personas']),
        finDeSemana: mapa(j['finDeSemana']));
  }
}

/// Resultado de una consulta cuya alerta a recepción (Caso 1) todavía no ha
/// salido: permite consultar por adelantado y alertar solo si el resultado
/// se usa.
class ConsultaDiferida<T> {
  ConsultaDiferida(this._resultado, {void Function()? alertar})
    : _alertar = alertar;

  final T _resultado;
  void Function()? _alertar;

  /// Dispara la alerta pendiente (una sola vez) y entrega el resultado.
  T confirmar() {
    _alertar?.call();
    _alertar = null;
    return _resultado;
  }
}

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
    this.timeout = const Duration(seconds: 25),
  }) : _client = client ?? clienteAirtable;

  final String token;
  final Duration timeout;
  final http.Client _client;

  static const String tablaPlacas = 'tbl4RxLK2q6RxtgZl';
  static const String tablaPersonas = 'tblQk550oa6JDBQ12';
  static const String tablaFinDeSemana = 'tblvyytm4SraskGOL';

  // Placas
  static const String _pPlaca = 'fld8YfRyOcLUmbQGR';
  static const String _pConductor = 'fldmGgGbio6vNBEsq';
  static const String _pAutorizado = 'fldjJ7Kfb2lf6hZHQ';
  static const String _pVence = 'fldHvJqZEmYIfOLqB';
  static const String _pEstado = 'fldb2cefOrqgc4j20';
  static const String _pNodo = 'fldsEEag2QU6LKx9w';
  static const String _pNotificado = 'fldzjmFvr17ZAue4S';

  // Personas
  static const String _eCedula = 'fld53SsbR1iHPE5ua';
  static const String _eNombre = 'fldwq6QE6HTEY3bUg';
  static const String _eAutorizado = 'fldZPZd0y8SrgVcC4';
  static const String _eVence = 'fld31y2GVkApsr3jG';
  static const String _eEstado = 'fld8hbtySIVMimW5g';
  static const String _eNodo = 'fld8V6wD74AHjyHYN';
  static const String _eNotificado = 'fld7asEW9h5vgFTAm';

  // FinDeSemana
  static const String _fCedula = 'fldELTuOdSekwTLHF';
  static const String _fNombre = 'fldm0UoeANFbWz0DM';
  static const String _fArea = 'fldnjUUAySUdWpCOD';
  static const String _fFechaFin = 'fld1WelP2ud7QzD7U';
  static const String _fEstado = 'fldMCGs10ZL3IALqK';
  static const String _fNodo = 'fldzBlSSGjqFlTqU5';
  static const String _fNotificado = 'fld0gaJRImwmqeHDK';

  // ---------- Consultas ----------

  /// Igual que CONSULTA del gateway. [nodoOrigen] (`!xxxxxxxx`) es el nodo
  /// del portero: con él el gateway le avisa cuando recepción resuelva.
  Future<PlateCheckResult> placa(String placa, {String? nodoOrigen}) async =>
      (await placaDiferida(placa, nodoOrigen: nodoOrigen)).confirmar();

  /// Como [placa], pero la alerta a recepción no sale hasta `confirmar()`.
  Future<ConsultaDiferida<PlateCheckResult>> placaDiferida(
    String placa, {
    String? nodoOrigen,
  }) async {
    final p = _limpiar(placa).toUpperCase();
    final recs = await _buscar(
      tablaPlacas,
      "UPPER({placa}) = '$p'",
      _pVence,
      const [_pConductor, _pAutorizado, _pVence, _pEstado],
    );
    if (recs.isEmpty) {
      return ConsultaDiferida(
        PlateCheckResult(status: PlateCheckStatus.notRegistered),
      );
    }
    // Varias filas por placa: se prefiere una vigente (como el gateway).
    final rec = recs.firstWhere(
      (r) => _vigente(_campos(r), _pAutorizado, _pVence),
      orElse: () => recs.first,
    );
    final f = _campos(rec);
    final conductor = _str(f[_pConductor]);
    if (_vigente(f, _pAutorizado, _pVence)) {
      return ConsultaDiferida(
        PlateCheckResult(
          status: PlateCheckStatus.approved,
          driverName: conductor,
        ),
      );
    }
    final estado = _str(f[_pEstado]).toUpperCase();
    if (estado == 'RECHAZADO') {
      return ConsultaDiferida(
        PlateCheckResult(
          status: PlateCheckStatus.rejected,
          driverName: conductor,
        ),
      );
    }
    return ConsultaDiferida(
      PlateCheckResult(
        status: PlateCheckStatus.registeredUnauthorized,
        driverName: conductor,
      ),
      alertar: () => _alertarRecepcion(
        tablaPlacas,
        rec['id'] as String,
        estado,
        nodoOrigen,
        campoEstado: _pEstado,
        campoNodo: _pNodo,
        campoNotificado: _pNotificado,
      ),
    );
  }

  /// Igual que CONSULTA_P del gateway.
  Future<PersonCheckResult> persona(
    String cedula, {
    String? nodoOrigen,
  }) async =>
      (await personaDiferida(cedula, nodoOrigen: nodoOrigen)).confirmar();

  /// Como [persona], pero la alerta a recepción no sale hasta `confirmar()`.
  Future<ConsultaDiferida<PersonCheckResult>> personaDiferida(
    String cedula, {
    String? nodoOrigen,
  }) async {
    final cc = _limpiar(cedula);
    final recs = await _buscar(
      tablaPersonas,
      "{cedula} = '$cc'",
      _eVence,
      const [_eNombre, _eAutorizado, _eVence, _eEstado],
    );
    if (recs.isEmpty) {
      return ConsultaDiferida(
        PersonCheckResult(status: PlateCheckStatus.notRegistered),
      );
    }
    final rec = recs.firstWhere(
      (r) => _vigente(_campos(r), _eAutorizado, _eVence),
      orElse: () => recs.first,
    );
    final f = _campos(rec);
    final nombre = _str(f[_eNombre]);
    if (_vigente(f, _eAutorizado, _eVence)) {
      return ConsultaDiferida(
        PersonCheckResult(
          status: PlateCheckStatus.approved,
          personName: nombre,
        ),
      );
    }
    final estado = _str(f[_eEstado]).toUpperCase();
    if (estado == 'RECHAZADO') {
      return ConsultaDiferida(
        PersonCheckResult(
          status: PlateCheckStatus.rejected,
          personName: nombre,
        ),
      );
    }
    return ConsultaDiferida(
      PersonCheckResult(
        status: PlateCheckStatus.registeredUnauthorized,
        personName: nombre,
      ),
      alertar: () => _alertarRecepcion(
        tablaPersonas,
        rec['id'] as String,
        estado,
        nodoOrigen,
        campoEstado: _eEstado,
        campoNodo: _eNodo,
        campoNotificado: _eNotificado,
      ),
    );
  }

  /// Igual que CONSULTA_F del gateway: aquí manda `estado` (vacío o
  /// AUTORIZADO = puede entrar), no hay checkbox ni vencimiento.
  Future<PersonCheckResult> finDeSemana(
    String cedula, {
    String? nodoOrigen,
  }) async =>
      (await finDeSemanaDiferida(cedula, nodoOrigen: nodoOrigen)).confirmar();

  /// Como [finDeSemana], pero la alerta a recepción no sale hasta
  /// `confirmar()`.
  Future<ConsultaDiferida<PersonCheckResult>> finDeSemanaDiferida(
    String cedula, {
    String? nodoOrigen,
  }) async {
    final cc = _limpiar(cedula);
    final recs = await _buscar(
      tablaFinDeSemana,
      "{cedula} = '$cc'",
      _fFechaFin,
      const [_fNombre, _fArea, _fFechaFin, _fEstado],
    );
    if (recs.isEmpty) {
      return ConsultaDiferida(
        PersonCheckResult(status: PlateCheckStatus.notRegistered),
      );
    }
    bool utilizable(Map<String, dynamic> f) =>
        const {'', 'AUTORIZADO'}.contains(_str(f[_fEstado]).toUpperCase());
    final rec = recs.firstWhere(
      (r) => utilizable(_campos(r)),
      orElse: () => recs.first,
    );
    final f = _campos(rec);
    final nombre = _str(f[_fNombre]);
    final area = _str(f[_fArea]);
    final estado = _str(f[_fEstado]).toUpperCase();
    if (utilizable(f)) {
      return ConsultaDiferida(
        PersonCheckResult(
          status: PlateCheckStatus.approved,
          personName: nombre,
          area: area,
        ),
      );
    }
    if (estado == 'RECHAZADO') {
      return ConsultaDiferida(
        PersonCheckResult(
          status: PlateCheckStatus.rejected,
          personName: nombre,
          area: area,
        ),
      );
    }
    return ConsultaDiferida(
      PersonCheckResult(
        status: PlateCheckStatus.registeredUnauthorized,
        personName: nombre,
        area: area,
      ),
      alertar: () => _alertarRecepcion(
        tablaFinDeSemana,
        rec['id'] as String,
        estado,
        nodoOrigen,
        campoEstado: _fEstado,
        campoNodo: _fNodo,
        campoNotificado: _fNotificado,
      ),
    );
  }

  // ---------- Descarga para la copia local ----------

  /// Cómo se busca una placa: sin comillas y en mayúsculas.
  static String clavePlaca(String placa) => _limpiar(placa).toUpperCase();

  /// Cómo se busca una cédula.
  static String claveCedula(String cedula) => _limpiar(cedula);

  /// Todos los que hoy darían APROBADO en una consulta, con la misma regla
  /// del gateway: `autorizado` y no vencido (placas y personas), o `estado`
  /// vacío / AUTORIZADO (fin de semana).
  Future<ListasVigentes> descargarVigentes() async {
    const vigente =
        'AND({autorizado}, OR({vence} = BLANK(), IS_AFTER({vence}, NOW())))';
    final placas = await _listarTodo(
        tablaPlacas, vigente, _pVence, const [_pPlaca, _pConductor, _pVence]);
    final personas = await _listarTodo(
        tablaPersonas, vigente, _eVence, const [_eCedula, _eNombre, _eVence]);
    final finDeSemana = await _listarTodo(
        tablaFinDeSemana,
        "OR({estado} = BLANK(), {estado} = 'AUTORIZADO')",
        _fFechaFin,
        const [_fCedula, _fNombre, _fArea]);

    // Varias filas por placa/cédula: basta una vigente. Se conserva la que
    // más dura (sin `vence` no vence nunca), que es la que respondería.
    Map<String, Autorizado> indexar(
        List<Map<String, dynamic>> filas, String Function(String) clave,
        String campoClave, String campoNombre,
        {String? campoVence, String? campoArea}) {
      final out = <String, Autorizado>{};
      for (final r in filas) {
        final f = _campos(r);
        final k = clave(_str(f[campoClave]));
        if (k.isEmpty) continue;
        final vence = campoVence == null ? null : f[campoVence] as String?;
        final previo = out[k];
        if (previo != null &&
            (previo.vence == null ||
                (vence != null && vence.compareTo(previo.vence!) <= 0))) {
          continue;
        }
        out[k] = Autorizado(
            nombre: _str(f[campoNombre]),
            area: campoArea == null ? '' : _str(f[campoArea]),
            vence: vence);
      }
      return out;
    }

    return ListasVigentes(
      // La consulta en línea compara UPPER({placa}) sin recortar espacios.
      placas: indexar(placas, (v) => v.toUpperCase(), _pPlaca, _pConductor,
          campoVence: _pVence),
      personas: indexar(personas, (v) => v, _eCedula, _eNombre,
          campoVence: _eVence),
      // Ya vienen de la más reciente a la más vieja: gana la primera.
      finDeSemana: indexar(finDeSemana, (v) => v, _fCedula, _fNombre,
          campoArea: _fArea),
    );
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
      if (nodoOrigen != null) ...{
        campoNodo: nodoOrigen,
        campoNotificado: false,
      },
    };
    if (fields.isEmpty) return;
    unawaited(
      _send('PATCH', _uri('$tabla/$id'), {'fields': fields}).then(
        (_) => debugPrint(
          '🔔 [AIRTABLE] Fila $id marcada PENDIENTE (alerta a recepción)',
        ),
        onError: (Object e) =>
            debugPrint('❌ [AIRTABLE] No se pudo alertar a recepción: $e'),
      ),
    );
  }

  // ---------- HTTP ----------

  Uri _uri(String path, [Map<String, dynamic>? query]) => Uri.https(
    'api.airtable.com',
    '/v0/${GerentesAirtable.baseGuaicaramo}/$path',
    query,
  );

  /// Primera página (100 filas) ordenada por [ordenarPor] descendente; el
  /// gateway tampoco mira más allá.
  /// Solo pide [campos]: con internet lento la respuesta pesa mucho menos.
  Future<List<Map<String, dynamic>>> _buscar(
    String tabla,
    String formula,
    String ordenarPor,
    List<String> campos,
  ) async {
    final body = await _send(
      'GET',
      _uri(tabla, {
        'pageSize': '100',
        'returnFieldsByFieldId': 'true',
        'fields[]': campos,
        'filterByFormula': formula,
        'sort[0][field]': ordenarPor,
        'sort[0][direction]': 'desc',
      }),
    );
    return (body['records'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Todas las páginas de [tabla] que cumplen [formula], solo con [campos].
  Future<List<Map<String, dynamic>>> _listarTodo(String tabla, String formula,
      String ordenarPor, List<String> campos) async {
    final out = <Map<String, dynamic>>[];
    String? offset;
    do {
      final body = await _send(
          'GET',
          _uri(tabla, {
            'pageSize': '100',
            'returnFieldsByFieldId': 'true',
            'fields[]': campos,
            'filterByFormula': formula,
            'sort[0][field]': ordenarPor,
            'sort[0][direction]': 'desc',
            'offset': ?offset,
          }));
      out.addAll((body['records'] as List<dynamic>).cast<Map<String, dynamic>>());
      offset = body['offset'] as String?;
    } while (offset != null);
    return out;
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
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
        FalloAirtable.sinInternet,
        'Airtable no respondió a tiempo',
      );
    } on Exception {
      throw const AirtableException(
        FalloAirtable.sinInternet,
        'Sin conexión a internet',
      );
    }

    final status = resp.statusCode;
    if (status >= 200 && status < 300) {
      return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    }
    if (status == 401 || status == 403 || status == 404) {
      throw AirtableException(
        FalloAirtable.credenciales,
        'El token no tiene acceso a la tabla (HTTP $status)',
      );
    }
    if (status == 429) {
      throw const AirtableException(
        FalloAirtable.limite,
        'Airtable pidió esperar unos segundos',
      );
    }
    if (status >= 500) {
      throw AirtableException(
        FalloAirtable.servidor,
        'Airtable falló (HTTP $status)',
      );
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
  static bool _vigente(
    Map<String, dynamic> f,
    String autorizado,
    String vence,
  ) => f[autorizado] == true && !vencida(f[vence]);

  /// Misma regla que `_is_expired` del gateway: dateTime se compara al
  /// segundo; una fecha sola vale hasta el fin de ese día (UTC). Un valor
  /// ilegible no se toma como vencido.
  static bool vencida(Object? vence, {DateTime? ahora}) {
    if (vence is! String || vence.isEmpty) return false;
    final now = (ahora ?? DateTime.now()).toUtc();
    if (vence.contains('T')) {
      final dt = DateTime.tryParse(vence);
      return dt != null && dt.isBefore(now);
    }
    final d = DateTime.tryParse(
      vence.length >= 10 ? vence.substring(0, 10) : vence,
    );
    if (d == null) return false;
    return DateTime.utc(d.year, d.month, d.day, 23, 59, 59).isBefore(now);
  }
}
