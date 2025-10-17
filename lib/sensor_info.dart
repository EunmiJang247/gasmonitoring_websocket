// 센서 정보 모델
class SensorInfo {
  final String portName;
  final String modelName;
  final String serialNumber;
  String data;
  String lastUpdateTime;

  SensorInfo({
    required this.portName,
    required this.modelName,
    required this.serialNumber,
    this.data = '--',
    this.lastUpdateTime = '--',
  });

  factory SensorInfo.fromJson(Map<String, dynamic> json) {
    return SensorInfo(
      portName: json['portName'] ?? '',
      modelName: json['modelName'] ?? '',
      serialNumber: json['serialNumber'] ?? '',
    );
  }

  String get topicPath => '/topic/sensor/$modelName/$portName/$serialNumber';
  String get displayName => '$modelName ($portName)';
}
