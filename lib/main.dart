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
    if (sensorIndex < 0 || sensorIndex >= _sensors.length) return;

    final nowStr = DateTime.now().toString().substring(11, 19);
    final sensor = _sensors[sensorIndex];

    String parsedValue(String? b) {
      if (b == null) return '--';
      try {
        final dynamic p = jsonDecode(b);
        if (p is Map && (p.containsKey('value') || p.containsKey('data'))) {
          return p['value']?.toString() ?? p['data']?.toString() ?? b;
        }
        if (p is num) return p.toStringAsFixed(2);
      } catch (_) {
        final n = double.tryParse(b);
        if (n != null) return n.toStringAsFixed(2);
      }
      return b;
    }

    final v = parsedValue(body);

    setState(() {
      sensor.data = v;
      sensor.lastUpdateTime = nowStr;
    });

    debugPrint('센서 업데이트: ${sensor.displayName} = $v');
  }

  // ------------------ 헬퍼 메서드 ------------------
  bool _isConnected() {
    return _isWebSocketConnected;
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
    final currentUrl = _usingSockJS ? _httpSockUrl : _wsUrl;

    Widget sensorCard(SensorInfo sensor) {
      return Card(
        elevation: 4,
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.sensors, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sensor.displayName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Serial: ${sensor.serialNumber}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              Text(
                'Topic: ${sensor.topicPath}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Text(
                  sensor.data,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '업데이트: ${sensor.lastUpdateTime}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('가스 모니터링'),
        centerTitle: true,
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
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // 연결 상태 카드
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          _isConnected() ? Icons.wifi : Icons.wifi_off,
                          color: _isConnected() ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '연결 상태: $_connectionStatus',
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'WebSocket: $currentUrl',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 센서 목록 표시
            Expanded(
              child: !_sensorsLoaded
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_sensorLoadError.isEmpty) ...[
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            const Text('센서 정보를 불러오는 중...'),
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
                  : ListView.builder(
                      itemCount: _sensors.length,
                      itemBuilder: (context, index) {
                        return sensorCard(_sensors[index]);
                      },
                    ),
            ),

            const SizedBox(height: 12),

            // 재연결/설정
            Row(
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
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _openSettings,
                  child: const Icon(Icons.settings),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // 현재 연결 정보
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$_serverIp:$_serverPort',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                if (_sensorsLoaded) ...[
                  Text(
                    ' • ${_sensors.length}개 센서',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
