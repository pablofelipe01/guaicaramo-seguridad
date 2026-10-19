import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guaicaramo_control/models/gerentes_models.dart';
import 'package:guaicaramo_control/services/gerentes_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = 'patTEST1234';

// IDs reales de campos (si cambian en el cliente, estas pruebas lo detectan).
const _gNombre = 'fldAc3gOPZfNDYpKt';
const _gCedula = 'fldojIMV6ZiwpwZTV';
const _gUea = 'fldUv7a4Vcxro135J';
const _gPlacas = 'fldmikvgBBpVV0Xim';
const _gAutorizado = 'fldKnvJeTysGrcNtw';
const _iGerente = 'fld6OMPw2pMS5GFuK';
const _iIngreso = 'fldp9gFetPvkr07e9';
const _iSalida = 'fldLtWo5AkTLWBHUY';
const _iNota = 'fldYaenmbqZFOyFY7';
const _iPlaca = 'fldG8vof6Dil2CFNj';

/// Airtable falso en memoria: solo lo que usa el módulo de gerentes.
class FakeAirtable {
  bool online = true;
  int? forzarStatus;

  /// El próximo POST se aplica pero su respuesta "se pierde" (corte de red).
  bool perderRespuestaPost = false;

  /// POST que vincule a este gerente responde 422 (gerente borrado).
  String? gerenteRechazado;
  int paginaMax = 100;

  final List<Map<String, dynamic>> gerentes = [];
  final Map<String, Map<String, dynamic>> ingresos = {};
  final List<String> log = [];
  int _n = 0;

  late final http.Client client = MockClient(_handle);

  String _nuevoId() => 'rec${(++_n).toString().padLeft(14, '0')}';

  void agregarGerente(String id, String nombre, String cedula,
      {String placas = '', bool autorizado = true, String uea = 'UEA S.A.S.'}) {
    gerentes.add({
      'id': id,
      'fields': {
        _gNombre: nombre,
        _gCedula: cedula,
        _gUea: uea,
        _gPlacas: placas,
        if (autorizado) _gAutorizado: true,
      },
    });
  }

  String agregarIngreso(String gerenteId, DateTime ingreso, {DateTime? salida}) {
    final id = _nuevoId();
    ingresos[id] = {
      _iGerente: [gerenteId],
      _iIngreso: ingreso.toUtc().toIso8601String(),
      if (salida != null) _iSalida: salida.toUtc().toIso8601String(),
    };
    return id;
  }

  int count(String prefijo) => log.where((l) => l.startsWith(prefijo)).length;

