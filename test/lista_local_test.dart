import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guaicaramo_control/models/data_models.dart';
import 'package:guaicaramo_control/services/consulta_airtable.dart';
import 'package:guaicaramo_control/services/lista_local.dart';
import 'package:guaicaramo_control/services/meshtastic_service.dart';
import 'package:guaicaramo_control/services/registro_local.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pPlaca = 'fld8YfRyOcLUmbQGR';
const _pConductor = 'fldmGgGbio6vNBEsq';
const _pVence = 'fldHvJqZEmYIfOLqB';
const _eCedula = 'fld53SsbR1iHPE5ua';
const _eNombre = 'fldwq6QE6HTEY3bUg';
const _fCedula = 'fldELTuOdSekwTLHF';
const _fNombre = 'fldm0UoeANFbWz0DM';
const _fArea = 'fldnjUUAySUdWpCOD';

/// Airtable falso con paginación de a [porPagina] filas.
class FakeAirtable {
  final Map<String, List<Map<String, dynamic>>> filas = {};
  final List<Uri> gets = [];
  bool caido = false;
  int porPagina = 100;

  late final http.Client client = MockClient((req) async {
    gets.add(req.url);
    if (caido) throw const SocketException('sin red');
    final todas = filas[req.url.pathSegments[2]] ?? const [];
    final desde = int.parse(req.url.queryParameters['offset'] ?? '0');
    final hasta = (desde + porPagina).clamp(0, todas.length);
    return http.Response(
        jsonEncode({
          'records': todas.sublist(desde, hasta),
          if (hasta < todas.length) 'offset': '$hasta',
        }),
        200);
  });

  ConsultaAirtable get api => ConsultaAirtable(token: 'patTEST', client: client);
}

Map<String, dynamic> _fila(Map<String, dynamic> campos) =>
    {'id': 'rec${campos.hashCode}', 'fields': campos};

void main() {
  late FakeAirtable at;
  late DateTime ahora;
  late ListaLocal lista;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    at = FakeAirtable();
    ahora = DateTime(2026, 11, 10, 8);
    lista = ListaLocal(cliente: () async => at.api, reloj: () => ahora);
    at.filas[ConsultaAirtable.tablaPlacas] = [
      _fila({_pPlaca: 'abc123', _pConductor: 'Ana'}),
      _fila({
        _pPlaca: 'XYZ789',
        _pConductor: 'Luis',
        _pVence: ahora.add(const Duration(minutes: 10)).toUtc().toIso8601String(),
      }),
    ];
    at.filas[ConsultaAirtable.tablaPersonas] = [
      _fila({_eCedula: '111', _eNombre: 'Eva'}),
    ];
    at.filas[ConsultaAirtable.tablaFinDeSemana] = [
      _fila({_fCedula: '222', _fNombre: 'Leo', _fArea: 'Planta'}),
      _fila({_fCedula: '222', _fNombre: 'Leo viejo', _fArea: 'Otra'}),
    ];
  });

  test('sin descargar no responde nada', () {
    expect(lista.utilizable, isFalse);
    expect(lista.placa('ABC123'), isNull);
  });

  test('descarga solo vigentes y responde AUTORIZADO al instante', () async {
    expect(await lista.sincronizar(), isTrue);

    final placas = at.gets.firstWhere(
        (u) => u.pathSegments[2] == ConsultaAirtable.tablaPlacas);
    expect(placas.queryParameters['filterByFormula'],
        'AND({autorizado}, OR({vence} = BLANK(), IS_AFTER({vence}, NOW())))');
    expect(placas.queryParametersAll['fields[]'], [_pPlaca, _pConductor, _pVence]);

    final consultas = at.gets.length;
    final r = lista.placa("abc12'3");
    expect(r!.status, PlateCheckStatus.approved);
    expect(r.driverName, 'Ana');
    expect(r.note, contains('Lista local'));
    expect(lista.persona('111')!.personName, 'Eva');
    final f = lista.finDeSemana('222')!;
    expect(f.personName, 'Leo'); // la fila más reciente
    expect(f.area, 'Planta');
    expect(at.gets.length, consultas, reason: 'no debe tocar la red');
  });

  test('quien no está en la copia va a consulta en línea', () async {
    await lista.sincronizar();
    expect(lista.placa('NOEXISTE'), isNull);
    expect(lista.persona('999'), isNull);
  });

  test('el vencimiento se revisa al consultar', () async {
    await lista.sincronizar();
    expect(lista.placa('XYZ789'), isNotNull);
    ahora = ahora.add(const Duration(minutes: 11));
    expect(lista.placa('XYZ789'), isNull);
    expect(lista.placa('ABC123'), isNotNull);
  });

  test('pasada la antigüedad máxima la copia deja de usarse', () async {
    await lista.sincronizar();
    at.caido = true;
    ahora = ahora.add(ListaLocal.antiguedadMaxima + const Duration(minutes: 1));
    expect(await lista.sincronizar(), isFalse);
    expect(lista.utilizable, isFalse);
    expect(lista.placa('ABC123'), isNull);
  });

  test('si la descarga falla se conserva la copia anterior', () async {
    await lista.sincronizar();
    at.caido = true;
    ahora = ahora.add(const Duration(minutes: 6));
    expect(await lista.sincronizar(), isFalse);
    expect(lista.placa('ABC123'), isNotNull);
    expect(lista.antiguedad, const Duration(minutes: 6));
  });

  test('reloj atrasado: no se confía en la copia', () async {
    await lista.sincronizar();
    ahora = ahora.subtract(const Duration(hours: 1));
    expect(lista.placa('ABC123'), isNull);
  });

  test('pagina de a 100 y sobrevive al reinicio de la app', () async {
    at.porPagina = 1;
    await lista.sincronizar();
    expect(lista.totalPlacas, 2);

    final otra = ListaLocal(cliente: () async => null, reloj: () => ahora);
    await otra.cargar();
    expect(otra.placa('ABC123')!.driverName, 'Ana');
    expect(otra.finDeSemana('222')!.area, 'Planta');
  });

  test('MeshtasticService responde con la copia sin nodo ni internet',
      () async {
    await lista.sincronizar();
    at.caido = true;
    final mesh = MeshtasticService()
      ..listaLocal = lista
      ..airtableRespaldo = () async => null;
    final r = await mesh.checkPlateWithGateway(cedula: '1', placa: 'ABC123');
    expect(r.status, PlateCheckStatus.approved);
    expect(r.driverName, 'Ana');
    // Quien no está en la copia sigue el camino de siempre.
    final p = await mesh.checkPersonWithGateway(cedula: '999');
    expect(p.status, PlateCheckStatus.error);
  });

  test('el registro guarda los logs en un archivo de texto por día', () async {
    final dir = Directory.systemTemp.createTempSync('registro_test');
    final consola = debugPrint;
    addTearDown(() async {
      await RegistroLocal.cerrar();
      debugPrint = consola;
      dir.deleteSync(recursive: true);
    });
    await RegistroLocal.iniciar(carpeta: dir);
    await lista.sincronizar();
    lista.placa('ABC123');
    await RegistroLocal.volcar();

    final archivos = dir.listSync().whereType<File>().toList();
    expect(archivos.single.path, endsWith('.log'));
    final texto = archivos.single.readAsStringSync();
    expect(texto, contains('==== App iniciada ===='));
    expect(texto, contains('placa ABC123: AUTORIZADO por copia local'));
    expect(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d', multiLine: true)
        .allMatches(texto).length, greaterThanOrEqualTo(3));
  });
}
