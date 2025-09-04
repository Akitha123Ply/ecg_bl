// ignore_for_file: curly_braces_in_flow_control_structures, empty_catches, deprecated_member_use, unnecessary_to_list_in_spreads
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';

void main() {
  runApp(const ECGApp());
}

/// Simple model that represents one parsed ECG packet (lead samples in raw counts)
class ECGData {
  final int leadV6,
      leadI,
      leadII,
      leadV2,
      leadV4,
      leadV3,
      leadV5,
      leadV1; // raw signed values
  final int aVR, aVL, aVF;
  final int status1, status2, status3;
  final int batteryLevel;
  final DateTime timestamp;

  ECGData({
    required this.leadV6,
    required this.leadI,
    required this.leadII,
    required this.leadV2,
    required this.leadV4,
    required this.leadV3,
    required this.leadV5,
    required this.leadV1,
    required this.aVR,
    required this.aVL,
    required this.aVF,
    required this.status1,
    required this.status2,
    required this.status3,
    required this.batteryLevel,
    required this.timestamp,
  });

  String get batteryStatus {
    final b = batteryLevel & 0x0F;
    return 'Battery: ${(b / 15 * 100).round()}%';
  }

  String get leadStatus {
    final failures = <String>[];
    final connected = <String>[];

    if ((status1 & 0x01) != 0)
      failures.add('V4');
    else
      connected.add('V4');
    if ((status1 & 0x02) != 0)
      failures.add('V3');
    else
      connected.add('V3');
    if ((status1 & 0x04) != 0)
      failures.add('V5');
    else
      connected.add('V5');
    if ((status1 & 0x08) != 0)
      failures.add('V1');
    else
      connected.add('V1');

    if ((status2 & 0x10) != 0)
      failures.add('V6');
    else
      connected.add('V6');
    if ((status2 & 0x20) != 0) failures.add('LA');
    if ((status2 & 0x40) != 0) failures.add('LL');
    if ((status2 & 0x80) != 0)
      failures.add('V2');
    else
      connected.add('V2');

    if ((status3 & 0x10) != 0) failures.add('RA');

    String status = '';
    if (connected.isNotEmpty) status += 'Connected: ${connected.join(", ")}';
    if (failures.isNotEmpty) {
      if (status.isNotEmpty) status += ' | ';
      status += 'Disconnected: ${failures.join(", ")}';
    }
    return status.isEmpty ? 'No lead data' : status;
  }
}

/// Constants & helpers
const double samplingRate =
    250.0; // set to actual device sampling rate (250 or 500)
const double timeWindowSeconds = 10.0;
final int samplesWindow = (samplingRate * timeWindowSeconds).round();

// default conversion: raw_counts * rawToMv = mV (user adjustable)
const double defaultRawToMv = 0.001; // 1 LSB == 1 µV -> 0.001 mV

// ECG paper visual constants
const double mmPerSecond = 25.0; // default paper speed (can be exposed in UI)
const double mmPerMv = 10.0; // 10 mm per 1 mV (standard)
double pixelsPerMmDefault =
    4.0; // initial px-per-mm used for grid (adjustable via device DPI if you want)

int toSigned16(int msb, int lsb) {
  int val = (msb << 8) | (lsb & 0xFF);
  if (val > 32767) val -= 65536;
  return val;
}

/// bluetooth_classic wrapper

class BluetoothService {
  final BluetoothClassic _bt = BluetoothClassic();

  Future<void> initPermissions() => _bt.initPermissions();
  Future<List<Device>> getPairedDevices() => _bt.getPairedDevices();
  Stream<Device> onDeviceDiscovered() => _bt.onDeviceDiscovered();
  Future<void> startScan() => _bt.startScan();
  Future<void> stopScan() => _bt.stopScan();
  Future<bool> connect(String address, String uuid) =>
      _bt.connect(address, uuid);
  Future<void> disconnect() => _bt.disconnect();
  Future<void> write(String cmd) => _bt.write(cmd);
  Stream<Uint8List> onDataReceived() => _bt.onDeviceDataReceived();
}

class ECGParser {
  final _out = StreamController<ECGData>.broadcast();
  Stream<ECGData> get stream => _out.stream;

  Uint8List _buffer = Uint8List(0);
  int lastStatus1 = 0, lastStatus2 = 0, lastStatus3 = 0;

  void addBytes(Uint8List data) {
    // Append incoming bytes to buffer
    _buffer = Uint8List.fromList([..._buffer, ...data]);
    while (true) {
      final dataEvent = _tryParseOnePacket();
      if (dataEvent == null) break;
      _out.add(dataEvent);
    }
  }

