import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show stdout;
import 'package:stomp_dart_client/stomp.dart';
import 'package:stomp_dart_client/stomp_config.dart';
import 'package:stomp_dart_client/stomp_frame.dart';
import 'package:http/http.dart' as http;
import 'sensor_info.dart';
import 'settings_page.dart';

void main() {
  runApp(const MyApp());
}

// 통합 로그 함수
void logMessage(String message, {String? name}) {
  final timestamp = DateTime.now().toString().substring(11, 19);
  final logLine = '[$timestamp] ${name != null ? '[$name] ' : ''}$message';

  // 콘솔 출력 (브라우저)
  debugPrint(logLine);

  // Developer log (브라우저)
  developer.log(message, name: name ?? 'GasMonitoring');

  // stdout 출력 시도 (웹에서는 작동하지 않지만 데스크톱에서는 작동)
  try {
    stdout.writeln(logLine);
  } catch (e) {
    // 웹에서는 stdout이 없으므로 무시
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gas Monitoring',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const GasMonitoringPage(),
    );
  }
}

class GasMonitoringPage extends StatefulWidget {
  const GasMonitoringPage({super.key});

  @override
  State<GasMonitoringPage> createState() => _GasMonitoringPageState();
}

class _GasMonitoringPageState extends State<GasMonitoringPage> {
  // ---- 서버 설정 ----
  String _serverIp = 'localhost';
  String _serverPort = '8081';

  // ---- 동적 센서 관리 ----
  List<SensorInfo> _sensors = [];
  bool _sensorsLoaded = false;
  String _sensorLoadError = '';

  // ---- 가스 데이터 관리 ----
  Map<String, Map<String, String>> _sensorGroups = {}; // 복합가스센서용
  Map<String, Map<String, String>> _lelSensors = {}; // LEL센서용
  Map<String, String> _sensorGroupAlarms = {};
  String _lastUpdateTime = '--';

  // ---- UI 상태 ----
  String _connectionStatus = '센서 정보 로딩중...';
  bool _isWebSocketConnected = false;

  // ---- 개별 센서 구독 상태 추적 ----
  Map<String, DateTime> _lastDataReceived = {}; // 센서별 마지막 데이터 수신 시간
  Map<String, bool> _subscriptionActive = {}; // 센서별 구독 활성 상태
  Timer? _subscriptionHealthChecker; // 구독 상태 체크 타이머

  // ---- STOMP ----
  StompClient? _stomp;
  StreamSubscription? _heartbeatTicker;
  Timer? _retryTimer;
  bool _isConnecting = false;

  String get _wsUrl => 'ws://$_serverIp:$_serverPort/ws/sensor';
  String get _apiUrl => 'http://$_serverIp:$_serverPort/api/sensor/mappings';

  @override
  void initState() {
    super.initState();
    _loadSensors();
  }

  @override
  void dispose() {
    _heartbeatTicker?.cancel();
    _retryTimer?.cancel();
    _subscriptionHealthChecker?.cancel();
    _stomp?.deactivate();
    super.dispose();
  }

