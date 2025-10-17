import 'package:flutter/material.dart';

// 가스 타입별 임계값 설정
class GasThresholds {
  static const Map<String, Map<String, dynamic>> thresholds = {
    'CO': {
      'normal_min': 0,
      'normal_max': 30,
      'warning_min': 30,
      'warning_max': 200,
      'danger_min': 200,
      'unit': 'ppm',
      'color': Colors.green,
      'icon': Icons.air,
    },
    'O2': {
      'normal_min': 20,
      'normal_max': 22,
      'warning_min_low': 19.5,
      'warning_max_low': 20,
      'warning_min_high': 22,
      'warning_max_high': 23.5,
      'danger_max': 23.5,
      'danger_min': 19.5,
      'unit': '%',
      'color': Colors.orange,
      'icon': Icons.bubble_chart,
    },
    'H2S': {
      'normal_min': 0,
      'normal_max': 5,
      'warning_min': 5,
      'warning_max': 50,
      'danger_min': 50,
      'unit': 'ppm',
      'color': Colors.green,
      'icon': Icons.warning,
    },
    'CO2': {
      'normal_min': 0,
      'normal_max': 1500,
      'warning_min': 1500,
      'warning_max': 5000,
      'danger_min': 5000,
      'unit': 'ppm',
      'color': Colors.red,
      'icon': Icons.cloud,
    },
    'LEL': {
      'normal_min': 0,
      'normal_max': 10,
      'warning_min': 10,
      'warning_max': 25,
      'danger_min': 25,
      'unit': '%',
      'color': Colors.green,
      'icon': Icons.local_fire_department,
    },
  };

  static String getGasType(String modelName) {
    if (modelName.contains('LEL')) return 'LEL';
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

    // 가스별 새로운 범위 기준으로 상태 계산
    switch (gasType) {
      case 'CO':
        if (numValue >= 0 && numValue <= 30) return SensorStatus.normal;
        if (numValue > 30 && numValue <= 200) return SensorStatus.warning;
        if (numValue > 200) return SensorStatus.danger;
        break;

      case 'O2':
        if (numValue >= 20 && numValue <= 22) return SensorStatus.normal;
        if ((numValue >= 19.5 && numValue < 20) ||
            (numValue > 22 && numValue <= 23.5)) {
          return SensorStatus.warning;
        }
        if (numValue < 19.5 || numValue > 23.5) return SensorStatus.danger;
        break;

      case 'H2S':
        if (numValue >= 0 && numValue <= 5) return SensorStatus.normal;
        if (numValue > 5 && numValue <= 50) return SensorStatus.warning;
        if (numValue > 50) return SensorStatus.danger;
        break;

      case 'CO2':
        if (numValue >= 0 && numValue <= 1500) return SensorStatus.normal;
        if (numValue > 1500 && numValue <= 5000) return SensorStatus.warning;
        if (numValue > 5000) return SensorStatus.danger;
        break;

      default:
        // 기본적으로 normal_min, normal_max 사용
        final threshold = thresholdInfo;
        if (threshold == null) return SensorStatus.error;

        final normalMin = threshold['normal_min'] as num;
        final normalMax = threshold['normal_max'] as num;

        if (numValue >= normalMin && numValue <= normalMax) {
          return SensorStatus.normal;
        }

        final warningMax = threshold['warning_max'] as num?;
        final dangerMin = threshold['danger_min'] as num?;

        if (warningMax != null && numValue <= warningMax) {
          return SensorStatus.warning;
        }

        if (dangerMin != null && numValue > dangerMin) {
          return SensorStatus.danger;
        }

        return SensorStatus.warning;
    }

    return SensorStatus.error;
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
