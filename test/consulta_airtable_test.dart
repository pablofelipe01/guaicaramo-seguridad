import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guaicaramo_control/models/data_models.dart';
import 'package:guaicaramo_control/services/consulta_airtable.dart';
import 'package:guaicaramo_control/services/gerentes_airtable.dart';
import 'package:guaicaramo_control/services/meshtastic_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// IDs reales de campos (si cambian en el cliente, estas pruebas lo detectan).
const _pPlaca = 'placa';
const _pConductor = 'fldmGgGbio6vNBEsq';
const _pAutorizado = 'fldjJ7Kfb2lf6hZHQ';
const _pVence = 'fldHvJqZEmYIfOLqB';
const _pEstado = 'fldb2cefOrqgc4j20';
const _pNodo = 'fldsEEag2QU6LKx9w';
const _pNotificado = 'fldzjmFvr17ZAue4S';
const _eNombre = 'fldwq6QE6HTEY3bUg';
const _eAutorizado = 'fldZPZd0y8SrgVcC4';
const _fNombre = 'fldm0UoeANFbWz0DM';
const _fArea = 'fldnjUUAySUdWpCOD';
const _fEstado = 'fldMCGs10ZL3IALqK';

/// Airtable falso: responde a cada tabla con las filas dadas (ya en el orden
/// en que Airtable las devolvería) y guarda los PATCH.
class FakeAirtable {
  final Map<String, List<Map<String, dynamic>>> filas = {};
  final List<(String, Map<String, dynamic>)> patches = [];
  final List<Uri> gets = [];
  int? forzarStatus;

  late final http.Client client = MockClient((req) async {
    if (forzarStatus != null) {
      return http.Response('{"error":"X"}', forzarStatus!);
    }
    final partes = req.url.pathSegments; // v0, base, tabla[, id]
    if (req.method == 'GET') {
      gets.add(req.url);
      return http.Response(
          jsonEncode({'records': filas[partes[2]] ?? const []}), 200);
    }
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    patches.add((partes[3], body['fields'] as Map<String, dynamic>));
    return http.Response(jsonEncode({'id': partes[3], 'fields': {}}), 200);
  });

  ConsultaAirtable get api => ConsultaAirtable(token: 'patTEST', client: client);
}

String _iso(DateTime d) => d.toUtc().toIso8601String();

