class TelemetryPayload {
  final String deviceId;
  final double lat;
  final double lng;
  final double peakJerk;
  final double dsr;
  final double rGyro;
  final String? vehicleModel;
  final String? tyreSize;

  TelemetryPayload({
    required this.deviceId,
    required this.lat,
    required this.lng,
    required this.peakJerk,
    required this.dsr,
    required this.rGyro,
    this.vehicleModel,
    this.tyreSize,
  });

  Map<String, dynamic> toJson() {
    return {
      'device_id': deviceId,
      'lat': lat,
      'lng': lng,
      'peak_jerk': peakJerk,
      'dsr': dsr,
      'r_gyro': rGyro,
      'vehicle_model': vehicleModel ?? 'Unknown',
      'tyre_size': tyreSize ?? 'Unknown',
    };
  }
}

class Hazard {
  final int id;
  final String type;
  final String status;
  final String size;
  final double lat;
  final double lng;

  Hazard({
    required this.id,
    required this.type,
    required this.status,
    required this.size,
    required this.lat,
    required this.lng,
  });

  factory Hazard.fromJson(Map<String, dynamic> json) {
    return Hazard(
      id: json['id'],
      type: json['type'],
      status: json['status'],
      size: json['size'] ?? 'unknown',
      lat: json['lat'],
      lng: json['lng'],
    );
  }
}