  ECGData? _tryParseOnePacket() {
    if (_buffer.isEmpty) return null;

    int startIndex = -1;
    for (int i = 0; i < _buffer.length; i++) {
      if (_buffer[i] == 0xAA || _buffer[i] == 0xBB) {
        startIndex = i;
        break;
      }
    }
    if (startIndex == -1) {
      _buffer = Uint8List(0);
      return null;
    }
    if (startIndex > 0) {
      _buffer = Uint8List.fromList(_buffer.sublist(startIndex));
    }
    if (_buffer.isEmpty) return null;

    final start = _buffer[0];
    if (start == 0xAA) {
      // expected full AA frame length 22 bytes (as observed in Java code)
      if (_buffer.length < 22) return null;
      // termination check (last byte 0x0A newline)
      if (_buffer[21] != 0x0A) {
        // drop first and try again
        _buffer = Uint8List.fromList(_buffer.sublist(1));
        return null;
      }
      final pkt = _buffer.sublist(0, 22);
      _buffer = Uint8List.fromList(_buffer.sublist(22));
      return _parseAAPacket(pkt);
    } else if (start == 0xBB) {
      // expected BB frame length 18 bytes
      if (_buffer.length < 18) return null;
      if (_buffer[17] != 0x0A) {
        _buffer = Uint8List.fromList(_buffer.sublist(1));
        return null;
      }
      final pkt = _buffer.sublist(0, 18);
      _buffer = Uint8List.fromList(_buffer.sublist(18));
      return _parseBBPacket(pkt);
    } else {
      _buffer = Uint8List.fromList(_buffer.sublist(1));
      return null;
    }
  }

  ECGData _parseAAPacket(Uint8List pkt) {
    lastStatus1 = pkt[1];
    lastStatus2 = pkt[2];
    lastStatus3 = pkt[3];

    int v6 = toSigned16(pkt[4], pkt[5]);
    int i = toSigned16(pkt[6], pkt[7]);
    int ii = toSigned16(pkt[8], pkt[9]);
    int v2 = toSigned16(pkt[10], pkt[11]);
    int v4 = toSigned16(pkt[12], pkt[13]);
    int v3 = toSigned16(pkt[14], pkt[15]);
    int v5 = toSigned16(pkt[16], pkt[17]);
    int v1 = toSigned16(pkt[18], pkt[19]);

    // Java applied gain of 2 in their code: keep same behavior
    v6 *= 2;
    i *= 2;
    ii *= 2;
    v2 *= 2;
    v4 *= 2;
    v3 *= 2;
    v5 *= 2;
    v1 *= 2;

    final avr = -(i + ii) ~/ 2;
    final avl = i - (ii ~/ 2);
    final avf = ii - (i ~/ 2);

    return ECGData(
      leadV6: v6,
      leadI: i,
      leadII: ii,
      leadV2: v2,
      leadV4: v4,
      leadV3: v3,
      leadV5: v5,
      leadV1: v1,
      aVR: avr,
      aVL: avl,
      aVF: avf,
      status1: lastStatus1,
      status2: lastStatus2,
      status3: lastStatus3,
      batteryLevel: lastStatus3,
      timestamp: DateTime.now(),
    );
  }

  ECGData _parseBBPacket(Uint8List pkt) {
    int v6 = toSigned16(pkt[1], pkt[2]);
    int i = toSigned16(pkt[3], pkt[4]);
    int ii = toSigned16(pkt[5], pkt[6]);
    int v2 = toSigned16(pkt[7], pkt[8]);
    int v4 = toSigned16(pkt[9], pkt[10]);
    int v3 = toSigned16(pkt[11], pkt[12]);
    int v5 = toSigned16(pkt[13], pkt[14]);
    int v1 = toSigned16(pkt[15], pkt[16]);

    v6 *= 2;
    i *= 2;
    ii *= 2;
    v2 *= 2;
    v4 *= 2;
    v3 *= 2;
    v5 *= 2;
    v1 *= 2;

    final avr = -(i + ii) ~/ 2;
    final avl = i - (ii ~/ 2);
    final avf = ii - (i ~/ 2);

    return ECGData(
      leadV6: v6,
      leadI: i,
      leadII: ii,
      leadV2: v2,
      leadV4: v4,
      leadV3: v3,
      leadV5: v5,
      leadV1: v1,
      aVR: avr,
      aVL: avl,
      aVF: avf,
      status1: lastStatus1,
      status2: lastStatus2,
      status3: lastStatus3,
      batteryLevel: lastStatus3,
      timestamp: DateTime.now(),
    );
  }

  void dispose() => _out.close();
}

