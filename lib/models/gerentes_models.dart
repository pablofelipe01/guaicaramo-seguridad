// Modelos del módulo Gerentes de Unidades Externas (UEA).
//
// El módulo es independiente de la malla Meshtastic y del gateway: trabaja con
// una copia local en el teléfono y se sincroniza directo con Airtable cuando
// hay internet (WiFi o datos).

/// Gerente/representante de una Unidad Externa (tabla
/// `Gerentes Unidades Externas`). Copia local para operar sin internet.
class Gerente {
  /// ID del registro en Airtable (`rec…`). Con él se vincula cada ingreso.
  final String recordId;
  final String cedula;
  final String nombre;
  final String uea;

  /// Placas registradas (en Airtable vienen en un solo texto separado por comas).
  final List<String> placas;
  final bool autorizado;

  const Gerente({
    required this.recordId,
    required this.cedula,
    required this.nombre,
    required this.uea,
    required this.placas,
    required this.autorizado,
  });

  /// "JJP240, kcl-232" → ["JJP240", "KCL232"] (mayúsculas, sin guiones).
  static List<String> parsePlacas(String raw) => raw
      .toUpperCase()
      .split(RegExp(r'[,;/\s]+'))
      .map((p) => p.replaceAll('-', '').trim())
      .where((p) => p.isNotEmpty)
      .toList();

  /// Texto normalizado para la búsqueda del vigilante.
  String get searchText =>
      '$nombre $cedula $uea ${placas.join(' ')}'.toLowerCase();

  Map<String, dynamic> toJson() => {
        'recordId': recordId,
        'cedula': cedula,
        'nombre': nombre,
        'uea': uea,
        'placas': placas,
        'autorizado': autorizado,
      };

  factory Gerente.fromJson(Map<String, dynamic> json) => Gerente(
        recordId: json['recordId'] as String,
        cedula: json['cedula'] as String? ?? '',
        nombre: json['nombre'] as String? ?? '',
        uea: json['uea'] as String? ?? '',
        placas: (json['placas'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const <String>[],
        autorizado: json['autorizado'] as bool? ?? false,
      );
}

/// Estado de sincronización de un evento (ingreso o salida) con Airtable.
enum SyncState {
  /// Guardado en el teléfono, falta subirlo a Airtable.
  pendiente,

  /// Ya quedó en Airtable.
  sincronizado,

  /// Airtable lo rechazó de forma definitiva (p. ej. el gerente fue borrado).
  /// No se reintenta; el vigilante puede descartarlo.
  rechazado,
}

/// Una visita de un gerente: ingreso y (cuando ocurra) salida. Se crea en el
/// teléfono aunque no haya internet; cada evento lleva su propio [SyncState].
/// Corresponde a una fila de `Ingresos Gerentes Unidades Externas`.
class GerenteVisita {
  /// ID local único.
  final String id;

  /// `recordId` del gerente en Airtable (para el campo vínculo `Gerente`).
  final String gerenteId;
  final String cedula;
  final String nombre;
  final String uea;

  /// Placa con la que ingresó (vacía si entró sin vehículo).
  final String placa;

  /// Hora del ingreso. Null si solo se registró la salida (el gerente entró por
  /// otra portería o antes de instalar la app).
  final DateTime? ingreso;
  DateTime? salida;
  final String? notaIngreso;
  String? notaSalida;

  /// ID de la fila en Airtable, cuando ya existe.
  String? airtableId;

  SyncState ingresoSync;
  SyncState? salidaSync;

  /// Un intento de crear la fila en Airtable quedó sin respuesta (pudo haberse
  /// guardado o no). Antes de reintentar se busca si ya existe, para no duplicar.
  bool creacionIncierta;

  /// La visita la registró otra portería: llegó al descargar de Airtable quién
  /// está dentro.
  final bool remota;

  /// Información para el vigilante (p. ej. "salida registrada en otra portería").
  String? aviso;

  /// Último motivo por el que no se pudo sincronizar.
  String? ultimoError;

  GerenteVisita({
    required this.id,
    required this.gerenteId,
    required this.cedula,
    required this.nombre,
    required this.uea,
    required this.placa,
    required this.ingreso,
    this.salida,
    this.notaIngreso,
    this.notaSalida,
    this.airtableId,
    this.ingresoSync = SyncState.pendiente,
    this.salidaSync,
    this.creacionIncierta = false,
    this.remota = false,
    this.aviso,
    this.ultimoError,
  });

  bool get dentro => salida == null;
  bool get tieneIngreso => ingreso != null;

  bool get ingresoPendiente => tieneIngreso && ingresoSync == SyncState.pendiente;
  bool get salidaPendiente => salida != null && salidaSync == SyncState.pendiente;
  bool get pendienteSync => ingresoPendiente || salidaPendiente;
  bool get rechazada =>
      ingresoSync == SyncState.rechazado || salidaSync == SyncState.rechazado;

  /// Hora del evento más reciente (para ordenar el historial).
  DateTime get ultimaHora => salida ?? ingreso!;

  Map<String, dynamic> toJson() => {
        'id': id,
        'gerenteId': gerenteId,
        'cedula': cedula,
        'nombre': nombre,
        'uea': uea,
        'placa': placa,
        'ingreso': ingreso?.toIso8601String(),
        'salida': salida?.toIso8601String(),
        'notaIngreso': notaIngreso,
        'notaSalida': notaSalida,
        'airtableId': airtableId,
        'ingresoSync': ingresoSync.name,
        'salidaSync': salidaSync?.name,
        'creacionIncierta': creacionIncierta,
        'remota': remota,
        'aviso': aviso,
        'ultimoError': ultimoError,
      };

  static SyncState? _syncFromName(String? name) => name == null
      ? null
      : SyncState.values.firstWhere(
          (s) => s.name == name,
          orElse: () => SyncState.pendiente,
        );

  static DateTime? _date(Object? raw) =>
      raw == null ? null : DateTime.parse(raw as String);

  factory GerenteVisita.fromJson(Map<String, dynamic> json) => GerenteVisita(
        id: json['id'] as String,
        gerenteId: json['gerenteId'] as String,
        cedula: json['cedula'] as String? ?? '',
        nombre: json['nombre'] as String? ?? '',
        uea: json['uea'] as String? ?? '',
        placa: json['placa'] as String? ?? '',
        ingreso: _date(json['ingreso']),
        salida: _date(json['salida']),
        notaIngreso: json['notaIngreso'] as String?,
        notaSalida: json['notaSalida'] as String?,
        airtableId: json['airtableId'] as String?,
        ingresoSync:
            _syncFromName(json['ingresoSync'] as String?) ?? SyncState.pendiente,
        salidaSync: _syncFromName(json['salidaSync'] as String?),
        creacionIncierta: json['creacionIncierta'] as bool? ?? false,
        remota: json['remota'] as bool? ?? false,
        aviso: json['aviso'] as String?,
        ultimoError: json['ultimoError'] as String?,
      );
}
