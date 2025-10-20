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
      // 'normal_max': 500,
      // 'warning_min': 500,
      // 'warning_max': 750,
      // 'danger_min': 750,
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

  // 현재 센서 상태 계산 - GasThresholds 사용하여 통일
  SensorStatus get status {
    if (data == '--' || data.isEmpty) return SensorStatus.error;

    final numValue = double.tryParse(data);
    if (numValue == null) return SensorStatus.error;

    // GasThresholds를 사용하여 임계치 통일 관리
    final threshold = GasThresholds.thresholds[gasType];
    if (threshold == null) return SensorStatus.error;

    final normalMin = threshold['normal_min'] as num;
    final normalMax = threshold['normal_max'] as num;

    // 정상 범위 확인
    if (numValue >= normalMin && numValue <= normalMax) {
      return SensorStatus.normal;
    }

    // O2는 특별한 처리 필요 (위/아래 둘 다 경고/위험 범위)
    if (gasType.toLowerCase() == 'o2') {
      // 위험 범위: 23.5 초과 또는 19.5 미만
      if (numValue > 23.5 || numValue < 19.5) {
        return SensorStatus.danger;
      }
      // 경고 범위: 22~23.5 또는 19.5~20
      if ((numValue > 22 && numValue <= 23.5) ||
          (numValue >= 19.5 && numValue < 20)) {
        return SensorStatus.warning;
      }
      return SensorStatus.normal;
    }

    // 다른 가스들 (CO, H2S, CO2, LEL)
    final warningMin = threshold['warning_min'] as num?;
    final warningMax = threshold['warning_max'] as num?;
    final dangerMin = threshold['danger_min'] as num?;

    // 위험 범위 확인
    if (dangerMin != null && numValue > dangerMin) {
      return SensorStatus.danger;
    }

    // 경고 범위 확인
    if (warningMin != null &&
        warningMax != null &&
        numValue > warningMin &&
        numValue <= warningMax) {
      return SensorStatus.warning;
    }

    // 정상 범위를 벗어났지만 경고/위험에 해당하지 않는 경우
    return SensorStatus.warning;
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
