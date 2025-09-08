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

/// ECG Data Model - Enhanced with proper validation
class ECGData {
  final int leadV6, leadI, leadII, leadV2, leadV4, leadV3, leadV5, leadV1;
  final int aVR, aVL, aVF;
  final int status1, status2, status3;
  final int batteryLevel;
  final DateTime timestamp;
  final bool isValid;

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
    this.isValid = true,
  });

  String get batteryStatus {
    final b = batteryLevel & 0x0F;
    return 'Battery: ${(b / 15 * 100).round()}%';
  }

  String get leadStatus {
    final failures = <String>[];
    final connected = <String>[];

    // Status1: V4, V3, V5, V1 (bits 0-3)
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

    // Status2: V6, LA, LL, V2 (bits 4-7)
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

    // Status3: RA (bit 4)
    if ((status3 & 0x10) != 0) failures.add('RA');

    String status = '';
    if (connected.isNotEmpty) status += 'Connected: ${connected.join(", ")}';
    if (failures.isNotEmpty) {
      if (status.isNotEmpty) status += ' | ';
      status += 'Disconnected: ${failures.join(", ")}';
    }
    return status.isEmpty ? 'No lead data' : status;
  }

  // Validate ECG data ranges (typical ECG values)
  bool get hasValidSignals {
    final leads = [
      leadI,
      leadII,
      leadV1,
      leadV2,
      leadV3,
      leadV4,
      leadV5,
      leadV6,
    ];
    return leads.every((lead) => lead.abs() < 32000); // Prevent overflow values
  }
}

/// Enhanced Constants
const double samplingRate = 250.0; // Hz - confirmed for most ECG devices
const double timeWindowSeconds = 10.0;
final int samplesWindow = (samplingRate * timeWindowSeconds).round();

// Calibration constants - more accurate for medical ECG
const double defaultRawToMv =
    0.00488; // 4.88 µV per LSB (typical for 12-bit ADC)
const double ecgGainFactor = 1.0; // Remove the arbitrary *2 multiplication

// ECG paper standards
const double mmPerSecond = 25.0; // 25 mm/s standard paper speed
const double mmPerMv = 10.0; // 10 mm per 1 mV standard
double pixelsPerMmDefault = 4.0;

/// Proper 16-bit signed conversion
int toSigned16(int msb, int lsb) {
  int val = (msb << 8) | (lsb & 0xFF);
  return val > 32767 ? val - 65536 : val;
}

/// Bluetooth Service Wrapper
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

/// Enhanced ECG Parser with Better Validation
class ECGParser {
  final _out = StreamController<ECGData>.broadcast();
  Stream<ECGData> get stream => _out.stream;

  Uint8List _buffer = Uint8List(0);
  int lastStatus1 = 0, lastStatus2 = 0, lastStatus3 = 0;
  int _packetCount = 0;
  int _errorCount = 0;

  void addBytes(Uint8List data) {
    _buffer = Uint8List.fromList([..._buffer, ...data]);

    while (true) {
      final dataEvent = _tryParseOnePacket();
      if (dataEvent == null) break;

      _packetCount++;
      if (dataEvent.isValid) {
        _out.add(dataEvent);
      } else {
        _errorCount++;
        print('Invalid ECG packet detected. Error count: $_errorCount');
      }
    }
  }

  ECGData? _tryParseOnePacket() {
    if (_buffer.isEmpty) return null;

    // Find packet start
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
      if (_buffer.length < 22) return null;

      // Validate termination
      if (_buffer[21] != 0x0A) {
        _buffer = Uint8List.fromList(_buffer.sublist(1));
        return null;
      }

      final pkt = _buffer.sublist(0, 22);
      _buffer = Uint8List.fromList(_buffer.sublist(22));
      return _parseAAPacket(pkt);
    } else if (start == 0xBB) {
      if (_buffer.length < 18) return null;

      if (_buffer[17] != 0x0A) {
        _buffer = Uint8List.fromList(_buffer.sublist(1));
        return null;
      }

      final pkt = _buffer.sublist(0, 18);
      _buffer = Uint8List.fromList(_buffer.sublist(18));
      return _parseBBPacket(pkt);
    }