class OnePole {
  final double alpha;
  double _y = 0.0;
  double _xPrev = 0.0;
  final bool highpass;
  OnePole.hp(double fc, double fs)
    : alpha =
          (fs - 2 * 3.141592653589793 * fc) / (fs + 2 * 3.141592653589793 * fc),
      highpass = true;
  OnePole.lp(double fc, double fs)
    : alpha =
          (fs - 2 * 3.141592653589793 * fc) / (fs + 2 * 3.141592653589793 * fc),
      highpass = false;
  double process(double x) {
    if (highpass) {
      // y[n] = alpha*(y[n-1] + x[n] - x[n-1])
      _y = alpha * (_y + x - _xPrev);
      _xPrev = x;
      return _y;
    } else {
      // y[n] = (1-alpha)/2 * (x + xPrev) + alpha*yPrev  (better LP)
      final y = ((1 - alpha) / 2.0) * (x + _xPrev) + alpha * _y;
      _xPrev = x;
      _y = y;
      return y;
    }
  }
}

class NotchBiquad {
  // Simple notch with fixed Q
  final double b0, b1, b2, a1, a2;
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  NotchBiquad(double fs, double f0, double q)
    : b0 = 1,
      b1 = -2 * cos(2 * pi * f0 / fs),
      b2 = 1,
      a1 = -2 * cos(2 * pi * f0 / fs) / (1 + (1 / (2 * q))),
      a2 = (1 - (1 / (2 * q))) / (1 + (1 / (2 * q)));
  double process(double x) {
    final y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
    return y;
  }
}

class FilterChain {
  final OnePole hp;
  final OnePole lp;
  final NotchBiquad? notch;
  FilterChain(double fs, {bool enableNotch = false, double mainsHz = 50.0})
    : hp = OnePole.hp(0.5, fs),
      lp = OnePole.lp(40.0, fs),
      notch = enableNotch ? NotchBiquad(fs, mainsHz, 20.0) : null;
  double process(double x) {
    var y = hp.process(x);
    if (notch != null) y = notch!.process(y);
    y = lp.process(y);
    return y;
  }
}

class WaveformController {
  final Map<String, FilterChain> filters = {};
  final Map<String, ListQueue<double>> leadBuffers = {};
  final ValueNotifier<int> tick = ValueNotifier<int>(0);
  double rawToMv = defaultRawToMv;
  int currentGain = 1;
  Timer? _uiTimer;

  WaveformController() {
    final fs = samplingRate;
    for (var l in [
      'I',
      'II',
      'III',
      'aVR',
      'aVL',
      'aVF',
      'V1',
      'V2',
      'V3',
      'V4',
      'V5',
      'V6',
    ]) {
      filters[l] = FilterChain(fs, enableNotch: true, mainsHz: 50.0);
    }
    final allLeads = [
      'I',
      'II',
      'III',
      'aVR',
      'aVL',
      'aVF',
      'V1',
      'V2',
      'V3',
      'V4',
      'V5',
      'V6',
    ];
    for (var l in allLeads) leadBuffers[l] = ListQueue<double>();

    // UI refresh ~20 FPS
    _uiTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      tick.value++;
    });
  }

  void setRawToMv(double v) => rawToMv = v;
  void setGain(int g) => currentGain = g;

  void addECGData(ECGData d) {
    final leadRaw = <String, int>{
      'I': d.leadI,
      'II': d.leadII,
      'III': d.leadII - d.leadI,
      'aVR': d.aVR,
      'aVL': d.aVL,
      'aVF': d.aVF,
      'V1': d.leadV1,
      'V2': d.leadV2,
      'V3': d.leadV3,
      'V4': d.leadV4,
      'V5': d.leadV5,
      'V6': d.leadV6,
    };

    for (final entry in leadRaw.entries) {
      final queue = leadBuffers[entry.key]!;
      final mvRaw = (entry.value * rawToMv) / max(1, currentGain);
      final mv = filters[entry.key]!.process(mvRaw);

      if (mv.isFinite && mv.abs() < 50.0) {
        queue.add(mv);
      } else {
        queue.add(0.0);
      }

      if (queue.length > samplesWindow) {
        queue.removeFirst();
      }
    }
  }

  List<double> getSamples(String lead) {
    return List<double>.from(leadBuffers[lead] ?? []);
  }

  void clear() {
    for (var q in leadBuffers.values) q.clear();
    tick.value++;
  }

  void dispose() {
    _uiTimer?.cancel();
    tick.dispose();
  }
}

/// ECGPaperPainter — CustomPainter for hospital-like ECG paper

class ECGPaperPainter extends CustomPainter {
  final List<double> samples; // mV oldest->newest
  final Color lineColor;
  final double samplingRateLocal;
  final String leadName;
  final bool showGrid;
  final bool showCalibration;
  final double pmm;
  final double mmPerSecLocal;