  static http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});

  static int? _epoch(Object? iso) => iso == null
      ? null
      : DateTime.parse(iso as String).millisecondsSinceEpoch ~/ 1000;

  Future<http.Response> _handle(http.Request req) async {
    if (!online) throw http.ClientException('Failed host lookup: api.airtable.com');
    if (req.headers['Authorization'] != 'Bearer $_token') {
      return _json({'error': {'type': 'AUTHENTICATION_REQUIRED', 'message': 'x'}}, 401);
    }
    if (forzarStatus != null) {
      return _json({'error': {'type': 'FORZADO', 'message': 'forzado'}}, forzarStatus!);
    }
    final seg = req.url.pathSegments; // v0, base, tabla, [id]
    expect(seg[1], 'apptwIqTras1uPNOc');
    final tabla = seg[2] == 'tblboorl2mhwQUCZL' ? 'gerentes' : 'ingresos';
    if (tabla == 'ingresos') expect(seg[2], 'tblZWDmWH5dc9ZwJ9');
    final id = seg.length > 3 ? seg[3] : null;
    log.add('${req.method} $tabla${id != null ? '/$id' : ''}');

    if (tabla == 'gerentes') return _pagina(gerentes, req.url.queryParameters['offset']);

    switch (req.method) {
      case 'GET':
        if (id != null) {
          final f = ingresos[id];
          return f == null
              ? _json({'error': 'NOT_FOUND'}, 404)
              : _json({'id': id, 'fields': f});
        }
        final formula = req.url.queryParameters['filterByFormula'] ?? '';
        var filas = ingresos.entries
            .map((e) => <String, dynamic>{'id': e.key, 'fields': e.value})
            .toList();
        final porHora =
            RegExp(r"DATETIME_FORMAT\(\{(\w+)\}, 'X'\) = '(\d+)'").firstMatch(formula);
        if (porHora != null) {
          final campo = porHora.group(1) == 'fecha_hora_salida' ? _iSalida : _iIngreso;
          final epoch = int.parse(porHora.group(2)!);
          filas = filas
              .where((r) => _epoch((r['fields'] as Map)[campo]) == epoch)
              .toList();
        } else if (formula.contains('BLANK()')) {
          final desde = DateTime.now().subtract(const Duration(days: 7));
          filas = filas.where((r) {
            final f = r['fields'] as Map;
            return f[_iSalida] == null &&
                f[_iIngreso] != null &&
                DateTime.parse(f[_iIngreso] as String).isAfter(desde);
          }).toList();
        } else {
          fail('fórmula inesperada: $formula');
        }
        return _pagina(filas, req.url.queryParameters['offset']);
      case 'POST':
        final fields = (jsonDecode(req.body) as Map)['fields'] as Map<String, dynamic>;
        if (gerenteRechazado != null &&
            (fields[_iGerente] as List).contains(gerenteRechazado)) {
          return _json({
            'error': {'type': 'ROW_DOES_NOT_EXIST', 'message': 'Record ID does not exist'}
          }, 422);
        }
        final nuevo = _nuevoId();
        ingresos[nuevo] = Map.of(fields);
        if (perderRespuestaPost) {
          perderRespuestaPost = false;
          throw http.ClientException('Connection reset by peer');
        }
        return _json({'id': nuevo, 'fields': fields});
      case 'PATCH':
        final f = ingresos[id];
        if (f == null) return _json({'error': 'NOT_FOUND'}, 404);
        f.addAll((jsonDecode(req.body) as Map)['fields'] as Map<String, dynamic>);
        return _json({'id': id, 'fields': f});
    }
    throw StateError('no esperado: ${req.method} ${req.url}');
  }

  http.Response _pagina(List<Map<String, dynamic>> filas, String? offset) {
    final desde = int.tryParse(offset ?? '') ?? 0;
    final pagina = filas.skip(desde).take(paginaMax).toList();
    final siguiente = desde + pagina.length;
    return _json({
      'records': pagina,
      if (siguiente < filas.length) 'offset': '$siguiente',
    });
  }
}

const _gId = 'recGER0000000001';
const _g2Id = 'recGER0000000002';

