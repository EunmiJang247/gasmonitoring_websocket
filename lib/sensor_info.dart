import 'package:flutter/material.dart';

// 가스 타입별 임계값 설정
class GasThresholds {
  static const Map<String, Map<String, dynamic>> thresholds = {
    'CO': {
      'normal_min': 0,
      'normal_max': 25,
      'unit': 'ppm',
      'color': Colors.green,
      'icon': Icons.air,
    },
    'O2': {
      'normal_min': 18,
      'normal_max': 23.5,
      'unit': '%',
      'color': Colors.orange,
      'icon': Icons.bubble_chart,
    },
    'H2S': {
      'normal_min': 0,
      'normal_max': 10,
      'unit': 'ppm',
      'color': Colors.green,
      'icon': Icons.warning,
    },
    'CO2': {
      'normal_min': 0,
      'normal_max': 1000,
      'unit': 'ppm',
      'color': Colors.red,
      'icon': Icons.cloud,
    },
  };

  static String getGasType(String modelName) {
    if (modelName.contains('CO2')) return 'CO2';
    if (modelName.contains('CO')) return 'CO';
    if (modelName.contains('O2')) return 'O2';
    if (modelName.contains('H2S')) return 'H2S';
    return 'UNKNOWN';
  }
}

// 센서 상태 열거형
enum SensorStatus {
  normal, // 정상
  warning, // 경고 (±20% 범위)
  danger, // 위험 (±20% 초과)
  error, // 오류 (데이터 없음)
}

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

  // 가스 타입 가져오기
  String get gasType => GasThresholds.getGasType(modelName);

  // 임계값 정보 가져오기
  Map<String, dynamic>? get thresholdInfo => GasThresholds.thresholds[gasType];

  // 현재 센서 상태 계산
  SensorStatus get status {
    if (data == '--' || data.isEmpty) return SensorStatus.error;

    final numValue = double.tryParse(data);
    if (numValue == null) return SensorStatus.error;

    final threshold = thresholdInfo;
    if (threshold == null) return SensorStatus.error;

    final normalMin = threshold['normal_min'] as num;
    final normalMax = threshold['normal_max'] as num;

    // 정상 범위
    if (numValue >= normalMin && numValue <= normalMax) {
      return SensorStatus.normal;
    }

    // 경고 범위 (±20%)
    final warningMinLow = normalMin * 0.8;
    final warningMaxHigh = normalMax * 1.2;

    if (numValue >= warningMinLow && numValue <= warningMaxHigh) {
      return SensorStatus.warning;
    }

    // 위험 범위
    return SensorStatus.danger;
  }

  // 상태별 색상
  Color get statusColor {
    switch (status) {
      case SensorStatus.normal:
        return Colors.green;
      case SensorStatus.warning:
        return Colors.orange;
      case SensorStatus.danger:
        return Colors.red;
      case SensorStatus.error:
        return Colors.grey;
    }
  }

  // 상태별 텍스트
  String get statusText {
    switch (status) {
      case SensorStatus.normal:
        return '정상';
      case SensorStatus.warning:
        return '경고';
      case SensorStatus.danger:
        return '위험';
      case SensorStatus.error:
        return '오류';
    }
  }

  // 단위 포함 데이터 표시
  String get dataWithUnit {
    if (data == '--' || data.isEmpty) return '--';
    final unit = thresholdInfo?['unit'] ?? '';
    return '$data $unit';
  }

  // 정상 범위 텍스트
  String get normalRangeText {
    final threshold = thresholdInfo;
    if (threshold == null) return '';
    final unit = threshold['unit'] ?? '';
    return '정상: ${threshold['normal_min']}~${threshold['normal_max']} $unit';
  }
}