  ECGPaperPainter({
    required this.samples,
    required this.lineColor,
    required this.samplingRateLocal,
    required this.leadName,
    required this.pmm,
    this.showGrid = true,
    this.showCalibration = false,
    this.mmPerSecLocal = mmPerSecond,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // paper bg
    final bg = Paint()..color = const Color(0xFFFDF5F5);
    canvas.drawRect(Offset.zero & size, bg);

    if (showGrid) _drawGrid(canvas, size);

    _drawWaveform(canvas, size);

    _drawLeadLabel(canvas, size);

    if (showCalibration) _drawCalibrationPulse(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final paintFine = Paint()
      ..color = const Color(0xFFE8C4C4)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    final paintBold = Paint()
      ..color = const Color(0xFFD49999)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final smallPx = pmm * 1.0;
    final largePx = pmm * 5.0;

    for (double x = 0; x <= size.width + 0.1; x += smallPx) {
      final nearLarge =
          ((x % largePx).abs() < 0.001) ||
          ((largePx - (x % largePx)).abs() < 0.001);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        nearLarge ? paintBold : paintFine,
      );
    }
    for (double y = 0; y <= size.height + 0.1; y += smallPx) {
      final nearLarge =
          ((y % largePx).abs() < 0.001) ||
          ((largePx - (y % largePx)).abs() < 0.001);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        nearLarge ? paintBold : paintFine,
      );
    }
  }

  void _drawWaveform(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    final paint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final centerY = size.height / 2.0;

    final pixelsPerSecond = mmPerSecLocal * pmm;
    final sampleSpacing = pixelsPerSecond / samplingRateLocal;
    final pixelsPerMvLocal = mmPerMv * pmm;

    final visibleSamples = min(
      samples.length,
      (size.width / sampleSpacing).ceil(),
    );
    final startIndex = max(0, samples.length - visibleSamples);

    bool first = true;
    for (int i = 0; i < visibleSamples; i++) {
      final idx = startIndex + i;
      final mv = samples[idx];
      final x = i * sampleSpacing;
      final y = centerY - (mv * pixelsPerMvLocal);
      final px = x.clamp(0.0, size.width);
      final py = y.clamp(0.0, size.height);

      if (first) {
        path.moveTo(px, py);
        first = false;
      } else {
        path.lineTo(px, py);
      }
    }

    canvas.drawPath(path, paint);

    final basePaint = Paint()
      ..color = Colors.red.withOpacity(0.12)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), basePaint);
  }

  void _drawLeadLabel(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: leadName,
        style: TextStyle(
          color: lineColor,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(8, 6));
  }

  void _drawCalibrationPulse(Canvas canvas, Size size) {
    final centerY = size.height * 0.2;
    final pxPerMvLocal = mmPerMv * pmm;
    final pxPerSec = mmPerSecond * pmm;
    final pulseHeight = 1.0 * pxPerMvLocal;
    final pulseWidth = pxPerSec * 0.2;

    final startX = pmm * 5.0;
    final p = Paint()
      ..color = Colors.black87
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(startX, centerY)
      ..lineTo(startX, centerY - pulseHeight)
      ..lineTo(startX + pulseWidth, centerY - pulseHeight)
      ..lineTo(startX + pulseWidth, centerY);

    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant ECGPaperPainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.leadName != leadName;
  }
}

/// ECGChart widget wrapper

class ECGChart extends StatelessWidget {
  final String leadName;
  final List<double> samples;
  final Color color;
  final double height;
  final bool showCalibration;
  final double pmm;

  const ECGChart({
    super.key,
    required this.leadName,
    required this.samples,
    required this.color,
    required this.pmm,
    this.height = 120,
    this.showCalibration = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF5F5),
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: CustomPaint(
        painter: ECGPaperPainter(
          samples: samples,
          lineColor: color,
          samplingRateLocal: samplingRate,
          leadName: leadName,
          showGrid: true,
          showCalibration: showCalibration,
          pmm: pmm,
        ),
        child: Container(),
      ),
    );
  }
}

/// Main Application
class ECGApp extends StatefulWidget {
  const ECGApp({super.key});

  @override
  State<ECGApp> createState() => _ECGAppState();
}

class _ECGAppState extends State<ECGApp> with SingleTickerProviderStateMixin {
  final BluetoothService btService = BluetoothService();
  final ECGParser parser = ECGParser();
  final WaveformController waveController = WaveformController();

  List<Device> devices = [];
  Device? connectedDevice;
  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<Device>? _discoverySub;
  StreamSubscription<ECGData>? _ecgSub;
  // removed unused bluetooth connection variable

