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

/// Vehículo que entró por la portería. Reemplaza ActiveVisitor.
class VehicleEntry {
  final String cedula;
  final String placa;
  final DateTime entryTime;
  DateTime? exitTime;

  /// 'GATEWAY' si la placa estaba en la lista de Airtable; nombre del
  /// supervisor si fue aprobación manual.
  final String approvedBy;

  VehicleEntry({
    required this.cedula,
    required this.placa,
    required this.entryTime,
    required this.approvedBy,
    this.exitTime,
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
      };

  factory VehicleEntry.fromJson(Map<String, dynamic> json) {
    final v = VehicleEntry(
      cedula: json['cedula'] as String,
      placa: json['placa'] as String,
      entryTime: DateTime.parse(json['entryTime'] as String),
      approvedBy: json['approvedBy'] as String? ?? 'GATEWAY',
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
  bool isResponded;
  String? responseStatus; // APROBADO, NEGADO, PENDIENTE
  String? supervisorName;
  String? comment;

  VehicleRequest({
    required this.requestId,
    required this.cedula,
    required this.placa,
    required this.fromNodeId,
    required this.fromNodeName,
    required this.timestamp,
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
