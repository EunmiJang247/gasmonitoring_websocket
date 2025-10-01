import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  final String currentIp;
  final String currentPort;

  // 센서1
  final String currentDeviceId1;
  final String currentSensorPort1;

  // 센서2
  final String currentDeviceId2;
  final String currentSensorPort2;

  final void Function(
    String ip,
    String port,
    String deviceId1,
    String sensorPort1,
    String deviceId2,
    String sensorPort2,
  )
  onSettingsChanged;

  const SettingsPage({
    super.key,
    required this.currentIp,
    required this.currentPort,
    required this.currentDeviceId1,
    required this.currentSensorPort1,
    required this.currentDeviceId2,
    required this.currentSensorPort2,
    required this.onSettingsChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _ipCtrl;
  late TextEditingController _portCtrl;

  late TextEditingController _dev1Ctrl;
  late TextEditingController _port1Ctrl;

  late TextEditingController _dev2Ctrl;
  late TextEditingController _port2Ctrl;

  @override
  void initState() {
    super.initState();
    _ipCtrl = TextEditingController(text: widget.currentIp);
    _portCtrl = TextEditingController(text: widget.currentPort);

    _dev1Ctrl = TextEditingController(text: widget.currentDeviceId1);
    _port1Ctrl = TextEditingController(text: widget.currentSensorPort1);

    _dev2Ctrl = TextEditingController(text: widget.currentDeviceId2);
    _port2Ctrl = TextEditingController(text: widget.currentSensorPort2);
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _dev1Ctrl.dispose();
    _port1Ctrl.dispose();
    _dev2Ctrl.dispose();
    _port2Ctrl.dispose();
    super.dispose();
  }

  void _save() {
    widget.onSettingsChanged(
      _ipCtrl.text.trim(),
      _portCtrl.text.trim(),
      _dev1Ctrl.text.trim(),
      _port1Ctrl.text.trim(),
      _dev2Ctrl.text.trim(),
      _port2Ctrl.text.trim(),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final labelStyle = TextStyle(color: Colors.grey[700]);

    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ipCtrl,
            decoration: InputDecoration(
              labelText: '서버 IP',
              labelStyle: labelStyle,
            ),
          ),
          TextField(
            controller: _portCtrl,
            decoration: InputDecoration(
              labelText: '서버 Port',
              labelStyle: labelStyle,
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          const Text('센서 #1', style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(
            controller: _dev1Ctrl,
            decoration: const InputDecoration(
              labelText: '디바이스 ID (예: UA58KFG)',
            ),
          ),
          TextField(
            controller: _port1Ctrl,
            decoration: const InputDecoration(labelText: '센서 포트 (예: COM3)'),
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          const Text('센서 #2', style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(
            controller: _dev2Ctrl,
            decoration: const InputDecoration(
              labelText: '디바이스 ID (예: UA58LEL)',
            ),
          ),
          TextField(
            controller: _port2Ctrl,
            decoration: const InputDecoration(labelText: '센서 포트 (예: COM4)'),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('저장'),
          ),
        ],
      ),
    );
  }
}