    _buffer = Uint8List.fromList(_buffer.sublist(1));
    return null;
  }

  ECGData _parseAAPacket(Uint8List pkt) {
    // Update status from AA packets
    lastStatus1 = pkt[1];
    lastStatus2 = pkt[2];
    lastStatus3 = pkt[3];

    // Parse leads without arbitrary gain multiplication
    int v6 = toSigned16(pkt[4], pkt[5]);
    int i = toSigned16(pkt[6], pkt[7]);
    int ii = toSigned16(pkt[8], pkt[9]);
    int v2 = toSigned16(pkt[10], pkt[11]);
    int v4 = toSigned16(pkt[12], pkt[13]);
    int v3 = toSigned16(pkt[14], pkt[15]);
    int v5 = toSigned16(pkt[16], pkt[17]);
    int v1 = toSigned16(pkt[18], pkt[19]);

    // Calculate augmented leads correctly
    final avr = -(i + ii) ~/ 2;
    final avl = i - (ii ~/ 2);
    final avf = ii - (i ~/ 2);

    final ecgData = ECGData(
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
      isValid: _validateECGData(v1, v2, v3, v4, v5, v6, i, ii),
    );

    return ecgData;
  }

  ECGData _parseBBPacket(Uint8List pkt) {
    // Parse leads from BB packets
    int v6 = toSigned16(pkt[1], pkt[2]);
    int i = toSigned16(pkt[3], pkt[4]);
    int ii = toSigned16(pkt[5], pkt[6]);
    int v2 = toSigned16(pkt[7], pkt[8]);
    int v4 = toSigned16(pkt[9], pkt[10]);
    int v3 = toSigned16(pkt[11], pkt[12]);
    int v5 = toSigned16(pkt[13], pkt[14]);
    int v1 = toSigned16(pkt[15], pkt[16]);

    final avr = -(i + ii) ~/ 2;
    final avl = i - (ii ~/ 2);
    final avf = ii - (i ~/ 2);

    final ecgData = ECGData(
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
      isValid: _validateECGData(v1, v2, v3, v4, v5, v6, i, ii),
    );

    return ecgData;
  }

  bool _validateECGData(
    int v1,
    int v2,
    int v3,
    int v4,
    int v5,
    int v6,
    int i,
    int ii,
  ) {
    final leads = [v1, v2, v3, v4, v5, v6, i, ii];

    // Check for reasonable ECG values (not saturated or invalid)
    for (final lead in leads) {
      if (lead.abs() > 30000) return false; // Likely saturated
      if (lead == -32768 || lead == 32767) return false; // Invalid values
    }

    // Basic physiological check - at least some leads should have variation
    final hasVariation = leads.any((lead) => lead.abs() > 50);
    return hasVariation;
  }

  double get packetSuccessRate =>
      _packetCount > 0 ? ((_packetCount - _errorCount) / _packetCount) : 0.0;

  void dispose() => _out.close();
}

/// Enhanced Digital Filters
class HighPassFilter {
  final double alpha;
  double _y = 0.0;
  double _xPrev = 0.0;

  HighPassFilter(double cutoffHz, double sampleRateHz)
    : alpha = sampleRateHz / (sampleRateHz + 2 * pi * cutoffHz);

  double process(double x) {
    _y = alpha * (_y + x - _xPrev);
    _xPrev = x;
    return _y;
  }
}

class LowPassFilter {
  final double alpha;
  double _y = 0.0;
  double _xPrev = 0.0;

  LowPassFilter(double cutoffHz, double sampleRateHz)
    : alpha = (2 * pi * cutoffHz) / (sampleRateHz + 2 * pi * cutoffHz);

  double process(double x) {
    final y = alpha * x + (1 - alpha) * _y;
    _xPrev = x;
    _y = y;
    return y;
  }
}

class NotchFilter {
  final double b0, b1, b2, a1, a2;
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;

  NotchFilter(double fs, double f0, double q)
    : b0 = 1,
      b1 = -2 * cos(2 * pi * f0 / fs),
      b2 = 1,
      a1 = -2 * cos(2 * pi * f0 / fs) * (1 - 1 / (2 * q)),
      a2 = (1 - 1 / (2 * q)) / (1 + 1 / (2 * q));

  double process(double x) {
    final y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
    return y;
  }
}