  bool isAcquiring = false;
  String statusMessage = 'Disconnected';
  int currentGain = 1;
  double calibration = defaultRawToMv;
  String selectedLead = 'II';
  late TabController tabController;
  ECGData? lastECGData;

  bool useMock = false;
  Timer? _mockTimer;

  @override
  void initState() {
    super.initState();
    tabController = TabController(length: 3, vsync: this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await btService.initPermissions();
      final paired = await btService.getPairedDevices();
      setState(() => devices = paired);

      // Listen to discovered devices; if target found, auto connect
      _discoverySub = btService.onDeviceDiscovered().listen((device) {
        if (!devices.any((d) => d.address == device.address)) {
          setState(() => devices.add(device));
        }
        if (device.name == 'ECGREC-232401-177' && connectedDevice == null) {
          _connectToDevice(device);
        }
      });

      _ecgSub = parser.stream.listen((ecgData) {
        lastECGData = ecgData;
        waveController.addECGData(ecgData);
      });

      // start scanning to discover unpaired devices (optional)
      await btService.startScan();
    } catch (e) {
      setState(() => statusMessage = 'Init error: $e');
    }
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _discoverySub?.cancel();
    _ecgSub?.cancel();
    parser.dispose();
    waveController.dispose();
    tabController.dispose();
    _mockTimer?.cancel();
    super.dispose();
  }

  Future<void> _connectToDevice(Device device) async {
    setState(
      () => statusMessage = 'Connecting to ${device.name ?? device.address}...',
    );
    try {
      final success = await btService.connect(
        device.address,
        "00001101-0000-1000-8000-00805f9b34fb",
      );
      if (!success) {
        setState(() => statusMessage = 'Connection failed');
        return;
      }
      setState(() {
        connectedDevice = device;
        statusMessage = 'Connected to ${device.name ?? device.address}';
        useMock = false;
      });
      _mockTimer?.cancel();

      _dataSub?.cancel();
      // Subscribe to raw bytes from device and feed to parser
      _dataSub = btService.onDataReceived().listen(
        (bytes) {
          // bytes is Uint8List
          parser.addBytes(bytes);
        },
        onError: (e) {
          setState(() => statusMessage = 'Data stream error: $e');
        },
        onDone: () {
          setState(() {
            statusMessage = 'Disconnected';
            connectedDevice = null;
          });
        },
      );
    } catch (e) {
      setState(() => statusMessage = 'Connect error: $e');
    }
  }

  Future<void> _disconnect() async {
    if (isAcquiring) await _stopAcquisition();
    try {
      await btService.disconnect();
    } catch (e) {}
    _dataSub?.cancel();
    setState(() {
      connectedDevice = null;
      statusMessage = 'Disconnected';
      lastECGData = null;
    });
    waveController.clear();
  }

  Future<void> _startAcquisition() async {
    if (connectedDevice == null) return;
    waveController.clear();
    waveController.setGain(currentGain);
    waveController.setRawToMv(calibration);

    try {
      await btService.write('S'); // stop if running
      await Future.delayed(const Duration(milliseconds: 200));
      await btService.write('R'); // reset / ready
      await Future.delayed(const Duration(milliseconds: 200));

      // map our selected gain to commands (common mapping in manufacturer code)
      final gainCommands = {
        1: 'B',
        2: 'C',
        3: 'D',
        4: 'E',
        6: 'F',
        8: 'G',
        12: 'H',
      };
      final gainCmd = gainCommands[currentGain] ?? 'B';
      await btService.write(gainCmd);
      await Future.delayed(const Duration(milliseconds: 200));

      await btService.write('A'); // start acquisition
      setState(() {
        isAcquiring = true;
        statusMessage = 'Acquiring...';
      });
    } catch (e) {
      setState(() => statusMessage = 'Start error: $e');
    }
  }

  Future<void> _stopAcquisition() async {
    try {
      await btService.write('S'); // stop
      setState(() {
        isAcquiring = false;
        statusMessage = 'Stopped';
      });
    } catch (e) {
      setState(() => statusMessage = 'Stop error: $e');
    }
  }