  // ------------------ 센서 정보 로딩 ------------------
  Future<void> _loadSensors() async {
    setState(() {
      _connectionStatus = '센서 정보 로딩중...';
      _sensorsLoaded = false;
      _sensorLoadError = '';
    });

    try {
      print('=== 센서 정보 로딩 시작 ===');
      print('API URL: $_apiUrl');
      print('서버: $_serverIp:$_serverPort');

      final response = await http
          .get(
            Uri.parse(_apiUrl),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));

      print('HTTP 응답 코드: ${response.statusCode}');
      print('HTTP 응답 헤더: ${response.headers}');
      print('HTTP 응답 바디: ${response.body}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = jsonDecode(response.body);
        print('파싱된 응답 데이터: $responseData');

        if (responseData['code'] == 200 && responseData['data'] != null) {
          final List<dynamic> sensorsJson =
              responseData['data']['sensors'] ?? [];

          print('센서 배열 길이: ${sensorsJson.length}');
          print('센서 원본 데이터: $sensorsJson');

          setState(() {
            _sensors = sensorsJson
                .map((json) => SensorInfo.fromJson(json))
                .where(
                  (sensor) => !sensor.modelName.toLowerCase().contains('error'),
                )
                .toList();
            _sensorsLoaded = true;
            _connectionStatus = '센서 ${_sensors.length}개 로딩 완료';
          });

          print('--- 로딩된 센서 목록 ---');
          for (int i = 0; i < _sensors.length; i++) {
            final sensor = _sensors[i];
            print('센서 ${i + 1}:');
            print('  - 표시명: ${sensor.displayName}');
            print('  - 모델명: ${sensor.modelName}');
            print('  - 포트명: ${sensor.portName}');
            print('  - 시리얼: ${sensor.serialNumber}');
            print('  - 토픽: ${sensor.topicPath}');
            print('  - 가스타입: ${sensor.gasType}');
          }

          // 센서 로딩 완료 후 WebSocket 연결 시작
          if (_sensors.isNotEmpty) {
            print('센서 로딩 완료 → 웹소켓 연결 시작');
            _connectStomp();
          } else {
            setState(() {
              _connectionStatus = '등록된 센서가 없습니다';
            });
            print('경고: 등록된 센서가 없습니다');
          }
          print('=== 센서 정보 로딩 완료 ===\n');
        } else {
          throw Exception(
            'API 응답 오류: ${responseData['message'] ?? 'Unknown error'}',
          );
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      setState(() {
        _sensorLoadError = e.toString();
        _connectionStatus = '센서 로딩 실패: $e';
        _sensorsLoaded = false;
      });
      print('ERROR: 센서 로딩 실패 - $e');
      print('=== 센서 정보 로딩 실패 ===\n');
    }
  }

  // ------------------ 연결/구독 ------------------
  void _connectStomp() {
    if (_isConnecting || !_sensorsLoaded) return;
    _isConnecting = true;
    setState(() => _connectionStatus = 'WebSocket 연결중...');

    _createAndActivateClient();
  }

  void _createAndActivateClient() {
    _stomp?.deactivate(); // 1. 기존 연결 완전히 해제

    final config = StompConfig(
      // 2. 새로운 STOMP 설정 생성
      url: _wsUrl, // WebSocket URL
      onConnect: _onConnect, // 연결 성공 콜백
      onStompError: _onStompError,
      onWebSocketError: _onWsError,
      onWebSocketDone: _onWsDone,
      reconnectDelay: const Duration(seconds: 3),
      heartbeatIncoming: const Duration(seconds: 10),
      heartbeatOutgoing: const Duration(seconds: 10),
      webSocketConnectHeaders: const {'Sec-WebSocket-Protocol': 'v12.stomp'},
    );

    _stomp = StompClient(config: config); // 3. 새로운 클라이언트 생성
    _stomp!.activate(); // 4. WebSocket 연결 시작
  }

  void _onConnect(StompFrame frame) {
    _isConnecting = false;
    _retryTimer?.cancel();

    print('=== 웹소켓 연결 성공 ===');
    print('서버: $_serverIp:$_serverPort');
    print('프레임 헤더: ${frame.headers}');
    print('프레임 바디: ${frame.body}');

    setState(() {
      _isWebSocketConnected = true;
      _connectionStatus = 'WebSocket 연결됨';
    });

    // ✅ 모든 센서들을 구독
    print('--- 센서 구독 시작 ---');
    for (int i = 0; i < _sensors.length; i++) {
      final sensor = _sensors[i];
      print('센서 ${i + 1}/${_sensors.length}: ${sensor.displayName}');
      print('  - 토픽: ${sensor.topicPath}');
      print('  - 모델: ${sensor.modelName}');
      print('  - 포트: ${sensor.portName}');
      print('  - 시리얼: ${sensor.serialNumber}');

      _stomp?.subscribe(
        // ← 구독도 자동으로 다시 시작
        destination: sensor.topicPath,
        headers: const {'ack': 'auto'},
        callback: (msg) {
          print(
            '센서 ${i + 1} 메시지 수신: ${msg.body?.substring(0, 100)}${(msg.body?.length ?? 0) > 100 ? '...' : ''}',
          );
          _updateSensor(i, msg.body);
        },
      );
      print('  ✓ 구독 완료');
    }

    _heartbeatTicker?.cancel();
    _heartbeatTicker = Stream.periodic(const Duration(seconds: 15)).listen((_) {
      // 15초마다 로그를 출력해서 연결이 유지되고 있음을 확인
      // 구독이 존재하는한 15초마다 한번씩 실행됨
      print(
        '[HEARTBEAT] ${DateTime.now().toString().substring(11, 19)} - 연결 유지 중',
      );
    });

    setState(() {
      _connectionStatus = '${_sensors.length}개 센서 구독 완료';
    });

    // 구독 상태 헬스체크 시작
    _startSubscriptionHealthCheck();

    print('=== 웹소켓 구독 완료 ===\n');
  }

  void _onStompError(StompFrame frame) {
    // WebSocket은 연결되었지만 STOMP 프로토콜에서 서버가 ERROR 프레임을 보낼 때
    _isConnecting = false;
    _heartbeatTicker?.cancel();
    _subscriptionHealthChecker?.cancel(); // 구독 헬스체크 중단
    setState(() {
      _isWebSocketConnected = false;
      _connectionStatus = 'STOMP 오류: ${frame.body ?? frame.headers.toString()}';
    });
  }

  void _onWsError(dynamic error, [dynamic frame]) {
    // 발생시점
    // 1. 서버가 꺼져있음 → _onWsError 발생
    // 2. 네트워크 연결 불가 → _onWsError 발생
    // 3. 방화벽 차단 → _onWsError 발생
    // 4. WebSocket 핸드셰이크 실패 → _onWsError 발생
    // 5. 연결 중간에 끊어짐 → _onWsError 발생

    debugPrint('WebSocket error: $error');
    _heartbeatTicker?.cancel();
    _subscriptionHealthChecker?.cancel(); // 구독 헬스체크 중단
    setState(() {
      _isWebSocketConnected = false;
      _connectionStatus = '연결 오류: $error';
    });
    _scheduleRetry();
  }

  void _onWsDone() {
    // 발생시점
    // 1. 서버가 정상적으로 연결 종료
    // 2. 클라이언트가 deactivate() 호출
    // 3. 프로토콜에 따른 정상 종료
    // 4. 타임아웃으로 인한 정상 종료

    debugPrint('WebSocket closed');
    _heartbeatTicker?.cancel();
    _subscriptionHealthChecker?.cancel(); // 구독 헬스체크 중단
    setState(() {
      _isWebSocketConnected = false;
      _connectionStatus = '연결 끊어짐';
    });
    _scheduleRetry();
  }

  // ------------------ 개별 센서 구독 관리 ------------------

  // 특정 센서만 재구독 (WebSocket 연결 유지)
  void _resubscribeSingleSensor(int sensorIndex) {
    if (sensorIndex >= _sensors.length || !_isWebSocketConnected) return;

    final sensor = _sensors[sensorIndex];
    final sensorId = '${sensor.modelName}_${sensor.portName}';

    print('개별 센서 재구독 시도: $sensorId (${sensor.displayName})');

    // 해당 센서만 다시 구독
    _stomp?.subscribe(
      destination: sensor.topicPath, // ← 이게 구독
      headers: const {'ack': 'auto'},
      callback: (msg) {
        print(
          '센서 ${sensorIndex + 1} 메시지 수신: ${msg.body?.substring(0, 100)}${(msg.body?.length ?? 0) > 100 ? '...' : ''}',
        );
        _updateSensor(sensorIndex, msg.body);
      },
    );

    print('개별 센서 재구독 완료: $sensorId');
  }

  // 실패한 센서들만 재구독
  void _resubscribeFailedSensors() {
    if (!_isWebSocketConnected) {
      print('WebSocket 연결이 없어 개별 재구독 불가');
      return;
    }

    final now = DateTime.now();
    List<int> failedSensorIndexes = [];

    // 30초 이상 데이터 안 온 센서들 찾기
    for (int i = 0; i < _sensors.length; i++) {
      final sensor = _sensors[i];
      final sensorId = '${sensor.modelName}_${sensor.portName}';
      final lastReceived = _lastDataReceived[sensorId];

      // 30초 이상 데이터 안 오면 구독 문제로 판단
      if (lastReceived == null || now.difference(lastReceived).inSeconds > 30) {
        failedSensorIndexes.add(i);
        _subscriptionActive[sensorId] = false;
      }
    }

    if (failedSensorIndexes.isNotEmpty) {
      print('실패한 센서 ${failedSensorIndexes.length}개 재구독 시작');
      for (int index in failedSensorIndexes) {
        _resubscribeSingleSensor(index);
      }

      setState(() {
        _connectionStatus = '${failedSensorIndexes.length}개 센서 재구독 시도';
      });
    } else {
      print('모든 센서 구독 정상');
    }
  }

  // 구독 상태 체크 시작
  void _startSubscriptionHealthCheck() {
    _subscriptionHealthChecker?.cancel();
    _subscriptionHealthChecker = Timer.periodic(
      const Duration(seconds: 30), // 30초마다 체크
      (_) => _checkSubscriptionHealth(),
    );
    print('구독 헬스체크 시작 (30초 간격)');
  }

  // 구독 상태 체크 및 문제 센서 재구독
  void _checkSubscriptionHealth() {
    if (!_isWebSocketConnected) return;

    final now = DateTime.now();
    List<String> problemSensors = [];

    for (final sensor in _sensors) {
      final sensorId = '${sensor.modelName}_${sensor.portName}';
      final lastReceived = _lastDataReceived[sensorId];

      // 30초 이상 데이터 안 오면 구독 문제로 판단
      if (lastReceived == null || now.difference(lastReceived).inSeconds > 30) {
        problemSensors.add(sensor.displayName);
        _subscriptionActive[sensorId] = false;
      }
    }

    if (problemSensors.isNotEmpty) {
      print('구독 문제 센서 발견: ${problemSensors.join(', ')}');
      _resubscribeFailedSensors();
    }
  }

  void _scheduleRetry() {
    // WebSocket 연결을 다시 하는 것(구독까지 포함된 전체 연결을 다시 시도)
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), () {
      setState(() => _connectionStatus = '재연결 시도중...');
      _createAndActivateClient();
    });
  }

  // ------------------ 메시지 처리 ------------------
  void _updateSensor(int sensorIndex, String? body) {
    // WebSocket에서 수신한 센서 데이터를 처리하고 UI 상태를 업데이트하는 핵심 함수

    if (body == null || body.isEmpty || sensorIndex >= _sensors.length) return;

    final nowStr = DateTime.now().toString().substring(11, 19);
    final sensor = _sensors[sensorIndex];
    final sensorId = '${sensor.modelName}_${sensor.portName}';

    // 센서별 데이터 수신 시간 기록 (개별 구독 상태 추적)
    _lastDataReceived[sensorId] = DateTime.now();
    _subscriptionActive[sensorId] = true;

    // 원본 데이터 출력
    logMessage('=== 웹소켓 데이터 수신 ===', name: 'WebSocket');
    logMessage('시간: $nowStr', name: 'WebSocket');
    logMessage('센서: $sensorId (${sensor.displayName})', name: 'WebSocket');
    logMessage('원본 데이터: $body', name: 'WebSocketData');
    logMessage('데이터 길이: ${body.length} bytes', name: 'WebSocket');

    try {
      // JSON 파싱
      final dynamic data = jsonDecode(body);
      logMessage('파싱된 JSON: $data', name: 'ParsedData');
      // 파싱된 JSON:  {alarmResult: {alarmLevel: NORMAL, messages: [정상]}, co: 3, o2: 20.37, h2s: 0, co2: 1013}

      if (data is Map<String, dynamic>) {
        logMessage('--- 가스 데이터 ---', name: 'GasData');
        data.forEach((key, value) {
          logMessage('  $key: $value (${value.runtimeType})', name: 'GasData');
        });

        // 센서 타입 판별 (LEL 센서 vs 복합가스센서)
        final isLelSensor =
            data.containsKey('lel') ||
            sensor.modelName.toLowerCase().contains('lel');

        setState(() {
          if (isLelSensor) {
            // LEL 센서 처리
            if (!_lelSensors.containsKey(sensorId)) {
              _lelSensors[sensorId] = {
                'lel': '--',
                'temperature': '--',
                'humidity': '--',
                'gasId': '--',
              };
              logMessage('새 LEL 센서 초기화: $sensorId', name: 'LELSensor');
            }

            // LEL 센서 데이터 업데이트
            if (data.containsKey('lel')) {
              final oldValue = _lelSensors[sensorId]!['lel'];
              final newValue = data['lel']?.toString() ?? '--';
              _lelSensors[sensorId]!['lel'] = newValue;
              logMessage('LEL 업데이트: $oldValue → $newValue', name: 'LELUpdate');
            }
            if (data.containsKey('temperature')) {
              final oldValue = _lelSensors[sensorId]!['temperature'];
              final newValue = data['temperature']?.toString() ?? '--';
              _lelSensors[sensorId]!['temperature'] = newValue;
              logMessage('온도 업데이트: $oldValue → $newValue', name: 'LELUpdate');
            }
            if (data.containsKey('humidity')) {
              final oldValue = _lelSensors[sensorId]!['humidity'];
              final newValue = data['humidity']?.toString() ?? '--';
              _lelSensors[sensorId]!['humidity'] = newValue;
              logMessage('습도 업데이트: $oldValue → $newValue', name: 'LELUpdate');
            }
            if (data.containsKey('gasId')) {
              final oldValue = _lelSensors[sensorId]!['gasId'];
              final newValue = data['gasId']?.toString() ?? '--';
              _lelSensors[sensorId]!['gasId'] = newValue;
              logMessage('가스ID 업데이트: $oldValue → $newValue', name: 'LELUpdate');
            }
          } else {
            // 복합가스센서 처리 (기존 로직)
            if (!_sensorGroups.containsKey(sensorId)) {
              _sensorGroups[sensorId] = {
                'CO': '--',
                'O2': '--',
                'H2S': '--',
                'CO2': '--',
              };
              logMessage('새 센서 그룹 초기화: $sensorId', name: 'SensorGroup');
            }

            // 각 가스 데이터 업데이트
            if (data.containsKey('co')) {
              final oldValue = _sensorGroups[sensorId]!['CO'];
              final newValue = data['co']?.toString() ?? '--';
              _sensorGroups[sensorId]!['CO'] = newValue;
              logMessage('CO 업데이트: $oldValue → $newValue', name: 'GasUpdate');
            }
            if (data.containsKey('o2')) {
              final oldValue = _sensorGroups[sensorId]!['O2'];
              final newValue = data['o2']?.toString() ?? '--';
              _sensorGroups[sensorId]!['O2'] = newValue;
              logMessage('O2 업데이트: $oldValue → $newValue', name: 'GasUpdate');
            }
            if (data.containsKey('h2s')) {
              final oldValue = _sensorGroups[sensorId]!['H2S'];
              final newValue = data['h2s']?.toString() ?? '--';
              _sensorGroups[sensorId]!['H2S'] = newValue;
              logMessage('H2S 업데이트: $oldValue → $newValue', name: 'GasUpdate');
            }
            if (data.containsKey('co2')) {
              final oldValue = _sensorGroups[sensorId]!['CO2'];
              final newValue = data['co2']?.toString() ?? '--';
              _sensorGroups[sensorId]!['CO2'] = newValue;
              logMessage('CO2 업데이트: $oldValue → $newValue', name: 'GasUpdate');
            }
          }

          // 알람 메시지 처리
          if (data.containsKey('alarmResult') && data['alarmResult'] is Map) {
            final alarmResult = data['alarmResult'] as Map<String, dynamic>;
            // print('알람 결과: $alarmResult');
            if (alarmResult.containsKey('messages') &&
                alarmResult['messages'] is List) {
              final messages = alarmResult['messages'] as List;
              final newAlarm = messages.isNotEmpty
                  ? messages.first.toString()
                  : '';
              final oldAlarm = _sensorGroupAlarms[sensorId] ?? '';
              _sensorGroupAlarms[sensorId] = newAlarm;
              print('알람 메시지 업데이트: "$oldAlarm" → "$newAlarm"');
            }
          } else {
            _sensorGroupAlarms[sensorId] = '';
          }

          _lastUpdateTime = nowStr;
        });

        print('--- 업데이트 완료 ---');
        print('센서 그룹 [$sensorId] 최종 데이터: ${_sensorGroups[sensorId]}');
        print('알람 상태: ${_sensorGroupAlarms[sensorId]}');
        print('=======================\n');
      } else {
        print('ERROR: 데이터가 Map 형태가 아닙니다: ${data.runtimeType}');
      }
    } catch (e) {
      print('JSON 파싱 오류: $e');
      print('원본 데이터: $body');

      // JSON 파싱 실패시 기존 방식으로 처리
      String parsedValue(String? b) {
        if (b == null) return '--';
        final n = double.tryParse(b);
        if (n != null) return n.toStringAsFixed(2);
        return b;
      }

      final v = parsedValue(body);
      setState(() {
        sensor.data = v;
        sensor.lastUpdateTime = nowStr;
      });

      print('기존 방식으로 처리됨: ${sensor.displayName} = $v');
      print('=======================\n');
    }
  }

  // ------------------ UI 빌더 메서드 ------------------
  Widget _buildLelSensorCard(String sensorId, SensorInfo sensor) {
    final lelData =
        _lelSensors[sensorId] ??
        {'lel': '--', 'temperature': '--', 'humidity': '--', 'gasId': '--'};
    final alarmMessage = _sensorGroupAlarms[sensorId] ?? '';

    // LEL 값으로 상태 계산 (새로운 범위 적용)
    final lelValue = lelData['lel'] ?? '--';
    Color statusColor = Colors.green;
    String statusText = '정상';

    if (lelValue != '--' && lelValue.isNotEmpty) {
      final numValue = double.tryParse(lelValue);
      if (numValue != null) {
        if (numValue > 25) {
          // 위험 범위: 25% 초과
          statusColor = Colors.red;
          statusText = '위험';
        } else if (numValue > 10) {
          // 경고 범위: 10~25%
          statusColor = Colors.orange;
          statusText = '경고';
        } else {
          // 정상 범위: 0~10%
          statusColor = Colors.green;
          statusText = '정상';
        }
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // LEL 센서 헤더
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: statusColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            child: Row(
              children: [
                Text(
                  'LEL센서 #${sensorId.split('_').last}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                const Spacer(),
                Text(
                  statusText,
                  style: TextStyle(color: statusColor, fontSize: 14),
                ),
              ],
            ),
          ),

          // LEL 메인 카드
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: statusColor,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withOpacity(0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // LEL 라벨과 정상 범위
                  const Text(
                    'LEL',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '정상: 0~10 %',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 20),

                  // 값과 단위
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        lelData['lel'] == '--' ? '--' : '${lelData['lel']}',

                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 32,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "%",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 32,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 센서 상태 하단
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '센서 상태',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                const Spacer(),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorGroupCard(String sensorId, SensorInfo sensor) {
    final gasData =
        _sensorGroups[sensorId] ??
        {'CO': '--', 'O2': '--', 'H2S': '--', 'CO2': '--'};
    final alarmMessage = _sensorGroupAlarms[sensorId] ?? '';

    // 디버그 로그 추가
    logMessage('복합가스센서 카드 빌드: $sensorId', name: 'UI');
    logMessage('가스데이터: $gasData', name: 'UI');
    logMessage('전체 센서그룹: ${_sensorGroups.keys.toList()}', name: 'UI');

    // 전체 센서 그룹의 상태 계산
    bool hasError = false;
    bool hasWarning = false;
    for (String gasType in ['CO', 'O2', 'H2S', 'CO2']) {
      final gasValue = gasData[gasType] ?? '--';
      if (gasValue != '--' && gasValue.isNotEmpty) {
        final status = _calculateGasStatus(gasType, gasValue);
        if (status == SensorStatus.danger) {
          hasError = true;
          break;
        } else if (status == SensorStatus.warning) {
          hasWarning = true;
        }
      }
    }

    Color groupStatusColor = hasError
        ? Colors.red
        : (hasWarning ? Colors.orange : Colors.green);
    String groupStatusText = hasError ? '위험' : (hasWarning ? '경고' : '정상');

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: groupStatusColor, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // 센서 그룹 헤더
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: groupStatusColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            child: Row(
              children: [
                Text(
                  '복합가스센서 #${sensorId.split('_').last}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                const Spacer(),
                Text(
                  groupStatusText,
                  style: TextStyle(color: groupStatusColor, fontSize: 14),
                ),
              ],
            ),
          ),

          // 가스 카드들 그리드
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 4,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.6,
              children: [
                _buildGasCard('CO', gasData['CO'] ?? '--'),
                _buildGasCard('O2', gasData['O2'] ?? '--'),
                _buildGasCard('H2S', gasData['H2S'] ?? '--'),
                _buildGasCard('CO2', gasData['CO2'] ?? '--'),
              ],
            ),
          ),

          // 센서 상태 하단
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                Text(
                  '센서 상태',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                const Spacer(),
                Text(
                  groupStatusText,
                  style: TextStyle(
                    color: groupStatusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  SensorStatus _calculateGasStatus(String gasType, String gasValue) {
    final threshold = GasThresholds.thresholds[gasType];
    if (gasValue == '--' || gasValue.isEmpty || threshold == null) {
      return SensorStatus.error;
    }

    final numValue = double.tryParse(gasValue);
    if (numValue == null) return SensorStatus.error;

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

  Widget _buildGasCard(String gasType, String gasValue) {
    final threshold = GasThresholds.thresholds[gasType];
    final status = _calculateGasStatus(gasType, gasValue);

    Color cardColor;
    switch (status) {
      case SensorStatus.normal:
        cardColor = Colors.green;
        break;
      case SensorStatus.warning:
        cardColor = Colors.orange;
        break;
      case SensorStatus.danger:
        cardColor = Colors.red;
        break;
      case SensorStatus.error:
        cardColor = Colors.grey;
        break;
    }

    // Create display text with proper chemical subscripts
    String displayText = gasType;
    if (gasType.toLowerCase() == 'co2') {
      displayText = 'CO₂';
    } else if (gasType.toLowerCase() == 'h2s') {
      displayText = 'H₂S';
    } else if (gasType.toLowerCase() == 'o2') {
      displayText = 'O₂';
    } else if (gasType.toLowerCase() == 'co') {
      displayText = 'CO';
    }

    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: cardColor.withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(8),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              displayText,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 4),
            // Gas value
            Text(
              gasValue,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            // Unit below the value
            Text(
              threshold?['unit'] ?? '',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _manualReconnect() {
    _isConnecting = false;
    _retryTimer?.cancel();
    _heartbeatTicker?.cancel();
    _stomp?.deactivate();

    setState(() {
      _isWebSocketConnected = false;
      _connectionStatus = '재연결 시도중...';
    });

    _loadSensors(); // 센서 정보부터 다시 로딩
  }

  void _reloadSensors() async {
    await _loadSensors();
  }

  void _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          currentIp: _serverIp,
          currentPort: _serverPort,
          sensors: _sensors,
          onSettingsChanged: (ip, port) {
            setState(() {
              _serverIp = ip;
              _serverPort = port;
            });
            _manualReconnect();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 40.0, bottom: 16.0),
            child: Column(
              children: [
                const Text(
                  "가스 센서 모니터링 대시보드",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),

                // 연결 상태 표시
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _isWebSocketConnected
                        ? Colors.green.withOpacity(0.1)
                        : Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isWebSocketConnected
                          ? Colors.green
                          : Colors.orange,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isWebSocketConnected ? Icons.wifi : Icons.wifi_find,
                        size: 16,
                        color: _isWebSocketConnected
                            ? Colors.green
                            : Colors.orange,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _connectionStatus,
                        style: TextStyle(
                          fontSize: 12,
                          color: _isWebSocketConnected
                              ? Colors.green
                              : Colors.orange,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 센서 그룹 리스트
          Expanded(
            child: !_sensorsLoaded
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_sensorLoadError.isEmpty) ...[
                          const CircularProgressIndicator(),
                          const Text(
                            '센서 정보를 불러오는 중...',
                            style: TextStyle(fontSize: 16),
                          ),
                        ] else ...[
                          const Icon(
                            Icons.error_outline,
                            color: Colors.red,
                            size: 64,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            '센서 정보 로딩 실패',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _sensorLoadError,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _reloadSensors,
                            icon: const Icon(Icons.refresh),
                            label: const Text('다시 시도'),
                          ),
                        ],
                      ],
                    ),
                  )
                : _sensors.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.sensors_off, color: Colors.grey, size: 64),
                        SizedBox(height: 16),
                        Text(
                          '등록된 센서가 없습니다',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ListView.builder(
                      itemCount: _sensors.length,
                      itemBuilder: (context, index) {
                        if (index >= _sensors.length) return Container();

                        final sensor = _sensors[index];
                        final sensorId =
                            '${sensor.modelName}_${sensor.portName}';

                        // 센서 타입 판별
                        final isLelSensor =
                            sensor.modelName.toLowerCase().contains('lel') ||
                            _lelSensors.containsKey(sensorId);

                        if (isLelSensor) {
                          // LEL 센서 카드 빌드
                          return _buildLelSensorCard(sensorId, sensor);
                        } else {
                          // 복합가스센서 카드 빌드
                          return _buildSensorGroupCard(sensorId, sensor);
                        }
                      },
                    ),
                  ),
          ),

          // 하단 컨트롤 버튼들
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isConnecting ? null : _manualReconnect,
                    icon: _isConnecting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(_isConnecting ? '연결중...' : '재연결'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _openSettings,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(12),
                  ),
                  child: const Icon(Icons.settings),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