/// Enhanced Filter Chain for ECG
class ECGFilterChain {
  final HighPassFilter hpFilter;
  final LowPassFilter lpFilter;
  final NotchFilter? notchFilter;
  final bool enableNotch;

  ECGFilterChain({
    required double sampleRate,
    this.enableNotch = true,
    double highPassCutoff = 0.5,
    double lowPassCutoff = 40.0,
    double notchFreq = 50.0,
  }) : hpFilter = HighPassFilter(highPassCutoff, sampleRate),
       lpFilter = LowPassFilter(lowPassCutoff, sampleRate),
       notchFilter = enableNotch
           ? NotchFilter(sampleRate, notchFreq, 30.0)
           : null;

  double process(double x) {
    var y = hpFilter.process(x);
    if (enableNotch && notchFilter != null) {
      y = notchFilter!.process(y);
    }
    y = lpFilter.process(y);
    return y;
  }
}

/// Enhanced Waveform Controller
class WaveformController {
  final Map<String, ECGFilterChain> filters = {};
  final Map<String, ListQueue<double>> leadBuffers = {};
  final ValueNotifier<int> tick = ValueNotifier<int>(0);

  double rawToMv = defaultRawToMv;
  int currentGain = 1;
  Timer? _uiTimer;

  // Statistics
  int _samplesProcessed = 0;
  DateTime? _firstSampleTime;
  double _actualSampleRate = 0.0;

  WaveformController() {
    _initializeFiltersAndBuffers();
    _startUITimer();
  }

  void _initializeFiltersAndBuffers() {
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

    for (var lead in allLeads) {
      filters[lead] = ECGFilterChain(
        sampleRate: samplingRate,
        enableNotch: true,
        highPassCutoff: 0.5, // Remove baseline drift
        lowPassCutoff: 40.0, // Anti-aliasing and noise reduction
        notchFreq: 50.0, // Power line interference
      );
      leadBuffers[lead] = ListQueue<double>();
    }
  }

  void _startUITimer() {
    _uiTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      tick.value++;
    });
  }

  void setRawToMv(double v) => rawToMv = v;
  void setGain(int g) => currentGain = max(1, g);

  void addECGData(ECGData d) {
    if (!d.isValid || !d.hasValidSignals) return;

    _updateSampleStatistics();

    // Calculate Lead III correctly: Lead III = Lead II - Lead I
    final leadRaw = <String, int>{
      'I': d.leadI,
      'II': d.leadII,
      'III': d.leadII - d.leadI, // Correct calculation
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
      final lead = entry.key;
      final rawValue = entry.value;

      // Convert to mV with proper calibration
      final mvRaw = (rawValue * rawToMv * ecgGainFactor) / max(1, currentGain);

      // Apply filtering
      final mvFiltered = filters[lead]!.process(mvRaw);

      // Validate filtered result
      if (mvFiltered.isFinite && mvFiltered.abs() < 20.0) {
        // Typical ECG range ±20mV
        leadBuffers[lead]!.add(mvFiltered);
      } else {
        // Add zero for invalid samples to maintain timing
        leadBuffers[lead]!.add(0.0);
      }

      // Maintain buffer size
      if (leadBuffers[lead]!.length > samplesWindow) {
        leadBuffers[lead]!.removeFirst();
      }
    }
  }

  void _updateSampleStatistics() {
    _samplesProcessed++;
    _firstSampleTime ??= DateTime.now();

    final elapsed = DateTime.now().difference(_firstSampleTime!).inMilliseconds;
    if (elapsed > 1000) {
      // Update every second
      _actualSampleRate = _samplesProcessed / (elapsed / 1000.0);
    }
  }

  List<double> getSamples(String lead) =>
      List<double>.from(leadBuffers[lead] ?? []);

  double get actualSampleRate => _actualSampleRate;
  int get totalSamplesProcessed => _samplesProcessed;

  void clear() {
    for (var q in leadBuffers.values) q.clear();
    _samplesProcessed = 0;
    _firstSampleTime = null;
    _actualSampleRate = 0.0;
    tick.value++;
  }

  void dispose() {
    _uiTimer?.cancel();
    tick.dispose();
  }
}

/// Enhanced ECG Paper Painter
class ECGPaperPainter extends CustomPainter {
  final List<double> samples;
  final Color lineColor;
  final String leadName;
  final bool showGrid;
  final bool showCalibration;
  final double pmm;
  final double samplingRateLocal;
  final double mmPerSecLocal;

