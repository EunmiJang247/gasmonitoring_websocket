import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:stomp_dart_client/stomp.dart';
import 'package:stomp_dart_client/stomp_config.dart';
import 'package:stomp_dart_client/stomp_frame.dart';
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
  // ---- 서버 & 센서 설정 ----
  String _serverIp = '192.168.0.224';
  String _serverPort = '8081';

  // 센서 #1
  String _deviceId1 = 'UA58KFG';
  String _sensorPort1 = 'COM3';

  // 센서 #2
  String _deviceId2 = 'UA58LEL';
  String _sensorPort2 = 'COM4';

  // ---- UI 상태 ----
  String _connectionStatus = '연결 대기중';

  // 센서 데이터/시간
  String _sensorData1 = '--';
  String _sensorTime1 = '--';
  String _sensorData2 = '--';
  String _sensorTime2 = '--';

  // ---- STOMP ----
  StompClient? _stomp;
  StreamSubscription? _heartbeatTicker;
  Timer? _retryTimer;
  bool _usingSockJS = false;
  bool _isConnecting = false;

  String get _wsUrl => 'ws://$_serverIp:$_serverPort/ws/sensor';
  String get _httpSockUrl => 'http://$_serverIp:$_serverPort/ws/sensor';

  String get _topic1 => '/topic/sensor/$_deviceId1/$_sensorPort1';
  String get _topic2 => '/topic/sensor/$_deviceId2/$_sensorPort2';

  @override
  void initState() {
    super.initState();
    _connectStomp();
  }

  @override
  void dispose() {
    _heartbeatTicker?.cancel();
    _retryTimer?.cancel();
    _stomp?.deactivate();
    super.dispose();
  }

  // ------------------ 연결/구독 ------------------
  void _connectStomp() {
    if (_isConnecting) return;
    _isConnecting = true;
    setState(() => _connectionStatus = '연결중...');

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
      _connectionStatus = '연결됨 (${_usingSockJS ? "SockJS" : "WS"})';
    });

    // ✅ 센서 1, 2를 각각 구독
    _stomp?.subscribe(
      destination: _topic1,
      headers: const {'ack': 'auto'},
      callback: (msg) => _updateSensor(1, msg.body),
    );
    _stomp?.subscribe(
      destination: _topic2,
      headers: const {'ack': 'auto'},
      callback: (msg) => _updateSensor(2, msg.body),
    );

    _heartbeatTicker?.cancel();
    _heartbeatTicker = Stream.periodic(
      const Duration(seconds: 15),
    ).listen((_) => debugPrint('[hb] alive'));
  }

  void _onStompError(StompFrame frame) {
    _isConnecting = false;
    setState(() {
      _connectionStatus = 'STOMP 오류: ${frame.body ?? frame.headers.toString()}';
    });
    _scheduleRetryOrFallback();
  }

  void _onWsError(Object error, {required bool sockJs}) {
    debugPrint('WS error(${sockJs ? "sockjs" : "ws"}): $error');
    setState(() => _connectionStatus = '연결 오류: $error');

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
    setState(() => _connectionStatus = '연결 끊어짐');
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
  void _updateSensor(int idx, String? body) {
    final nowStr = DateTime.now().toString().substring(11, 19);

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
      if (idx == 1) {
        _sensorData1 = v;
        _sensorTime1 = nowStr;
      } else {
        _sensorData2 = v;
        _sensorTime2 = nowStr;
      }
    });
  }

  // ------------------ 수동 재연결/설정 ------------------
  void _manualReconnect() {
    _isConnecting = false;
    _retryTimer?.cancel();
    _heartbeatTicker?.cancel();
    _stomp?.deactivate();
    setState(() {
      _connectionStatus = '재연결 시도중...';
    });
    _connectStomp();
  }

  void _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          currentIp: _serverIp,
          currentPort: _serverPort,
          // 센서1
          currentDeviceId1: _deviceId1,
          currentSensorPort1: _sensorPort1,
          // 센서2
          currentDeviceId2: _deviceId2,
          currentSensorPort2: _sensorPort2,
          onSettingsChanged: (ip, port, d1, p1, d2, p2) {
            setState(() {
              _serverIp = ip;
              _serverPort = port;
              _deviceId1 = d1;
              _sensorPort1 = p1;
              _deviceId2 = d2;
              _sensorPort2 = p2;
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

    Widget sensorCard({
      required String title,
      required String topic,
      required String value,
      required String time,
    }) {
      return Card(
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.sensors, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Topic: $topic',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 12),
              Container(
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
                  value,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '업데이트: $time',
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
                          _connectionStatus.startsWith('연결됨')
                              ? Icons.wifi
                              : Icons.wifi_off,
                          color: _connectionStatus.startsWith('연결됨')
                              ? Colors.green
                              : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '연결 상태: $_connectionStatus',
                          style: const TextStyle(fontSize: 16),
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

            // 센서 2개 표시
            Expanded(
              child: ListView(
                children: [
                  sensorCard(
                    title: '센서 #1 ($_deviceId1 / $_sensorPort1)',
                    topic: _topic1,
                    value: _sensorData1,
                    time: _sensorTime1,
                  ),
                  sensorCard(
                    title: '센서 #2 ($_deviceId2 / $_sensorPort2)',
                    topic: _topic2,
                    value: _sensorData2,
                    time: _sensorTime2,
                  ),
                ],
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
            Text(
              '$_serverIp:$_serverPort',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}