const _g = Gerente(
  recordId: _gId,
  cedula: '1119890856',
  nombre: 'JHONATAN AGUDELO',
  uea: 'CRECER S.A.S.',
  placas: ['KXY123'],
  autorizado: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAirtable at;

  GerentesService nuevo() => GerentesService(httpClient: at.client, autoSync: false);

  setUp(() {
    SharedPreferences.setMockInitialValues({'gerentes_airtable_token': _token});
    at = FakeAirtable()
      ..agregarGerente(_gId, 'JHONATAN AGUDELO', '1119890856', placas: 'KXY123')
      ..agregarGerente(_g2Id, 'HERNESTO DOMIGEZ', '7062276',
          placas: 'JJP240, kcl-232', autorizado: false, uea: 'COVITRAN S.A.S.');
  });

  test('parsePlacas separa y normaliza', () {
    expect(Gerente.parsePlacas('JJP240, kcl-232'), ['JJP240', 'KCL232']);
    expect(Gerente.parsePlacas(''), isEmpty);
  });

  test('registrar antes de que termine la carga no pisa lo guardado', () async {
    at.online = false;
    final s1 = nuevo();
    s1.registrarIngreso(_g, placa: 'KXY123');
    await s1.sincronizar(); // termina carga + guardado
    expect(s1.pendientesSync, 1);

    // Al abrir la app, el vigilante registra antes de que termine la carga.
    final s2 = nuevo();
    const g2 = Gerente(
        recordId: _g2Id, cedula: '7062276', nombre: 'H', uea: '', placas: [],
        autorizado: true);
    final nuevaVisita = s2.registrarIngreso(g2, placa: '')!;
    await s2.sincronizar();
    expect(s2.visitas.length, 2, reason: 'no se pierde la visita anterior');
    expect(s2.visitas, contains(same(nuevaVisita)));

    final s3 = nuevo();
    await s3.sincronizar();
    expect(s3.pendientesSync, 2, reason: 'ambas quedaron persistidas');
  });

  test('sin token registra en el teléfono y no intenta red', () async {
    SharedPreferences.setMockInitialValues({});
    final s = nuevo();
    expect(s.registrarIngreso(_g, placa: 'KXY123'), isNotNull);
    await s.sincronizar(manual: true);
    expect(s.configurado, isFalse);
    expect(s.pendientesSync, 1);
    expect(at.log, isEmpty);
  });

  test('configurar token: prueba la conexión y guarda la lista (paginada)', () async {
    SharedPreferences.setMockInitialValues({});
    at.paginaMax = 1; // obliga a paginar
    final s = nuevo();
    final r = await s.configurarToken('  $_token  ');
    expect(r.ok, isTrue, reason: r.mensaje);
    expect(at.count('GET gerentes'), 2);
    expect(s.gerentes.length, 2);
    final h = s.gerentes.firstWhere((g) => g.recordId == _g2Id);
    expect(h.placas, ['JJP240', 'KCL232']);
    expect(h.autorizado, isFalse);
    expect(h.uea, 'COVITRAN S.A.S.');
    expect(s.enLinea, isTrue);

    // "Reinicio" de la app: todo sigue en el teléfono, sin red.
    at.online = false;
    final s2 = nuevo();
    await s2.sincronizar(); // espera la carga
    expect(s2.configurado, isTrue);
    expect(s2.tokenFinal, '1234');
    expect(s2.gerentes.length, 2);
    expect(s2.listaActualizada, isNotNull);
  });

  test('token inválido: error de configuración y no reintenta solo', () async {
    at.forzarStatus = 401;
    final s = nuevo();
    final r = await s.configurarToken(_token);
    expect(r.ok, isFalse);
    expect(r.mensaje, contains('inválido'));
    expect(s.errorConfiguracion, isTrue);

    at.forzarStatus = null;
    final antes = at.log.length;
    await s.sincronizar(); // automático: no insiste
    expect(at.log.length, antes);
    await s.sincronizar(manual: true); // el vigilante sí puede reintentar
    expect(s.errorConfiguracion, isFalse);
    expect(s.gerentes, isNotEmpty);
  });

  test('sin internet: ingreso y salida quedan en cola y suben en orden al volver',
      () async {
    at.online = false;
    final s = nuevo();
    final v = s.registrarIngreso(_g, placa: 'kxy-123', nota: '  viene a   reunión ')!;
    expect(s.registrarIngreso(_g, placa: 'KXY123'), isNull,
        reason: 'no puede ingresar dos veces');
    s.registrarSalida(v, nota: 'ok');
    await s.sincronizar(manual: true);
    expect(s.enLinea, isFalse);
    expect(s.pendientesSync, 2);
    expect(at.ingresos, isEmpty);

    // La cola sobrevive a cerrar la app.
    final s2 = nuevo();
    await s2.sincronizar(); // sigue sin red
    expect(s2.pendientesSync, 2);

    at.online = true;
    await s2.sincronizar(manual: true);
    expect(s2.pendientesSync, 0);
    expect(s2.enLinea, isTrue);
    expect(at.ingresos.length, 1, reason: 'una sola fila por visita');
    final f = at.ingresos.values.single;
    expect(f[_iGerente], [_gId]);
    expect(f[_iIngreso], v.ingreso!.toUtc().toIso8601String());
    expect(f[_iSalida], s2.visitas.single.salida!.toUtc().toIso8601String());
    expect(f[_iPlaca], 'KXY123');
    expect(f[_iNota], 'Ingreso: viene a reunión\nSalida: ok');
    expect(at.log.indexOf('POST ingresos'),
        lessThan(at.log.indexWhere((l) => l.startsWith('PATCH'))));
  });

  test('POST sin respuesta: al reintentar verifica y no duplica', () async {
    final s = nuevo();
    final v = s.registrarIngreso(_g, placa: 'KXY123')!;
    at.perderRespuestaPost = true;
    await s.sincronizar(manual: true);
    expect(at.ingresos.length, 1, reason: 'Airtable sí la creó');
    expect(s.pendientesSync, 1, reason: 'la app no lo sabe');
    expect(v.creacionIncierta, isTrue);

    await s.sincronizar(manual: true);
    expect(s.pendientesSync, 0);
    expect(at.ingresos.length, 1, reason: 'sin duplicar');
    expect(v.airtableId, at.ingresos.keys.single);
    expect(at.count('POST'), 1);
  });

  test('salida sin ingreso local cierra el ingreso abierto de otra portería',
      () async {
    final otra = at.agregarIngreso(_gId,
        DateTime.now().subtract(const Duration(hours: 1)));
    final s = nuevo();
    s.registrarSalidaSinIngreso(_g, placa: 'KXY123');
    await s.sincronizar(manual: true);
    expect(s.pendientesSync, 0);
    expect(at.ingresos.length, 1);
    expect(at.ingresos[otra]![_iSalida], isNotNull);
  });

  test('salida sin ningún ingreso abierto deja constancia en una fila', () async {
    final s = nuevo();
    s.registrarSalidaSinIngreso(_g, placa: 'KXY123', nota: 'iba de afán');
    await s.sincronizar(manual: true);
    final f = at.ingresos.values.single;
    expect(f[_iIngreso], isNull);
    expect(f[_iSalida], isNotNull);
    expect(f[_iNota], 'Salida sin ingreso registrado.\nSalida: iba de afán');
  });

  test('estado: trae lo de otras porterías y se entera de salidas y borrados',
      () async {
    final r1 = at.agregarIngreso(_g2Id,
        DateTime.now().subtract(const Duration(minutes: 30)));
    final s = nuevo();
    await s.sincronizar(manual: true);
    expect(s.dentro.length, 1);
    final remota = s.dentro.single;
    expect(remota.remota, isTrue);
    expect(remota.nombre, 'HERNESTO DOMIGEZ');
    expect(s.visitaAbierta(_g2Id), isNotNull);

    // Otra portería registra la salida.
    at.ingresos[r1]![_iSalida] = DateTime.now().toUtc().toIso8601String();
    await s.sincronizar(manual: true);
    expect(s.dentro, isEmpty);
    expect(remota.aviso, contains('otra portería'));

    // Una visita abierta que luego se borra en Airtable desaparece aquí.
    final r2 = at.agregarIngreso(_gId,
        DateTime.now().subtract(const Duration(minutes: 5)));
    await s.sincronizar(manual: true);
    expect(s.dentro.length, 1);
    at.ingresos.remove(r2);
    await s.sincronizar(manual: true);
    expect(s.dentro, isEmpty);

    // Todo quedó guardado para consultarlo sin internet.
    at.online = false;
    final s2 = nuevo();
    await s2.sincronizar();
    expect(s2.visitas.where((v) => v.remota).length, 1);
  });

  test('si otra portería ya registró la salida, no se sobrescribe', () async {
    final s = nuevo();
    final v = s.registrarIngreso(_g, placa: 'KXY123')!;
    await s.sincronizar(manual: true);
    final id = v.airtableId!;
    final salidaOtra =
        DateTime.now().subtract(const Duration(minutes: 1)).toUtc().toIso8601String();
    at.ingresos[id]![_iSalida] = salidaOtra;

    s.registrarSalida(v);
    await s.sincronizar(manual: true);
    expect(s.pendientesSync, 0);
    expect(at.ingresos[id]![_iSalida], salidaOtra);
    expect(at.count('PATCH'), 0);
    expect(v.aviso, contains('ya figuraba'));
  });

  test('registro rechazado por Airtable (422) se marca y la cola sigue', () async {
    at.gerenteRechazado = _g2Id;
    final s = nuevo();
    final malo = s.registrarIngreso(
        const Gerente(
            recordId: _g2Id,
            cedula: '7062276',
            nombre: 'X',
            uea: '',
            placas: [],
            autorizado: true),
        placa: '')!;
    s.registrarSalida(malo);
    final bueno = s.registrarIngreso(_g, placa: 'KXY123')!;
    await s.sincronizar(manual: true);

    expect(malo.ingresoSync, SyncState.rechazado);
    expect(malo.salidaSync, SyncState.rechazado);
    expect(malo.ultimoError, contains('does not exist'));
    expect(bueno.ingresoSync, SyncState.sincronizado);
    expect(s.pendientesSync, 0);
    expect(s.error, isNull);

    s.descartarRechazada(malo);
    expect(s.visitas, [bueno]);
  });
}