  ECGPaperPainter({
    required this.samples,
    required this.lineColor,
    required this.leadName,
    required this.pmm,
    required this.samplingRateLocal,
    this.showGrid = true,
    this.showCalibration = false,
    this.mmPerSecLocal = mmPerSecond,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _drawBackground(canvas, size);
    if (showGrid) _drawGrid(canvas, size);
    _drawWaveform(canvas, size);
    _drawLeadLabel(canvas, size);
    if (showCalibration) _drawCalibrationPulse(canvas, size);
  }

  void _drawBackground(Canvas canvas, Size size) {
    final bg = Paint()
      ..color = const Color(0xFFFDF8F8); // Slightly warmer background
    canvas.drawRect(Offset.zero & size, bg);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final fineGrid = Paint()
      ..color = const Color(0xFFE8C4C4)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    final boldGrid = Paint()
      ..color = const Color(0xFFD49999)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final smallStep = pmm * 1.0; // 1mm
    final largeStep = pmm * 5.0; // 5mm

    // Draw vertical lines
    for (double x = 0; x <= size.width; x += smallStep) {
      final isBold = (x % largeStep).abs() < 0.5;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        isBold ? boldGrid : fineGrid,
      );
    }

    // Draw horizontal lines
    for (double y = 0; y <= size.height; y += smallStep) {
      final isBold = (y % largeStep).abs() < 0.5;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        isBold ? boldGrid : fineGrid,
      );
    }
  }

  void _drawWaveform(Canvas canvas, Size size) {
    if (samples.isEmpty) {
      _drawNoDataMessage(canvas, size);
      return;
    }

    final waveformPaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final centerY = size.height / 2.0;
    final pixelsPerSecond = mmPerSecLocal * pmm;
    final pixelsPerSample = pixelsPerSecond / samplingRateLocal;
    final pixelsPerMv = mmPerMv * pmm;

    final path = Path();
    bool pathStarted = false;

    // Calculate visible sample range
    final maxVisibleSamples = (size.width / pixelsPerSample).ceil();
    final startIndex = max(0, samples.length - maxVisibleSamples);

    for (int i = startIndex; i < samples.length; i++) {
      final sampleIndex = i - startIndex;
      final mv = samples[i];
      final x = sampleIndex * pixelsPerSample;
      final y = centerY - (mv * pixelsPerMv);

      // Clamp to visible area
      final clampedX = x.clamp(0.0, size.width);
      final clampedY = y.clamp(0.0, size.height);

      if (!pathStarted) {
        path.moveTo(clampedX, clampedY);
        pathStarted = true;
      } else {
        path.lineTo(clampedX, clampedY);
      }
    }

    canvas.drawPath(path, waveformPaint);

    // Draw baseline reference
    final baselinePaint = Paint()
      ..color = Colors.red.withOpacity(0.3)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      baselinePaint,
    );
  }

  void _drawNoDataMessage(Canvas canvas, Size size) {
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'No ECG data',
        style: TextStyle(color: Colors.grey, fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        (size.width - textPainter.width) / 2,
        (size.height - textPainter.height) / 2,
      ),
    );
  }

  void _drawLeadLabel(Canvas canvas, Size size) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: leadName,
        style: TextStyle(
          color: lineColor.withOpacity(0.8),
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, const Offset(8, 8));
  }

  void _drawCalibrationPulse(Canvas canvas, Size size) {
    final calibrationPaint = Paint()
      ..color = Colors.black87
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final startY = size.height * 0.8;
    final pulseHeight = mmPerMv * pmm; // 1 mV pulse
    final pulseWidth = mmPerSecLocal * pmm * 0.2; // 200ms pulse
    final startX = pmm * 10;

    final path = Path()
      ..moveTo(startX, startY)
      ..lineTo(startX, startY - pulseHeight)
      ..lineTo(startX + pulseWidth, startY - pulseHeight)
      ..lineTo(startX + pulseWidth, startY);

    canvas.drawPath(path, calibrationPaint);

    // Label the calibration pulse
    final labelPainter = TextPainter(
      text: const TextSpan(
        text: '1mV',
        style: TextStyle(color: Colors.black87, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    );
    labelPainter.layout();
    labelPainter.paint(canvas, Offset(startX, startY - pulseHeight - 15));
  }

  @override
  bool shouldRepaint(covariant ECGPaperPainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.leadName != leadName;
  }
}

/// ECG Chart Widget
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
        color: const Color(0xFFFDF8F8),
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: CustomPaint(
        painter: ECGPaperPainter(
          samples: samples,
          lineColor: color,
          leadName: leadName,
          pmm: pmm,
          samplingRateLocal: samplingRate,
          showGrid: true,
          showCalibration: showCalibration,
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
      _dataSub = btService.onDataReceived().listen(
        (bytes) => parser.addBytes(bytes),
        onError: (e) => setState(() => statusMessage = 'Data stream error: $e'),
        onDone: () => setState(() {
          statusMessage = 'Disconnected';
          connectedDevice = null;
        }),
      );
    } catch (e) {
      setState(() => statusMessage = 'Connect error: $e');
    }
  }

  Future<void> _disconnect() async {
    if (isAcquiring) await _stopAcquisition();

    try {
      await btService.disconnect();
    } catch (e) {
      print('Disconnect error: $e');
    }

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
      // Send proper command sequence for ECG device
      await btService.write('S'); // Stop
      await Future.delayed(const Duration(milliseconds: 300));

      await btService.write('R'); // Reset
      await Future.delayed(const Duration(milliseconds: 300));

      // Set gain based on current selection
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
      await Future.delayed(const Duration(milliseconds: 300));

      await btService.write('A'); // Start acquisition

      setState(() {
        isAcquiring = true;
        statusMessage = 'Acquiring ECG data...';
      });
    } catch (e) {
      setState(() => statusMessage = 'Start error: $e');
    }
  }

  Future<void> _stopAcquisition() async {
    try {
      await btService.write('S'); // Stop command
      setState(() {
        isAcquiring = false;
        statusMessage = 'Stopped';
      });
    } catch (e) {
      setState(() => statusMessage = 'Stop error: $e');
    }
  }

  void _startMockData() {
    _mockTimer?.cancel();

    final fs = samplingRate;
    final dt = 1.0 / fs;
    double t = 0.0;
    final rng = Random();

    _mockTimer = Timer.periodic(Duration(microseconds: (1e6 / fs).round()), (
      _,
    ) {
      // Generate realistic ECG-like signal
      final hrBpm = 75.0;
      final rrInterval = 60.0 / hrBpm;
      final phase = (t % rrInterval) / rrInterval;

      // Enhanced ECG morphology with proper P, QRS, T waves
      double ecgSignal = 0.0;

      // P wave (0.08-0.12s)
      if (phase >= 0.15 && phase <= 0.25) {
        ecgSignal += 0.15 * exp(-pow((phase - 0.20) / 0.025, 2));
      }

      // QRS complex (0.06-0.10s)
      if (phase >= 0.35 && phase <= 0.45) {
        // Q wave (negative)
        if (phase >= 0.35 && phase <= 0.37) {
          ecgSignal += -0.2 * exp(-pow((phase - 0.36) / 0.005, 2));
        }
        // R wave (positive, dominant)
        else if (phase >= 0.37 && phase <= 0.41) {
          ecgSignal += 1.2 * exp(-pow((phase - 0.39) / 0.008, 2));
        }
        // S wave (negative)
        else if (phase >= 0.41 && phase <= 0.44) {
          ecgSignal += -0.3 * exp(-pow((phase - 0.42) / 0.008, 2));
        }
      }

      // T wave (0.15-0.25s)
      if (phase >= 0.60 && phase <= 0.85) {
        ecgSignal += 0.3 * exp(-pow((phase - 0.72) / 0.06, 2));
      }

      // Add realistic noise and baseline wander
      ecgSignal += 0.02 * sin(2 * pi * 0.3 * t); // Respiratory artifact
      ecgSignal += (rng.nextDouble() - 0.5) * 0.02; // Random noise

      // Generate lead-specific variations
      final leadVariations = {
        'I': ecgSignal * 0.8,
        'II': ecgSignal * 1.0, // Reference lead
        'III': ecgSignal * 0.6,
        'aVR': -ecgSignal * 0.5, // Inverted
        'aVL': ecgSignal * 0.4,
        'aVF': ecgSignal * 0.7,
        'V1': ecgSignal * 0.6,
        'V2': ecgSignal * 0.8,
        'V3': ecgSignal * 1.1, // Higher amplitude in precordial leads
        'V4': ecgSignal * 1.3,
        'V5': ecgSignal * 1.0,
        'V6': ecgSignal * 0.9,
      };

      // Update buffers with mock data
      for (var entry in leadVariations.entries) {
        final queue = waveController.leadBuffers[entry.key]!;
        queue.add(entry.value);
        if (queue.length > samplesWindow) {
          queue.removeFirst();
        }
      }

      waveController.tick.value++;
      t += dt;
    });

    setState(() {
      useMock = true;
      statusMessage = 'Mock ECG data active';
    });
  }

  String _getGroupName(int groupIndex) {
    const groups = [
      'Limb Leads (I, II, III)',
      'Augmented Leads (aVR, aVL, aVF)',
      'Precordial V1-V3',
      'Precordial V4-V6',
    ];
    return groups[groupIndex] ?? 'Leads';
  }

  Widget _buildDeviceSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connectedDevice != null
                            ? 'Connected: ${connectedDevice!.name ?? connectedDevice!.address}'
                            : 'Searching for ECGREC-232401-177...',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        statusMessage,
                        style: TextStyle(
                          color: isAcquiring
                              ? Colors.green
                              : Colors.grey.shade600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _showDeviceDialog,
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
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.battery_full, color: Colors.green, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          lastECGData!.batteryStatus,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 20),
                        Text(
                          'Sample Rate: ${waveController.actualSampleRate.toStringAsFixed(1)} Hz',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.cable, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
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
                ),
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
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Text(
                  'Gain:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
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
                          if (v != null) {
                            setState(() => currentGain = v);
                            waveController.setGain(v);
                          }
                        },
                ),
                const SizedBox(width: 24),
                const Text(
                  'Calibration:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      Slider(
                        value: calibration,
                        min: 0.001,
                        max: 0.01,
                        divisions: 100,
                        label:
                            '${(calibration * 1000000).toStringAsFixed(1)}µV',
                        onChanged: (v) {
                          setState(() => calibration = v);
                          waveController.setRawToMv(v);
                        },
                      ),
                      Text(
                        '${(calibration * 1000000).toStringAsFixed(1)}µV/count',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
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
                  onPressed: waveController.clear,
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear'),
                ),
                Column(
                  children: [
                    Switch(
                      value: useMock,
                      onChanged: (v) {
                        if (v) {
                          _startMockData();
                        } else {
                          _mockTimer?.cancel();
                          setState(() {
                            useMock = false;
                            statusMessage = 'Mock data stopped';
                          });
                        }
                      },
                    ),
                    const Text('Mock Data', style: TextStyle(fontSize: 12)),
                  ],
                ),
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
      Colors.red.shade700,
      Colors.blue.shade700,
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

    return ValueListenableBuilder(
      valueListenable: waveController.tick,
      builder: (context, _, __) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              // Summary info
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text('Heart Rate: ${_calculateHeartRate()}'),
                      Text('Samples: ${waveController.totalSamplesProcessed}'),
                      Text(
                        'Success Rate: ${(parser.packetSuccessRate * 100).toStringAsFixed(1)}%',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Lead groups
              ...leadGroups.asMap().entries.map((groupEntry) {
                final groupIndex = groupEntry.key;
                final leads = groupEntry.value;

                return Column(
                  children: [
                    if (groupIndex > 0) const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
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
                        pmm: pixelsPerMmDefault,
                      );
                    }),
                  ],
                );
              }),
            ],
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

    return Column(
      children: [
        Card(
          margin: const EdgeInsets.all(8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text(
                      'Lead:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<String>(
                      value: selectedLead,
                      items: allLeads
                          .map(
                            (l) => DropdownMenuItem(value: l, child: Text(l)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() {
                        if (v != null) selectedLead = v;
                      }),
                    ),
                    const Spacer(),
                    ValueListenableBuilder(
                      valueListenable: waveController.tick,
                      builder: (context, _, __) {
                        final samples = waveController.getSamples(selectedLead);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('Samples: ${samples.length}'),
                            if (samples.isNotEmpty)
                              Text(
                                'Range: ${samples.reduce(min).toStringAsFixed(2)} to ${samples.reduce(max).toStringAsFixed(2)} mV',
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('Gain: ${currentGain}x'),
                    const SizedBox(width: 20),
                    Text(
                      'Calibration: ${(calibration * 1000000).toStringAsFixed(1)}µV/count',
                    ),
                    const SizedBox(width: 20),
                    Text('Paper Speed: ${mmPerSecond}mm/s'),
                  ],
                ),
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
                  pmm: pixelsPerMmDefault,
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
              // Real-time statistics
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
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
                        _buildStatRow(
                          'Sample Rate',
                          '${waveController.actualSampleRate.toStringAsFixed(1)} Hz',
                        ),
                        _buildStatRow(
                          'Total Samples',
                          waveController.totalSamplesProcessed.toString(),
                        ),
                        _buildStatRow(
                          'Packet Success Rate',
                          '${(parser.packetSuccessRate * 100).toStringAsFixed(1)}%',
                        ),
                        _buildStatRow('Lead Status', lastECGData!.leadStatus),
                        _buildStatRow('Battery', lastECGData!.batteryStatus),
                        _buildStatRow(
                          'Last Update',
                          lastECGData!.timestamp.toString().substring(11, 19),
                        ),
                      ] else
                        const Text('No ECG data received yet'),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Lead sample counts
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
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
                        runSpacing: 8,
                        children: waveController.leadBuffers.entries.map((
                          entry,
                        ) {
                          final leadName = entry.key;
                          final sampleCount = entry.value.length;
                          final samples = List<double>.from(entry.value);
                          final hasData = samples.isNotEmpty;

                          return Chip(
                            avatar: CircleAvatar(
                              backgroundColor: sampleCount > 100
                                  ? Colors.green
                                  : Colors.orange,
                              child: Text(
                                '${leadName[0]}',
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                            label: Text(
                              '$leadName: $sampleCount${hasData ? " (${samples.last.toStringAsFixed(2)}mV)" : ""}',
                            ),
                            backgroundColor: sampleCount > 100
                                ? Colors.green.shade50
                                : Colors.orange.shade50,
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Recent values visualization
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
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
                        height: 80,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: min(
                            30,
                            waveController.getSamples('II').length,
                          ),
                          itemBuilder: (context, i) {
                            final samples = waveController.getSamples('II');
                            if (i >= samples.length) return const SizedBox();

                            final value = samples[samples.length - 1 - i];
                            final isPositive = value >= 0;

                            return Container(
                              width: 60,
                              margin: const EdgeInsets.only(right: 4),
                              child: Card(
                                color: isPositive
                                    ? Colors.green.shade50
                                    : Colors.red.shade50,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      isPositive
                                          ? Icons.arrow_upward
                                          : Icons.arrow_downward,
                                      size: 16,
                                      color: isPositive
                                          ? Colors.green
                                          : Colors.red,
                                    ),
                                    Text(
                                      value.toStringAsFixed(3),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    Text(
                                      'T-${i}',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  String _calculateHeartRate() {
    final samples = waveController.getSamples('II');
    if (samples.length < samplingRate) return 'Calculating...';

    // Enhanced R-wave detection
    int peakCount = 0;
    double adaptiveThreshold = 0.3;
    bool wasAboveThreshold = false;
    int samplesAboveThreshold = 0;

    // Calculate adaptive threshold based on signal amplitude
    if (samples.isNotEmpty) {
      final maxVal = samples.reduce(max);
      final minVal = samples.reduce(min);
      adaptiveThreshold = (maxVal - minVal) * 0.4 + minVal;
    }

    for (int i = 1; i < samples.length; i++) {
      final current = samples[i];
      final previous = samples[i - 1];

      if (current > adaptiveThreshold) {
        samplesAboveThreshold++;
        if (!wasAboveThreshold && previous <= adaptiveThreshold) {
          // Rising edge detected
          peakCount++;
        }
        wasAboveThreshold = true;
      } else {
        if (wasAboveThreshold && samplesAboveThreshold > 5) {
          // Valid peak completed (minimum width check)
        }
        samplesAboveThreshold = 0;
        wasAboveThreshold = false;
      }
    }

    if (peakCount < 2) return 'Detecting...';

    final timeSpan = samples.length / samplingRate;
    final bpm = ((peakCount - 1) / timeSpan * 60).round().clamp(30, 200);

    return '$bpm BPM';
  }

  void _showDeviceDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Bluetooth ECG Devices'),
              content: SizedBox(
                width: double.maxFinite,
                height: 500,
                child: Column(
                  children: [
                    Card(
                      color: Colors.blue.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Icon(Icons.info, color: Colors.blue.shade700),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'Looking for ECGREC-232401-177 ECG device',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    await btService.startScan();
                                    setDialogState(() {});
                                  },
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Scan'),
                                ),
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    await btService.stopScan();
                                    setDialogState(() {});
                                  },
                                  icon: const Icon(Icons.stop),
                                  label: const Text('Stop'),
                                ),
                                Text('${devices.length} found'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
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
                                    'Ensure ECG device is powered on and in pairing mode',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: devices.length,
                              itemBuilder: (context, index) {
                                final device = devices[index];
                                final isTargetECG =
                                    device.name == 'ECGREC-232401-177';
                                final isConnected =
                                    connectedDevice?.address == device.address;

                                return Card(
                                  elevation: isTargetECG ? 4 : 1,
                                  color: isConnected
                                      ? Colors.green.shade50
                                      : isTargetECG
                                      ? Colors.red.shade50
                                      : null,
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: isConnected
                                          ? Colors.green
                                          : isTargetECG
                                          ? Colors.red.shade600
                                          : Colors.blue,
                                      child: Icon(
                                        isConnected
                                            ? Icons.check
                                            : isTargetECG
                                            ? Icons.monitor_heart
                                            : Icons.bluetooth,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                    title: Text(
                                      device.name ?? 'Unknown Device',
                                      style: TextStyle(
                                        fontWeight: isTargetECG
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
                                            fontSize: 12,
                                          ),
                                        ),
                                        if (isTargetECG)
                                          Container(
                                            margin: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.red.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: const Text(
                                              'ECG Device',
                                              style: TextStyle(
                                                color: Colors.red,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                        if (isConnected)
                                          Container(
                                            margin: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.green.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: const Text(
                                              'Connected',
                                              style: TextStyle(
                                                color: Colors.green,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 11,
                                              ),
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
                                              size: 18,
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
                                              size: 18,
                                            ),
                                            label: const Text('Connect'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: isTargetECG
                                                  ? Colors.red.shade600
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
                    label: const Text('Refresh Scan'),
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
      title: 'Professional ECG Monitor',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(elevation: 2, centerTitle: true),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.monitor_heart, color: Colors.red),
              SizedBox(width: 8),
              Text('Professional ECG Monitor'),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.devices),
              onPressed: _showDeviceDialog,
              tooltip: 'Device Selection',
            ),
            IconButton(
              icon: const Icon(Icons.bluetooth_searching),
              onPressed: btService.startScan,
              tooltip: 'Start Bluetooth Scan',
            ),
            Container(
              margin: const EdgeInsets.only(right: 8),
              child: IconButton(
                icon: Icon(
                  isAcquiring ? Icons.pause_circle : Icons.play_circle,
                ),
                onPressed: connectedDevice != null
                    ? (isAcquiring ? _stopAcquisition : _startAcquisition)
                    : null,
                tooltip: isAcquiring ? 'Stop ECG' : 'Start ECG',
                iconSize: 32,
              ),
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
            if (connectedDevice == null)
              FloatingActionButton(
                heroTag: 'connect',
                mini: true,
                onPressed: _showDeviceDialog,
                backgroundColor: Colors.blue.shade600,
                tooltip: 'Connect to ECG Device',
                child: const Icon(
                  Icons.bluetooth_searching,
                  color: Colors.white,
                ),
              ),
            if (connectedDevice != null) ...[
              const SizedBox(height: 8),
              FloatingActionButton(
                heroTag: 'main_action',
                onPressed: isAcquiring ? _stopAcquisition : _startAcquisition,
                backgroundColor: isAcquiring ? Colors.red : Colors.green,
                tooltip: isAcquiring
                    ? 'Stop ECG Recording'
                    : 'Start ECG Recording',
                child: Icon(
                  isAcquiring ? Icons.stop : Icons.play_arrow,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