  // Mock generator for testing without device
  void _startMock() {
    _mockTimer?.cancel();
    final fs = samplingRate;
    final dt = 1.0 / fs;
    double t = 0.0;
    final rng = Random();

    _mockTimer = Timer.periodic(Duration(microseconds: (1e6 / fs).round()), (
      _,
    ) {
      final hrBpm = 72.0;
      final rr = 60.0 / hrBpm;
      final ph = (t % rr) / rr;
      double ecg = 0.0;
      ecg += 0.12 * exp(-pow((ph - 0.18) / 0.03, 2));
      ecg += -0.15 * exp(-pow((ph - 0.36) / 0.01, 2));
      ecg += 1.10 * exp(-pow((ph - 0.40) / 0.008, 2));
      ecg += -0.25 * exp(-pow((ph - 0.44) / 0.012, 2));
      ecg += 0.35 * exp(-pow((ph - 0.62) / 0.05, 2));
      ecg += 0.02 * sin(2 * pi * 0.33 * t) + (rng.nextDouble() - 0.5) * 0.01;

      // push to buffers as mV (mock already in mV)
      final leadMap = {
        'I': ecg * 0.95,
        'II': ecg,
        'III': ecg * 0.90,
        'aVR': -ecg * 0.5,
        'aVL': ecg * 0.4,
        'aVF': ecg * 0.5,
        'V1': ecg * 0.8,
        'V2': ecg * 0.85,
        'V3': ecg * 0.9,
        'V4': ecg * 0.95,
        'V5': ecg * 1.0,
        'V6': ecg * 0.9,
      };

      for (var kv in leadMap.entries) {
        final q = waveController.leadBuffers[kv.key]!;
        q.add(kv.value);
        if (q.length > samplesWindow) q.removeFirst();
      }
      waveController.tick.value++;
      t += dt;
    });
  }

  String _getGroupName(int groupIndex) {
    switch (groupIndex) {
      case 0:
        return 'Limb Leads';
      case 1:
        return 'Augmented Leads';
      case 2:
        return 'Precordial V1-V3';
      case 3:
        return 'Precordial V4-V6';
      default:
        return 'Leads';
    }
  }

