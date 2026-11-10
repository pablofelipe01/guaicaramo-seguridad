import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/data_models.dart';
import 'consulta_airtable.dart';
import 'gerentes_service.dart';

/// Copia local de quién está autorizado (placas, personas y fin de semana),
/// descargada de Airtable en segundo plano. Con ella una consulta de alguien
/// autorizado se responde al instante, sin depender del internet ni de la
/// malla en ese momento.
///
/// Reglas de seguridad:
/// - Solo sirve para decir AUTORIZADO. Si alguien no está en la copia, la
///   consulta sigue su camino normal (gateway / Airtable): un recién
///   autorizado no se rechaza por tener la copia vieja.
/// - El vencimiento (`vence`) se revisa en el momento de la consulta.
/// - Una autorización revocada puede seguir saliendo AUTORIZADO hasta la
///   siguiente descarga ([intervalo]). Si las descargas fallan, la copia deja
///   de usarse cuando cumple [antiguedadMaxima].
class ListaLocal extends ChangeNotifier {
  ListaLocal({
    Future<ConsultaAirtable?> Function()? cliente,
    DateTime Function()? reloj,
  })  : _cliente =
            cliente ?? (() => GerentesService.instance.clienteConsultas()),
        _reloj = reloj ?? DateTime.now;

  /// Instancia de la app. No descarga nada hasta [iniciar].
  static final ListaLocal instance = ListaLocal();

  /// Cada cuánto se vuelve a descargar la lista.
  static const Duration intervalo = Duration(minutes: 5);

  /// Con datos más viejos que esto la copia no se usa.
  static const Duration antiguedadMaxima = Duration(minutes: 30);

  static const String _clave = 'lista_local_v1';

  final Future<ConsultaAirtable?> Function() _cliente;
  final DateTime Function() _reloj;

  ListasVigentes _listas = const ListasVigentes();
  DateTime? _actualizada;
  DateTime? _ultimoIntento;
  Future<bool>? _enCurso;
  Timer? _ticker;

  /// Cuándo se descargó la copia que hay ahora (null = nunca).
  DateTime? get actualizada => _actualizada;

  /// Edad de la copia. Null si no hay, o si el reloj del equipo retrocedió.
  Duration? get antiguedad {
    final at = _actualizada;
    if (at == null) return null;
    final edad = _reloj().difference(at);
    return edad.isNegative ? null : edad;
  }

  bool get utilizable {
    final edad = antiguedad;
    return edad != null && edad <= antiguedadMaxima;
  }

  int get totalPlacas => _listas.placas.length;
  int get totalPersonas => _listas.personas.length;
  int get totalFinDeSemana => _listas.finDeSemana.length;

  // ---------- Ciclo de vida ----------

  /// Carga la copia guardada y la mantiene al día mientras la app viva.
  Future<void> iniciar() async {
    await cargar();
    unawaited(sincronizar());
    _ticker ??= Timer.periodic(const Duration(minutes: 1), (_) {
      final edad = antiguedad;
      final vencida = edad == null || edad >= intervalo;
      // Tras un fallo se reintenta al minuto siguiente (el temporizador).
      if (vencida) unawaited(sincronizar());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> cargar() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_clave);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _listas = ListasVigentes.fromJson(json);
      _actualizada = DateTime.parse(json['actualizada'] as String);
      debugPrint('📒 [LISTA] Copia local cargada: $_resumen, '
          'descargada $_actualizada');
    } catch (e) {
      debugPrint('❌ [LISTA] No se pudo leer la copia local: $e');
    }
  }

  /// Descarga la lista completa. Devuelve true si quedó actualizada. Si
  /// falla, la copia anterior se conserva (y envejece).
  Future<bool> sincronizar() => _enCurso ??= _sincronizar().whenComplete(() {
        _enCurso = null;
      });

  Future<bool> _sincronizar() async {
    _ultimoIntento = _reloj();
    final api = await _cliente();
    if (api == null) return false; // sin token no hay de dónde descargar
    final reloj = Stopwatch()..start();
    try {
      final listas = await api.descargarVigentes();
      _listas = listas;
      _actualizada = _reloj();
      debugPrint('📒 [LISTA] Descargada en ${reloj.elapsed.inSeconds}s: '
          '$_resumen');
      await _guardar();
      notifyListeners();
      return true;
    } catch (e) {
      final edad = antiguedad;
      debugPrint('❌ [LISTA] Falló la descarga tras '
          '${reloj.elapsed.inSeconds}s: $e. Copia actual: '
          '${edad == null ? 'ninguna' : 'de hace ${_edad(edad)}'}'
          '${utilizable ? '' : ' (no se usa)'}');
      return false;
    }
  }

  /// Último intento de descarga, haya salido bien o no.
  DateTime? get ultimoIntento => _ultimoIntento;

  Future<void> _guardar() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _clave,
          jsonEncode({
            'actualizada': _actualizada!.toIso8601String(),
            ..._listas.toJson(),
          }));
    } catch (e) {
      debugPrint('❌ [LISTA] No se pudo guardar la copia local: $e');
    }
  }

  // ---------- Consultas ----------

  /// APROBADO si la placa está vigente en la copia; null si hay que
  /// consultar en línea.
  PlateCheckResult? placa(String placa) {
    final a = _vigente('placa', ConsultaAirtable.clavePlaca(placa), _listas.placas);
    if (a == null) return null;
    return PlateCheckResult(
        status: PlateCheckStatus.approved, driverName: a.nombre, note: _nota());
  }

  PersonCheckResult? persona(String cedula) {
    final a = _vigente(
        'persona', ConsultaAirtable.claveCedula(cedula), _listas.personas);
    if (a == null) return null;
    return PersonCheckResult(
        status: PlateCheckStatus.approved, personName: a.nombre, note: _nota());
  }

  PersonCheckResult? finDeSemana(String cedula) {
    final a = _vigente('fin de semana', ConsultaAirtable.claveCedula(cedula),
        _listas.finDeSemana);
    if (a == null) return null;
    return PersonCheckResult(
        status: PlateCheckStatus.approved,
        personName: a.nombre,
        area: a.area,
        note: _nota());
  }

  Autorizado? _vigente(String tipo, String clave, Map<String, Autorizado> lista) {
    final edad = antiguedad;
    if (edad == null || edad > antiguedadMaxima) {
      debugPrint('📒 [LISTA] $tipo $clave: copia local '
          '${edad == null ? 'no disponible' : 'vieja (${_edad(edad)})'} '
          '→ consulta en línea');
      return null;
    }
    final a = lista[clave];
    if (a == null) {
      debugPrint('📒 [LISTA] $tipo $clave: no está vigente en la copia local '
          '(${_edad(edad)}) → consulta en línea');
      return null;
    }
    if (ConsultaAirtable.vencida(a.vence, ahora: _reloj())) {
      debugPrint('📒 [LISTA] $tipo $clave: venció (${a.vence}) '
          '→ consulta en línea');
      return null;
    }
    debugPrint('📒 [LISTA] $tipo $clave: AUTORIZADO por copia local '
        '(${a.nombre}; datos de hace ${_edad(edad)}, '
        'vence ${a.vence ?? 'sin fecha'})');
    return a;
  }

  String _nota() => 'Lista local · datos de hace ${_edad(antiguedad!)}';

  String get _resumen => '$totalPlacas placas, $totalPersonas personas, '
      '$totalFinDeSemana fin de semana';

  static String _edad(Duration d) =>
      d.inMinutes < 1 ? 'menos de 1 min' : '${d.inMinutes} min';
}