void main() {
  late FakeAirtable at;
  final manana = DateTime.now().add(const Duration(days: 1));
  final ayer = DateTime.now().subtract(const Duration(days: 1));

  setUp(() => at = FakeAirtable());

  group('placa', () {
    test('busca en mayúsculas en la tabla Placas', () async {
      await at.api.placa("abc12'3");
      final url = at.gets.single;
      expect(url.pathSegments[2], ConsultaAirtable.tablaPlacas);
      expect(url.queryParameters['filterByFormula'], "UPPER({$_pPlaca}) = 'ABC123'");
      expect(url.queryParameters['sort[0][field]'], _pVence);
    });

    test('sin filas → NO_REGISTRADO', () async {
      final r = await at.api.placa('ABC123');
      expect(r.status, PlateCheckStatus.notRegistered);
    });

    test('prefiere la fila vigente aunque no sea la primera', () async {
      at.filas[ConsultaAirtable.tablaPlacas] = [
        {'id': 'rec1', 'fields': {_pConductor: 'Viejo', _pAutorizado: true, _pVence: _iso(ayer)}},
        {'id': 'rec2', 'fields': {_pConductor: 'Ana', _pAutorizado: true, _pVence: _iso(manana)}},
      ];
      final r = await at.api.placa('ABC123');
      expect(r.status, PlateCheckStatus.approved);
      expect(r.driverName, 'Ana');
      expect(at.patches, isEmpty);
    });

    test('RECHAZADO no levanta alerta', () async {
      at.filas[ConsultaAirtable.tablaPlacas] = [
        {'id': 'rec1', 'fields': {_pConductor: 'Ana', _pEstado: 'RECHAZADO'}},
      ];
      final r = await at.api.placa('ABC123');
      expect(r.status, PlateCheckStatus.rejected);
      expect(at.patches, isEmpty);
    });

    test('vencida → SIN_AUTORIZACION y alerta a recepción con el nodo', () async {
      at.filas[ConsultaAirtable.tablaPlacas] = [
        {'id': 'rec1', 'fields': {_pConductor: 'Ana', _pAutorizado: true, _pVence: _iso(ayer)}},
      ];
      final r = await at.api.placa('ABC123', nodoOrigen: '!0000abcd');
      expect(r.status, PlateCheckStatus.registeredUnauthorized);
      expect(r.driverName, 'Ana');
      await pumpEventQueue();
      expect(at.patches.single.$1, 'rec1');
      expect(at.patches.single.$2, {
        _pEstado: 'PENDIENTE',
        _pNodo: '!0000abcd',
        _pNotificado: false,
      });
    });
  });

  test('persona aprobada devuelve el nombre', () async {
    at.filas[ConsultaAirtable.tablaPersonas] = [
      {'id': 'rec1', 'fields': {_eNombre: 'Luis', _eAutorizado: true}},
    ];
    final r = await at.api.persona('123');
    expect(r.status, PlateCheckStatus.approved);
    expect(r.personName, 'Luis');
  });

  group('fin de semana', () {
    test('estado vacío vale', () async {
      at.filas[ConsultaAirtable.tablaFinDeSemana] = [
        {'id': 'rec1', 'fields': {_fNombre: 'Eva', _fArea: 'Planta'}},
      ];
      final r = await at.api.finDeSemana('123');
      expect(r.status, PlateCheckStatus.approved);
      expect(r.area, 'Planta');
    });

    test('PENDIENTE → SIN_AUTORIZACION sin volver a cambiar el estado', () async {
      at.filas[ConsultaAirtable.tablaFinDeSemana] = [
        {'id': 'rec1', 'fields': {_fNombre: 'Eva', _fEstado: 'PENDIENTE'}},
      ];
      final r = await at.api.finDeSemana('123');
      expect(r.status, PlateCheckStatus.registeredUnauthorized);
      await pumpEventQueue();
      expect(at.patches, isEmpty); // sin nodo y ya PENDIENTE: nada que escribir
    });
  });

  test('token sin acceso lanza AirtableException de credenciales', () async {
    at.forzarStatus = 403;
    expect(
      () => at.api.placa('ABC123'),
      throwsA(isA<AirtableException>()
          .having((e) => e.tipo, 'tipo', FalloAirtable.credenciales)),
    );
  });

  test('vencida: fecha sola vale hasta el fin del día', () {
    final ahora = DateTime.utc(2026, 10, 27, 15);
    expect(ConsultaAirtable.vencida('2026-10-27', ahora: ahora), isFalse);
    expect(ConsultaAirtable.vencida('2026-10-26', ahora: ahora), isTrue);
    expect(ConsultaAirtable.vencida('2026-10-27T14:00:00.000Z', ahora: ahora), isTrue);
    expect(ConsultaAirtable.vencida('2026-10-27T16:00:00.000Z', ahora: ahora), isFalse);
    expect(ConsultaAirtable.vencida(null, ahora: ahora), isFalse);
    expect(ConsultaAirtable.vencida('basura', ahora: ahora), isFalse);
  });

  group('MeshtasticService sin nodo', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('consulta directo en Airtable', () async {
      at.filas[ConsultaAirtable.tablaPlacas] = [
        {'id': 'rec1', 'fields': {_pConductor: 'Ana', _pAutorizado: true}},
      ];
      final mesh = MeshtasticService()..airtableRespaldo = () async => at.api;
      final r = await mesh.checkPlateWithGateway(cedula: '1', placa: 'ABC123');
      expect(r.status, PlateCheckStatus.approved);
      expect(r.driverName, 'Ana');
    });

    test('sin token conserva el error de siempre', () async {
      final mesh = MeshtasticService()..airtableRespaldo = () async => null;
      final r = await mesh.checkPersonWithGateway(cedula: '1');
      expect(r.status, PlateCheckStatus.error);
      expect(r.note, 'Sin conexión al nodo');
    });
  });
}
