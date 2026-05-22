enum DeliveryStatus {
  sending,
  delivered,
  failed,
  none,
}

class ChatMessage {
  final String id;
  final String messageText;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  final int channel;
  final int? toNodeId;
  final bool isDirectMessage;
  final bool isMine;
  DeliveryStatus deliveryStatus;

  ChatMessage({
    String? id,
    required this.messageText,
    required this.fromNodeId,
    required this.fromNodeName,
    required this.timestamp,
    required this.channel,
    this.toNodeId,
    required this.isDirectMessage,
    required this.isMine,
    this.deliveryStatus = DeliveryStatus.none,
  }) : id = id ?? '${fromNodeId}_${timestamp.millisecondsSinceEpoch}';

  String get formattedTime {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String get formattedDate {
    final day = timestamp.day.toString().padLeft(2, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    final year = timestamp.year;
    return '$day/$month/$year';
  }

  bool isSameDay(ChatMessage other) {
    return timestamp.year == other.timestamp.year &&
        timestamp.month == other.timestamp.month &&
        timestamp.day == other.timestamp.day;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  Map<String, dynamic> toJson() => {
        'id': id,
        'messageText': messageText,
        'fromNodeId': fromNodeId,
        'fromNodeName': fromNodeName,
        'timestamp': timestamp.toIso8601String(),
        'channel': channel,
        'toNodeId': toNodeId,
        'isDirectMessage': isDirectMessage,
        'isMine': isMine,
        'deliveryStatus': deliveryStatus.name,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String?,
        messageText: json['messageText'] as String,
        fromNodeId: json['fromNodeId'] as int,
        fromNodeName: json['fromNodeName'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        channel: json['channel'] as int,
        toNodeId: json['toNodeId'] as int?,
        isDirectMessage: json['isDirectMessage'] as bool,
        isMine: json['isMine'] as bool,
        deliveryStatus: DeliveryStatus.values.firstWhere(
          (s) => s.name == json['deliveryStatus'],
          orElse: () => DeliveryStatus.none,
        ),
      );
}

class MeshNode {
  final int nodeId;
  final String nodeName;
  final bool isOnline;
  final DateTime? lastSeen;
  final int? batteryLevel;
  final double? voltage;

  // GPS (añadido para el mapa)
  final double? latitude;
  final double? longitude;
  final int? altitude;
  final DateTime? positionTime;

  MeshNode({
    required this.nodeId,
    required this.nodeName,
    this.isOnline = true,
    this.lastSeen,
    this.batteryLevel,
    this.voltage,
    this.latitude,
    this.longitude,
    this.altitude,
    this.positionTime,
  });

  String get displayName =>
      nodeName.isNotEmpty ? nodeName : 'Nodo !${nodeId.toRadixString(16)}';
  String get shortId => '!${nodeId.toRadixString(16)}';

  bool get isUsbPowered => batteryLevel != null && batteryLevel! > 100;
  bool get hasPosition => latitude != null && longitude != null;

  MeshNode copyWith({
    String? nodeName,
    bool? isOnline,
    DateTime? lastSeen,
    int? batteryLevel,
    double? voltage,
    double? latitude,
    double? longitude,
    int? altitude,
    DateTime? positionTime,
  }) {
    return MeshNode(
      nodeId: nodeId,
      nodeName: nodeName ?? this.nodeName,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      voltage: voltage ?? this.voltage,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      altitude: altitude ?? this.altitude,
      positionTime: positionTime ?? this.positionTime,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshNode && nodeId == other.nodeId;

  @override
  int get hashCode => nodeId.hashCode;
}

/// Punto único del track de sesión de un nodo. No persiste entre cierres.
class NodePositionPoint {
  final double latitude;
  final double longitude;
  final DateTime timestamp;

  NodePositionPoint(this.latitude, this.longitude, this.timestamp);
}

/// Acompañante de un conductor — persona que va en el mismo vehículo.
/// Se verifica contra la tabla Personas (CC). El nombre se llena desde
/// el resultado de la consulta si la persona está registrada.
class Acompanante {
  final String cedula;
  final String? nombre;

  const Acompanante({required this.cedula, this.nombre});

  Map<String, dynamic> toJson() => {
        'cedula': cedula,
        'nombre': nombre,
      };

  factory Acompanante.fromJson(Map<String, dynamic> json) => Acompanante(
        cedula: json['cedula'] as String,
        nombre: json['nombre'] as String?,
      );

  /// Render para mostrar / persistir: "CC - Nombre" o solo "CC".
  String get displayLine =>
      (nombre != null && nombre!.isNotEmpty) ? '$cedula - $nombre' : cedula;
}

/// Vehículo que entró por la portería. Reemplaza ActiveVisitor.
class VehicleEntry {
  final String cedula;
  final String placa;
  final DateTime entryTime;
  DateTime? exitTime;

  /// 'GATEWAY' si la placa estaba en la lista de Airtable; nombre del
  /// supervisor si fue aprobación manual.
  final String approvedBy;

  /// Lista de hasta 4 acompañantes registrados con esta entrada.
  final List<Acompanante> acompanantes;

  VehicleEntry({
    required this.cedula,
    required this.placa,
    required this.entryTime,
    required this.approvedBy,
    this.exitTime,
    this.acompanantes = const [],
  });

  bool get hasExited => exitTime != null;

  String get formattedEntryTime {
    final hour = entryTime.hour.toString().padLeft(2, '0');
    final minute = entryTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String? get formattedExitTime {
    if (exitTime == null) return null;
    final hour = exitTime!.hour.toString().padLeft(2, '0');
    final minute = exitTime!.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Map<String, dynamic> toJson() => {
        'cedula': cedula,
        'placa': placa,
        'entryTime': entryTime.toIso8601String(),
        'exitTime': exitTime?.toIso8601String(),
        'approvedBy': approvedBy,
        'acompanantes': acompanantes.map((a) => a.toJson()).toList(),
      };

  factory VehicleEntry.fromJson(Map<String, dynamic> json) {
    final acompananteList = (json['acompanantes'] as List<dynamic>?)
            ?.map((e) => Acompanante.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <Acompanante>[];
    final v = VehicleEntry(
      cedula: json['cedula'] as String,
      placa: json['placa'] as String,
      entryTime: DateTime.parse(json['entryTime'] as String),
      approvedBy: json['approvedBy'] as String? ?? 'GATEWAY',
      acompanantes: acompananteList,
    );
    if (json['exitTime'] != null) {
      v.exitTime = DateTime.parse(json['exitTime'] as String);
    }
    return v;
  }
}

/// Solicitud de aprobación manual al supervisor (cuando la placa no está
/// en la lista de Airtable). Reemplaza VisitorRequest.
class VehicleRequest {
  final int requestId;
  final String cedula;
  final String placa;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  /// Contexto opcional que el portero envía con la solicitud para que el
  /// supervisor entienda de qué se trata ("viene a entregar paquete", etc.).
  final String? porteroComment;
  bool isResponded;
  String? responseStatus; // APROBADO, NEGADO, PENDIENTE
  String? supervisorName;
  String? comment;

  /// CCs de acompañantes incluidos en la solicitud. Vacío si no hay.
  final List<String> acompananteCedulas;

  VehicleRequest({
    required this.requestId,
    required this.cedula,
    required this.placa,
    required this.fromNodeId,
    required this.fromNodeName,
    required this.timestamp,
    this.porteroComment,
    this.acompananteCedulas = const [],
    this.isResponded = false,
    this.responseStatus,
    this.supervisorName,
    this.comment,
  });

  String get formattedTime {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String get formattedDate {
    final day = timestamp.day.toString().padLeft(2, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    return '$day/$month';
  }

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'cedula': cedula,
        'placa': placa,
        'fromNodeId': fromNodeId,
        'fromNodeName': fromNodeName,
        'timestamp': timestamp.toIso8601String(),
        'porteroComment': porteroComment,
        'acompananteCedulas': acompananteCedulas,
        'isResponded': isResponded,
        'responseStatus': responseStatus,
        'supervisorName': supervisorName,
        'comment': comment,
      };

  factory VehicleRequest.fromJson(Map<String, dynamic> json) => VehicleRequest(
        requestId: json['requestId'] as int,
        cedula: json['cedula'] as String,
        placa: json['placa'] as String,
        fromNodeId: json['fromNodeId'] as int,
        fromNodeName: json['fromNodeName'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        porteroComment: json['porteroComment'] as String?,
        acompananteCedulas: (json['acompananteCedulas'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const <String>[],
        isResponded: json['isResponded'] as bool? ?? false,
        responseStatus: json['responseStatus'] as String?,
        supervisorName: json['supervisorName'] as String?,
        comment: json['comment'] as String?,
      );
}

enum PlateCheckStatus { approved, notApproved, timeout, error }

/// Resultado de [MeshtasticService.checkPlateWithGateway].
class PlateCheckResult {
  final PlateCheckStatus status;
  final String? driverName;
  final String? note;

  PlateCheckResult({
    required this.status,
    this.driverName,
    this.note,
  });

  bool get isApproved => status == PlateCheckStatus.approved;
  bool get isNotApproved => status == PlateCheckStatus.notApproved;
  bool get isTimeout => status == PlateCheckStatus.timeout;
  bool get isError => status == PlateCheckStatus.error;
}

/// Respuesta del supervisor a un [VehicleRequest] (transportada por chat).
class VehicleResponse {
  final String status; // APROBADO, NEGADO, PENDIENTE
  final String supervisorName;
  final String? comment;
  final int fromNodeId;
  final DateTime timestamp;

  VehicleResponse({
    required this.status,
    required this.supervisorName,
    this.comment,
    required this.fromNodeId,
    required this.timestamp,
  });

  bool get isApproved => status == 'APROBADO';
  bool get isDenied => status == 'NEGADO';
  bool get isPending => status == 'PENDIENTE';
}

// ============================================================================
// Peatones — paralelo a vehículos. Comparten estructura pero protocolo distinto.
// ============================================================================

/// Persona que entró a pie (sin vehículo). Paralelo a [VehicleEntry].
/// Sirve tanto para peatones regulares como para fin-de-semana
/// (diferenciados por [categoria]).
class PersonEntry {
  final String cedula;
  final String nombre;
  final DateTime entryTime;
  DateTime? exitTime;
  final String approvedBy;
  /// "PEATON" o "FIN_DE_SEMANA". Default "PEATON" para compatibilidad
  /// con entries persistidos antes de añadir este campo.
  final String categoria;

  PersonEntry({
    required this.cedula,
    required this.nombre,
    required this.entryTime,
    required this.approvedBy,
    this.exitTime,
    this.categoria = 'PEATON',
  });

  bool get hasExited => exitTime != null;

  String get formattedEntryTime {
    final hour = entryTime.hour.toString().padLeft(2, '0');
    final minute = entryTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String? get formattedExitTime {
    if (exitTime == null) return null;
    final hour = exitTime!.hour.toString().padLeft(2, '0');
    final minute = exitTime!.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Map<String, dynamic> toJson() => {
        'cedula': cedula,
        'nombre': nombre,
        'entryTime': entryTime.toIso8601String(),
        'exitTime': exitTime?.toIso8601String(),
        'approvedBy': approvedBy,
        'categoria': categoria,
      };

  factory PersonEntry.fromJson(Map<String, dynamic> json) {
    final v = PersonEntry(
      cedula: json['cedula'] as String,
      nombre: json['nombre'] as String? ?? '',
      entryTime: DateTime.parse(json['entryTime'] as String),
      approvedBy: json['approvedBy'] as String? ?? 'GATEWAY',
      categoria: json['categoria'] as String? ?? 'PEATON',
    );
    if (json['exitTime'] != null) {
      v.exitTime = DateTime.parse(json['exitTime'] as String);
    }
    return v;
  }
}

/// Solicitud de aprobación manual al supervisor para un peatón.
/// Paralelo a [VehicleRequest].
class PersonRequest {
  final int requestId;
  final String cedula;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  final String? porteroComment;
  bool isResponded;
  String? responseStatus;
  String? supervisorName;
  String? comment;

  PersonRequest({
    required this.requestId,
    required this.cedula,
    required this.fromNodeId,
    required this.fromNodeName,
    required this.timestamp,
    this.porteroComment,
    this.isResponded = false,
    this.responseStatus,
    this.supervisorName,
    this.comment,
  });

  String get formattedTime {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String get formattedDate {
    final day = timestamp.day.toString().padLeft(2, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    return '$day/$month';
  }

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'cedula': cedula,
        'fromNodeId': fromNodeId,
        'fromNodeName': fromNodeName,
        'timestamp': timestamp.toIso8601String(),
        'porteroComment': porteroComment,
        'isResponded': isResponded,
        'responseStatus': responseStatus,
        'supervisorName': supervisorName,
        'comment': comment,
      };

  factory PersonRequest.fromJson(Map<String, dynamic> json) => PersonRequest(
        requestId: json['requestId'] as int,
        cedula: json['cedula'] as String,
        fromNodeId: json['fromNodeId'] as int,
        fromNodeName: json['fromNodeName'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        porteroComment: json['porteroComment'] as String?,
        isResponded: json['isResponded'] as bool? ?? false,
        responseStatus: json['responseStatus'] as String?,
        supervisorName: json['supervisorName'] as String?,
        comment: json['comment'] as String?,
      );
}

/// Resultado de [MeshtasticService.checkPersonWithGateway].
/// Paralelo a [PlateCheckResult] pero con el nombre del titular.
/// También se usa para fin-de-semana, con [area] adicional.
class PersonCheckResult {
  final PlateCheckStatus status;
  final String? personName;
  final String? area;
  final String? note;

  PersonCheckResult({
    required this.status,
    this.personName,
    this.area,
    this.note,
  });

  bool get isApproved => status == PlateCheckStatus.approved;
  bool get isNotApproved => status == PlateCheckStatus.notApproved;
  bool get isTimeout => status == PlateCheckStatus.timeout;
  bool get isError => status == PlateCheckStatus.error;
}

/// Respuesta del supervisor a un [PersonRequest].
class PersonResponse {
  final String status;
  final String supervisorName;
  final String? comment;
  final int fromNodeId;
  final DateTime timestamp;

  PersonResponse({
    required this.status,
    required this.supervisorName,
    this.comment,
    required this.fromNodeId,
    required this.timestamp,
  });

  bool get isApproved => status == 'APROBADO';
  bool get isDenied => status == 'NEGADO';
  bool get isPending => status == 'PENDIENTE';
}

// ============================================================================
// Items — órdenes de servicio para sacar cosas de Guaicaramo.
// Un admin crea la fila en Airtable; el portero la ve en la pestaña Salidas
// y registra cuándo el item efectivamente sale.
// ============================================================================

/// Item autorizado para salir de Guaicaramo (orden de servicio).
class Item {
  final String numero;
  final String nombre;
  final String? concepto;
  final String? destino;
  final String? autorizadoPor;
  final String? area;
  bool usado;

  /// Si conocemos cuándo se autorizó. No siempre llega en el mensaje resumen.
  DateTime? fechaAutorizacion;

  /// Cuándo el portero registró la salida. Local.
  DateTime? fechaSalida;

  Item({
    required this.numero,
    required this.nombre,
    this.concepto,
    this.destino,
    this.autorizadoPor,
    this.area,
    this.usado = false,
    this.fechaAutorizacion,
    this.fechaSalida,
  });

  bool get hasExited => fechaSalida != null;

  String get title =>
      '#$numero — $nombre'.replaceAll('— —', '—').trim().replaceAll(RegExp(r'—\s*$'), '');

  Map<String, dynamic> toJson() => {
        'numero': numero,
        'nombre': nombre,
        'concepto': concepto,
        'destino': destino,
        'autorizadoPor': autorizadoPor,
        'area': area,
        'usado': usado,
        'fechaAutorizacion': fechaAutorizacion?.toIso8601String(),
        'fechaSalida': fechaSalida?.toIso8601String(),
      };

  factory Item.fromJson(Map<String, dynamic> json) => Item(
        numero: json['numero'] as String,
        nombre: json['nombre'] as String? ?? '',
        concepto: json['concepto'] as String?,
        destino: json['destino'] as String?,
        autorizadoPor: json['autorizadoPor'] as String?,
        area: json['area'] as String?,
        usado: json['usado'] as bool? ?? false,
        fechaAutorizacion: json['fechaAutorizacion'] != null
            ? DateTime.parse(json['fechaAutorizacion'] as String)
            : null,
        fechaSalida: json['fechaSalida'] != null
            ? DateTime.parse(json['fechaSalida'] as String)
            : null,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Item && other.numero == numero;

  @override
  int get hashCode => numero.hashCode;
}

/// Estado posible de una consulta de item al gateway.
enum ItemCheckStatus {
  authorized,    // existe, autorizado=true, usado=false → portero puede registrar salida
  alreadyUsed,   // existe pero ya fue marcado como usado (sale solo una vez)
  notAuthorized, // existe pero autorizado=false (admin no lo aprobó)
  notFound,      // numero no existe en Airtable
  timeout,
  error,
}

/// Resultado de [MeshtasticService.consultItemWithGateway].
class ItemCheckResult {
  final ItemCheckStatus status;
  final Item? item;
  final String? note;

  ItemCheckResult({required this.status, this.item, this.note});

  bool get isAuthorized => status == ItemCheckStatus.authorized;
  bool get isAlreadyUsed => status == ItemCheckStatus.alreadyUsed;
  bool get isNotAuthorized => status == ItemCheckStatus.notAuthorized;
  bool get isNotFound => status == ItemCheckStatus.notFound;
  bool get isTimeout => status == ItemCheckStatus.timeout;
  bool get isError => status == ItemCheckStatus.error;
}

class ChatDestination {
  final String displayName;
  final int? channel;
  final int? nodeId;
  final bool isChannel;

  const ChatDestination({
    required this.displayName,
    this.channel,
    this.nodeId,
    required this.isChannel,
  });

  static const ChatDestination primaryChannel = ChatDestination(
    displayName: 'Canal 0: Primary',
    channel: 0,
    isChannel: true,
  );

  static const ChatDestination supervisorsChannel = ChatDestination(
    displayName: 'Canal 1: Supervisores',
    channel: 1,
    isChannel: true,
  );

  static ChatDestination directMessage(MeshNode node) {
    return ChatDestination(
      displayName: 'DM: ${node.displayName}',
      nodeId: node.nodeId,
      isChannel: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatDestination &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          nodeId == other.nodeId;

  @override
  int get hashCode => Object.hash(channel, nodeId);
}