  Widget _buildDeviceSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connectedDevice != null
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
                  color: connectedDevice != null ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    connectedDevice != null
                        ? 'Connected: ${connectedDevice!.name ?? connectedDevice!.address}'
                        : 'Scanning for ECGREC-232401-177...',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  statusMessage,
                  style: TextStyle(
                    color: isAcquiring ? Colors.green : Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _showDeviceDialog(),
                  icon: const Icon(Icons.devices),
                  label: Text(
                    connectedDevice != null ? 'Change Device' : 'Select Device',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade600,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            if (lastECGData != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      lastECGData!.batteryStatus,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Text(
                      lastECGData!.leadStatus,
                      style: const TextStyle(fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildControlPanel() {
    final isConnected = connectedDevice != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Text(
                  'Gain:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: currentGain,
                  items: [1, 2, 3, 4, 6, 8, 12]
                      .map(
                        (g) => DropdownMenuItem(value: g, child: Text('${g}x')),
                      )
                      .toList(),
                  onChanged: isAcquiring
                      ? null
                      : (v) {
                          if (v != null) setState(() => currentGain = v);
                        },
                ),
                const SizedBox(width: 16),
                const Text(
                  'Calibration (µV/count):',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: calibration,
                    min: 0.0001,
                    max: 0.01,
                    divisions: 100,
                    label: '${(calibration * 1000000).toStringAsFixed(1)}µV',
                    onChanged: (v) {
                      setState(() {
                        calibration = v;
                        waveController.setRawToMv(calibration);
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text('${(calibration * 1000000).toStringAsFixed(1)}µV'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: isConnected && !isAcquiring
                      ? _startAcquisition
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start ECG'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: isAcquiring ? _stopAcquisition : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                ),
                ElevatedButton.icon(
                  onPressed: isConnected ? _disconnect : null,
                  icon: const Icon(Icons.bluetooth_disabled),
                  label: const Text('Disconnect'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    waveController.clear();
                    setState(() => lastECGData = null);
                  },
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear'),
                ),
                Switch(
                  value: useMock,
                  onChanged: (v) {
                    setState(() {
                      useMock = v;
                      if (v) {
                        _startMock();
                      } else {
                        _mockTimer?.cancel();
                      }
                    });
                  },
                ),
                const Text('Mock'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStandardTwelveLeadView() {
    final leadGroups = [
      ['I', 'II', 'III'],
      ['aVR', 'aVL', 'aVF'],
      ['V1', 'V2', 'V3'],
      ['V4', 'V5', 'V6'],
    ];

    final colors = [
      Colors.blue.shade700,
      Colors.red.shade700,
      Colors.green.shade700,
      Colors.purple.shade700,
      Colors.orange.shade700,
      Colors.teal.shade700,
      Colors.indigo.shade700,
      Colors.pink.shade700,
      Colors.brown.shade700,
      Colors.cyan.shade700,
      Colors.lime.shade700,
      Colors.amber.shade700,
    ];

    final pmm = pixelsPerMmDefault;

    return ValueListenableBuilder(
      valueListenable: waveController.tick,
      builder: (context, _, __) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: leadGroups.asMap().entries.map((groupEntry) {
              final groupIndex = groupEntry.key;
              final leads = groupEntry.value;
              return Column(
                children: [
                  if (groupIndex > 0) const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      _getGroupName(groupIndex),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  ...leads.asMap().entries.map((leadEntry) {
                    final leadIndex = leadEntry.key;
                    final lead = leadEntry.value;
                    final colorIndex = groupIndex * 3 + leadIndex;
                    final samples = waveController.getSamples(lead);
                    return ECGChart(
                      leadName: lead,
                      samples: samples,
                      color: colors[colorIndex % colors.length],
                      height: 100,
                      showCalibration: groupIndex == 0 && leadIndex == 0,
                      pmm: pmm,
                    );
                  }).toList(),
                ],
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildSingleLeadView() {
    final allLeads = [
      'I',
      'II',
      'III',
      'aVR',
      'aVL',
      'aVF',
      'V1',
      'V2',
      'V3',
      'V4',
      'V5',
      'V6',
    ];
    final pmm = pixelsPerMmDefault;

    return Column(
      children: [
        Card(
          margin: const EdgeInsets.all(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Text(
                  'Lead:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: selectedLead,
                  items: allLeads
                      .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    if (v != null) selectedLead = v;
                  }),
                ),
                const Spacer(),
                Text(
                  'Samples: ${waveController.getSamples(selectedLead).length}',
                ),
                const SizedBox(width: 16),
                Text('Gain: ${currentGain}x'),
                const SizedBox(width: 16),
                Text('${(calibration * 1000000).toStringAsFixed(1)}µV/count'),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: ValueListenableBuilder(
              valueListenable: waveController.tick,
              builder: (context, _, __) {
                final samples = waveController.getSamples(selectedLead);
                return ECGChart(
                  leadName: selectedLead,
                  samples: samples,
                  color: Colors.red.shade700,
                  height: double.infinity,
                  showCalibration: true,
                  pmm: pmm,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDataAnalysis() {
    return ValueListenableBuilder(
      valueListenable: waveController.tick,
      builder: (context, _, __) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Real-time Statistics',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (lastECGData != null) ...[
                        _buildStatRow('Heart Rate', _calculateHeartRate()),
                        _buildStatRow('Lead Status', lastECGData!.leadStatus),
                        _buildStatRow('Battery', lastECGData!.batteryStatus),
                        _buildStatRow(
                          'Timestamp',
                          lastECGData!.timestamp.toString().substring(11, 19),
                        ),
                      ] else
                        const Text('No ECG data received yet'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Lead Sample Counts',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: waveController.leadBuffers.entries.map((
                          entry,
                        ) {
                          final leadName = entry.key;
                          final sampleCount = entry.value.length;
                          return Chip(
                            label: Text('$leadName: $sampleCount'),
                            backgroundColor: sampleCount > 100
                                ? Colors.green.shade100
                                : Colors.orange.shade100,
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Recent Lead II Values (mV)',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          ElevatedButton.icon(
                            onPressed: waveController.clear,
                            icon: const Icon(Icons.clear_all),
                            label: const Text('Clear All Data'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 60,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: min(
                            20,
                            waveController.getSamples('II').length,
                          ),
                          itemBuilder: (context, i) {
                            final samples = waveController.getSamples('II');
                            if (i >= samples.length) return const SizedBox();
                            final value = samples[samples.length - 1 - i];
                            return Container(
                              width: 80,
                              margin: const EdgeInsets.only(right: 4),
                              child: Card(
                                child: Center(
                                  child: Text(
                                    value.toStringAsFixed(3),
                                    style: const TextStyle(fontSize: 12),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  String _calculateHeartRate() {
    final samples = waveController.getSamples('II');
    if (samples.length < 100) return 'Calculating...';

    int peakCount = 0;
    double threshold = 0.5;
    bool wasAboveThreshold = false;

    for (int i = 1; i < samples.length; i++) {
      final current = samples[i];
      final previous = samples[i - 1];
      if (current > threshold && !wasAboveThreshold) {
        if (previous <= threshold) {
          peakCount++;
        }
        wasAboveThreshold = true;
      } else if (current <= threshold) {
        wasAboveThreshold = false;
      }
    }

    if (peakCount < 2) return 'Detecting...';
    final timeSpan = samples.length / samplingRate;
    final bpm = (peakCount / timeSpan * 60).round();
    return '$bpm BPM';
  }

  void _showDeviceDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Bluetooth Devices'),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  children: [
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () async {
                            await btService.startScan();
                            setDialogState(() {});
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh Scan'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () async {
                            await btService.stopScan();
                            setDialogState(() {});
                          },
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop Scan'),
                        ),
                        const Spacer(),
                        Text('${devices.length} devices found'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 8),
                    Expanded(
                      child: devices.isEmpty
                          ? const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 16),
                                  Text('Scanning for devices...'),
                                  SizedBox(height: 8),
                                  Text(
                                    'Make sure your ECG device is in pairing mode',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: devices.length,
                              itemBuilder: (context, index) {
                                final device = devices[index];
                                final isECG =
                                    device.name == 'ECGREC-232401-177';
                                final isConnected =
                                    connectedDevice?.address == device.address;
                                return Card(
                                  elevation: isECG ? 3 : 1,
                                  color: isConnected
                                      ? Colors.green.shade50
                                      : isECG
                                      ? Colors.red.shade50
                                      : null,
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: isConnected
                                          ? Colors.green
                                          : isECG
                                          ? Colors.red
                                          : Colors.blue,
                                      child: Icon(
                                        isConnected
                                            ? Icons.check
                                            : isECG
                                            ? Icons.monitor_heart
                                            : Icons.bluetooth,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                    title: Text(
                                      device.name ?? 'Unknown Device',
                                      style: TextStyle(
                                        fontWeight: isECG
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          device.address,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                        if (isECG)
                                          const Text(
                                            'ECG Device Detected',
                                            style: TextStyle(
                                              color: Colors.red,
                                              fontWeight: FontWeight.w500,
                                              fontSize: 12,
                                            ),
                                          ),
                                        if (isConnected)
                                          const Text(
                                            'Currently Connected',
                                            style: TextStyle(
                                              color: Colors.green,
                                              fontWeight: FontWeight.w500,
                                              fontSize: 12,
                                            ),
                                          ),
                                      ],
                                    ),
                                    trailing: isConnected
                                        ? ElevatedButton.icon(
                                            onPressed: () async {
                                              Navigator.of(context).pop();
                                              await _disconnect();
                                            },
                                            icon: const Icon(
                                              Icons.bluetooth_disabled,
                                            ),
                                            label: const Text('Disconnect'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.red,
                                              foregroundColor: Colors.white,
                                            ),
                                          )
                                        : ElevatedButton.icon(
                                            onPressed: () async {
                                              Navigator.of(context).pop();
                                              await _connectToDevice(device);
                                            },
                                            icon: const Icon(
                                              Icons.bluetooth_connected,
                                            ),
                                            label: const Text('Connect'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: isECG
                                                  ? Colors.red
                                                  : Colors.blue,
                                              foregroundColor: Colors.white,
                                            ),
                                          ),
                                    isThreeLine: true,
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
                if (connectedDevice == null)
                  ElevatedButton.icon(
                    onPressed: () async {
                      await btService.startScan();
                      setDialogState(() {});
                    },
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('Scan Again'),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Medigraphy ECG Monitor',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Medigraphy ECG Monitor'),
          actions: [
            IconButton(
              icon: const Icon(Icons.devices),
              onPressed: _showDeviceDialog,
            ),
            IconButton(
              icon: const Icon(Icons.bluetooth_searching),
              onPressed: btService.startScan,
            ),
            IconButton(
              icon: Icon(isAcquiring ? Icons.pause : Icons.play_arrow),
              onPressed: connectedDevice != null
                  ? (isAcquiring ? _stopAcquisition : _startAcquisition)
                  : null,
            ),
          ],
          bottom: TabBar(
            controller: tabController,
            tabs: const [
              Tab(icon: Icon(Icons.grid_view), text: '12-Lead ECG'),
              Tab(icon: Icon(Icons.show_chart), text: 'Single Lead'),
              Tab(icon: Icon(Icons.analytics), text: 'Analysis'),
            ],
          ),
        ),
        body: Column(
          children: [
            _buildDeviceSection(),
            _buildControlPanel(),
            Expanded(
              child: TabBarView(
                controller: tabController,
                children: [
                  _buildStandardTwelveLeadView(),
                  _buildSingleLeadView(),
                  _buildDataAnalysis(),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FloatingActionButton(
              heroTag: 'devices',
              mini: true,
              onPressed: _showDeviceDialog,
              backgroundColor: Colors.blue.shade600,
              child: const Icon(Icons.devices, color: Colors.white),
            ),
            const SizedBox(height: 8),
            FloatingActionButton(
              heroTag: 'main_action',
              onPressed: connectedDevice != null
                  ? (isAcquiring ? _stopAcquisition : _startAcquisition)
                  : () => _showDeviceDialog(),
              backgroundColor: connectedDevice != null
                  ? (isAcquiring ? Colors.red : Colors.green)
                  : Colors.orange,
              child: Icon(
                connectedDevice != null
                    ? (isAcquiring ? Icons.stop : Icons.play_arrow)
                    : Icons.bluetooth_searching,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
