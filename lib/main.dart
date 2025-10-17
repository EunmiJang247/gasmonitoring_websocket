import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:stomp_dart_client/stomp.dart';
import 'package:stomp_dart_client/stomp_config.dart';
import 'package:stomp_dart_client/stomp_frame.dart';
import 'package:http/http.dart' as http;
import 'sensor_info.dart';
import 'settings_page.dart';

void main() {
  runApp(const MyApp());
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
  String _serverIp = '192.168.0.224';
  String _serverPort = '8080';

  // ---- 동적 센서 관리 ----
  List<SensorInfo> _sensors = [];
  bool _sensorsLoaded = false;
  String _sensorLoadError = '';

  // ---- 가스 데이터 관리 ----
  Map<String, Map<String, String>> _sensorGroups = {};
  Map<String, String> _sensorGroupAlarms = {};
  String _lastUpdateTime = '--';

  // ---- UI 상태 ----
  String _connectionStatus = '센서 정보 로딩중...';
  bool _isWebSocketConnected = false;

  // ---- STOMP ----
  StompClient? _stomp;
  StreamSubscription? _heartbeatTicker;
  Timer? _retryTimer;
  bool _usingSockJS = false;
  bool _isConnecting = false;

  String get _wsUrl => 'ws://$_serverIp:$_serverPort/ws/sensor';
  String get _httpSockUrl => 'http://$_serverIp:$_serverPort/ws/sensor';
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
      debugPrint('센서 매핑 API 호출: $_apiUrl');
      final response = await http
          .get(
            Uri.parse(_apiUrl),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = jsonDecode(response.body);
        debugPrint('API 응답: $responseData');

        if (responseData['code'] == 200 && responseData['data'] != null) {
          final List<dynamic> sensorsJson =
              responseData['data']['sensors'] ?? [];

          setState(() {
            _sensors = sensorsJson
                .map((json) => SensorInfo.fromJson(json))
                .toList();
            _sensorsLoaded = true;
            _connectionStatus = '센서 ${_sensors.length}개 로딩 완료';
          });

          debugPrint('로딩된 센서들:');
          for (var sensor in _sensors) {
            debugPrint('  - ${sensor.displayName}: ${sensor.topicPath}');
          }

          // 센서 로딩 완료 후 WebSocket 연결 시작
          if (_sensors.isNotEmpty) {
            _connectStomp();
          } else {
            setState(() {
              _connectionStatus = '등록된 센서가 없습니다';
            });
          }
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
      debugPrint('센서 로딩 오류: $e');
    }
  }

  // ------------------ 연결/구독 ------------------
  void _connectStomp() {
    if (_isConnecting || !_sensorsLoaded) return;
    _isConnecting = true;
    setState(() => _connectionStatus = 'WebSocket 연결중...');

    _usingSockJS = false; // 순수 WS 우선
    _createAndActivateClient(sockJs: false);
  }

  void _createAndActivateClient({required bool sockJs}) {
    _stomp?.deactivate();

    final url = sockJs ? _httpSockUrl : _wsUrl;

    final config = sockJs
        ? StompConfig.SockJS(
            url: url,
            onConnect: _onConnect,
            onStompError: _onStompError,
            onWebSocketError: (e) => _onWsError(e, sockJs: true),
            onWebSocketDone: _onWsDone,
            reconnectDelay: const Duration(seconds: 3),
            heartbeatIncoming: const Duration(seconds: 10),
            heartbeatOutgoing: const Duration(seconds: 10),
            // stompConnectHeaders: const {'login': 'user', 'passcode': 'secret'},
          )
        : StompConfig(
            url: url,
            onConnect: _onConnect,
            onStompError: _onStompError,
            onWebSocketError: (e) => _onWsError(e, sockJs: false),
            onWebSocketDone: _onWsDone,
            reconnectDelay: const Duration(seconds: 3),
            heartbeatIncoming: const Duration(seconds: 10),
            heartbeatOutgoing: const Duration(seconds: 10),
            // 일부 서버는 STOMP 서브프로토콜 명시 필요
            webSocketConnectHeaders: const {
              'Sec-WebSocket-Protocol': 'v12.stomp',
            },
            // stompConnectHeaders: const {'login': 'user', 'passcode': 'secret'},
          );

    _stomp = StompClient(config: config);
    _stomp!.activate();
  }

  void _onConnect(StompFrame frame) {
    _isConnecting = false;
    _retryTimer?.cancel();

    setState(() {
      _isWebSocketConnected = true;
      _connectionStatus = 'WebSocket 연결됨 (${_usingSockJS ? "SockJS" : "WS"})';
    });

    // ✅ 모든 센서들을 구독
    for (int i = 0; i < _sensors.length; i++) {
      final sensor = _sensors[i];
      debugPrint('센서 구독: ${sensor.topicPath}');

      _stomp?.subscribe(
        destination: sensor.topicPath,
        headers: const {'ack': 'auto'},
        callback: (msg) => _updateSensor(i, msg.body),
      );
    }

    _heartbeatTicker?.cancel();
    _heartbeatTicker = Stream.periodic(
      const Duration(seconds: 15),
    ).listen((_) => debugPrint('[hb] alive'));

    setState(() {
      _connectionStatus = '${_sensors.length}개 센서 구독 완료';
    });
  }

  void _onStompError(StompFrame frame) {
    _isConnecting = false;
    setState(() {
      _isWebSocketConnected = false;
      _connectionStatus = 'STOMP 오류: ${frame.body ?? frame.headers.toString()}';
    });
    _scheduleRetryOrFallback();
  }

  void _onWsError(Object error, {required bool sockJs}) {
    debugPrint('WS error(${sockJs ? "sockjs" : "ws"}): $error');
    setState(() {
      _isWebSocketConnected = false;
      _connectionStatus = '연결 오류: $error';
    });

    if (!sockJs) {
      // 순수 WS 실패 → SockJS로 폴백
      _usingSockJS = true;
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(milliseconds: 500), () {
        setState(() => _connectionStatus = 'WS 실패 → SockJS 재시도...');
        _createAndActivateClient(sockJs: true);
      });
    } else {
      _scheduleRetryOrFallback();
    }
  }

  void _onWsDone() {
    debugPrint('WS done/closed');
    setState(() {
      _isWebSocketConnected = false;
      _connectionStatus = '연결 끊어짐';
    });
    _scheduleRetryOrFallback();
  }

  void _scheduleRetryOrFallback() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), () {
      setState(() => _connectionStatus = '재연결 시도중...');
      _createAndActivateClient(sockJs: _usingSockJS);
    });
  }

  // ------------------ 메시지 처리 ------------------
  void _updateSensor(int sensorIndex, String? body) {
    if (body == null || body.isEmpty || sensorIndex >= _sensors.length) return;

    final nowStr = DateTime.now().toString().substring(11, 19);
    final sensor = _sensors[sensorIndex];
    final sensorId = '${sensor.modelName}_${sensor.portName}';

    try {
      // JSON 파싱
      final dynamic data = jsonDecode(body);
      debugPrint('받은 데이터 [$sensorId]: $data');

      if (data is Map<String, dynamic>) {
        setState(() {
          // 센서 그룹 초기화
          if (!_sensorGroups.containsKey(sensorId)) {
            _sensorGroups[sensorId] = {
              'CO': '--',
              'O2': '--',
              'H2S': '--',
              'CO2': '--',
            };
          }

          // 각 가스 데이터 업데이트
          if (data.containsKey('co')) {
            _sensorGroups[sensorId]!['CO'] = data['co']?.toString() ?? '--';
          }
          if (data.containsKey('o2')) {
            _sensorGroups[sensorId]!['O2'] = data['o2']?.toString() ?? '--';
          }
          if (data.containsKey('h2s')) {
            _sensorGroups[sensorId]!['H2S'] = data['h2s']?.toString() ?? '--';
          }
          if (data.containsKey('co2')) {
            _sensorGroups[sensorId]!['CO2'] = data['co2']?.toString() ?? '--';
          }

          // 알람 메시지 처리
          if (data.containsKey('alarmResult') && data['alarmResult'] is Map) {
            final alarmResult = data['alarmResult'] as Map<String, dynamic>;
            if (alarmResult.containsKey('messages') &&
                alarmResult['messages'] is List) {
              final messages = alarmResult['messages'] as List;
              _sensorGroupAlarms[sensorId] = messages.isNotEmpty
                  ? messages.first.toString()
                  : '';
            }
          } else {
            _sensorGroupAlarms[sensorId] = '';
          }

          _lastUpdateTime = nowStr;
        });

        debugPrint('센서 그룹 [$sensorId] 데이터 업데이트: ${_sensorGroups[sensorId]}');
      }
    } catch (e) {
      debugPrint('JSON 파싱 오류: $e, 원본 데이터: $body');

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
    }
  }

  // ------------------ UI 빌더 메서드 ------------------
  Widget _buildSensorGroupCard(String sensorId, SensorInfo sensor) {
    final gasData =
        _sensorGroups[sensorId] ??
        {'CO': '--', 'O2': '--', 'H2S': '--', 'CO2': '--'};
    final alarmMessage = _sensorGroupAlarms[sensorId] ?? '';

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
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: groupStatusColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.sensors, color: Colors.white, size: 24),
                const SizedBox(width: 12),
                Text(
                  '복합가스센서 #${sensorId.split('_').last}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                const Spacer(),
                Text(
                  groupStatusText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),

          // 가스 카드들 그리드
          Padding(
            padding: const EdgeInsets.all(16),
            child: GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.2,
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
                Icon(
                  hasError
                      ? Icons.error
                      : (hasWarning ? Icons.warning : Icons.check_circle),
                  color: groupStatusColor,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  '센서 상태',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                const Spacer(),
                if (alarmMessage.isNotEmpty) ...[
                  Icon(Icons.warning, color: Colors.orange, size: 16),
                  const SizedBox(width: 4),
                ],
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
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 가스 타입과 정상 범위
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    gasType,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  if (gasType == 'O2')
                    const Text(
                      '₂',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  if (gasType == 'H2S')
                    const Text(
                      '₂S',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  if (gasType == 'CO2')
                    const Text(
                      '₂',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              if (threshold != null)
                Text(
                  '정상: ${threshold['normal_min']}~${threshold['normal_max']} ${threshold['unit']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
            ],
          ),

          // 큰 실선 표시
          Container(
            width: double.infinity,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // 값과 단위
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                gasValue == '--' ? '--' : gasValue,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
              Text(
                threshold?['unit'] ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSensorCard(SensorInfo sensor) {
    final threshold = sensor.thresholdInfo;
    final gasType = sensor.gasType;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: sensor.statusColor, width: 3),
        boxShadow: [
          BoxShadow(
            color: sensor.statusColor.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 가스 타입과 아이콘
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color:
                      threshold?['color']?.withOpacity(0.1) ??
                      Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  threshold?['icon'] ?? Icons.sensors,
                  color: threshold?['color'] ?? Colors.grey,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      gasType,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      sensor.portName,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 센서 값 표시
          Center(
            child: Column(
              children: [
                Text(
                  sensor.dataWithUnit,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: sensor.statusColor,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: sensor.statusColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    sensor.statusText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Spacer(),

          // 정상 범위 표시
          if (threshold != null) ...[
            const SizedBox(height: 8),
            Text(
              sensor.normalRangeText,
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],

          // 업데이트 시간
          Text(
            '업데이트: ${sensor.lastUpdateTime}',
            style: TextStyle(fontSize: 10, color: Colors.grey[500]),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  } // ------------------ 수동 재연결/설정 ------------------

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
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('가스 모니터링 시스템'),
        centerTitle: true,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _sensorsLoaded ? _reloadSensors : null,
            tooltip: '센서 정보 새로고침',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
            tooltip: '설정',
          ),
        ],
      ),
      body: Column(
        children: [
          // 연결 상태 표시
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _isWebSocketConnected ? Colors.green : Colors.red,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(
                  _isWebSocketConnected ? Icons.wifi : Icons.wifi_off,
                  color: Colors.white,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isWebSocketConnected ? '실시간 모니터링 중' : '연결 끊김',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        '$_serverIp:$_serverPort',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 알람 메시지 표시
          if (_sensorGroupAlarms.values.any((alarm) => alarm.isNotEmpty)) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.warning, color: Colors.orange),
                      SizedBox(width: 12),
                      Text(
                        '알람 메시지',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ..._sensorGroupAlarms.entries
                      .where((entry) => entry.value.isNotEmpty)
                      .map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '• ${entry.value}',
                            style: const TextStyle(
                              color: Colors.orange,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // 센서 그룹 리스트
          Expanded(
            child: !_sensorsLoaded
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_sensorLoadError.isEmpty) ...[
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
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
                        final sensor = _sensors[index];
                        final sensorId =
                            '${sensor.modelName}_${sensor.portName}';
                        return _buildSensorGroupCard(sensorId, sensor);
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
