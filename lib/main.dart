// ignore_for_file: curly_braces_in_flow_control_structures, empty_catches, deprecated_member_use, unnecessary_to_list_in_spreads
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';
import 'package:google_fonts/google_fonts.dart';

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

/// Enhanced Constants - FIXED ECG TIMING
const double samplingRate = 250.0; // Hz - confirmed for most ECG devices
const double timeWindowSeconds = 10.0; // Show 10 seconds of ECG data
final int samplesWindow = (samplingRate * timeWindowSeconds).round();

// Calibration constants - more accurate for medical ECG
const double defaultRawToMv =
    0.00488; // 4.88 µV per LSB (typical for 12-bit ADC)
const double ecgGainFactor = 1.0; // Remove the arbitrary *2 multiplication

// ECG paper standards - CORRECTED VALUES
const double mmPerSecond = 25.0; // 25 mm/s standard paper speed
const double mmPerMv = 10.0; // 10 mm per 1 mV standard
double pixelsPerMmDefault = 5.0; // INCREASED from 4.0 to reduce compression

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

    // Calculate augmented leads correctly - FIXED FORMULA
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

/// Enhanced Digital Filters - IMPROVED COEFFICIENTS
class HighPassFilter {
  final double alpha;
  double _y = 0.0;
  double _xPrev = 0.0;
  double _yPrev = 0.0;

  HighPassFilter(double cutoffHz, double sampleRateHz)
    : alpha = 1.0 / (1.0 + (2.0 * pi * cutoffHz) / sampleRateHz);

  double process(double x) {
    _y = alpha * (_yPrev + x - _xPrev);
    _xPrev = x;
    _yPrev = _y;
    return _y;
  }
}

class LowPassFilter {
  final double alpha;
  double _y = 0.0;

  LowPassFilter(double cutoffHz, double sampleRateHz)
    : alpha = (2 * pi * cutoffHz) / (sampleRateHz + 2 * pi * cutoffHz);

  double process(double x) {
    _y = alpha * x + (1 - alpha) * _y;
    return _y;
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

/// Enhanced Waveform Controller - FIXED TIMING AND DATA MANAGEMENT
class WaveformController {
  final Map<String, ECGFilterChain> filters = {};
  final Map<String, ListQueue<double>> leadBuffers = {};
  final Map<String, DateTime> lastSampleTimes = {};
  final ValueNotifier<int> tick = ValueNotifier<int>(0);

  double rawToMv = defaultRawToMv;
  int currentGain = 1;
  Timer? _uiTimer;

  // Statistics - IMPROVED TRACKING
  int _samplesProcessed = 0;
  DateTime? _firstSampleTime;
  double _actualSampleRate = 0.0;
  final List<DateTime> _recentSampleTimes = [];

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
        highPassCutoff: 0.05, // Lower cutoff to preserve ST segments
        lowPassCutoff: 100.0, // Higher cutoff for better signal fidelity
        notchFreq: 50.0, // Power line interference
      );
      leadBuffers[lead] = ListQueue<double>();
      lastSampleTimes[lead] = DateTime.now();
    }
  }

  void _startUITimer() {
    // REDUCED UI update frequency for better performance
    _uiTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
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

      // Convert to mV with proper calibration - IMPROVED CONVERSION
      final mvRaw = (rawValue * rawToMv) / max(1, currentGain);

      // Apply filtering
      final mvFiltered = filters[lead]!.process(mvRaw);

      // Validate filtered result - RELAXED VALIDATION
      if (mvFiltered.isFinite && mvFiltered.abs() < 50.0) {
        // Extended range ±50mV for abnormal ECG patterns
        leadBuffers[lead]!.add(mvFiltered);
        lastSampleTimes[lead] = DateTime.now();
      } else {
        // Add zero for invalid samples to maintain timing
        leadBuffers[lead]!.add(0.0);
      }

      // Maintain buffer size - FIXED WINDOW MANAGEMENT
      while (leadBuffers[lead]!.length > samplesWindow) {
        leadBuffers[lead]!.removeFirst();
      }
    }
  }

  void _updateSampleStatistics() {
    _samplesProcessed++;
    final now = DateTime.now();
    _recentSampleTimes.add(now);
    _firstSampleTime ??= now;

    // Keep only recent samples for rate calculation
    _recentSampleTimes.removeWhere(
      (time) => now.difference(time).inMilliseconds > 2000,
    );

    if (_recentSampleTimes.length > 10) {
      final duration = _recentSampleTimes.last
          .difference(_recentSampleTimes.first)
          .inMilliseconds;
      if (duration > 0) {
        _actualSampleRate =
            (_recentSampleTimes.length - 1) / (duration / 1000.0);
      }
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
    _recentSampleTimes.clear();
    tick.value++;
  }

  void dispose() {
    _uiTimer?.cancel();
    tick.dispose();
  }
}

/// Enhanced ECG Paper Painter - FIXED SCALING AND TIMING
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

    // CORRECTED SCALING - This fixes the horizontal compression
    final pixelsPerSecond = mmPerSecLocal * pmm;
    final pixelsPerSample = pixelsPerSecond / samplingRateLocal;
    final pixelsPerMv = mmPerMv * pmm;

    // Calculate the time window we want to show (in seconds)
    final timeWindowToShow = min(
      timeWindowSeconds,
      size.width / pixelsPerSecond,
    );
    final samplesToShow = (timeWindowToShow * samplingRateLocal).round();

    final path = Path();
    bool pathStarted = false;

    // Always start from the most recent samples for real-time display
    final startIndex = max(0, samples.length - samplesToShow);

    for (int i = startIndex; i < samples.length; i++) {
      final sampleIndex = i - startIndex;
      final mv = samples[i];

      // FIXED TIMING: Each sample is properly spaced based on sample rate
      final x = sampleIndex * pixelsPerSample;
      final y = centerY - (mv * pixelsPerMv);

      // Clamp to visible area with proper bounds checking
      if (x >= 0 && x <= size.width) {
        final clampedY = y.clamp(0.0, size.height);

        if (!pathStarted) {
          path.moveTo(x, clampedY);
          pathStarted = true;
        } else {
          path.lineTo(x, clampedY);
        }
      }
    }

    if (pathStarted) {
      canvas.drawPath(path, waveformPaint);
    }

    // Draw baseline reference
    final baselinePaint = Paint()
      ..color = Colors.red.withOpacity(0.3)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      baselinePaint,
    );

    // Draw amplitude markers
    _drawAmplitudeMarkers(canvas, size, centerY, pixelsPerMv);
  }

  void _drawAmplitudeMarkers(
    Canvas canvas,
    Size size,
    double centerY,
    double pixelsPerMv,
  ) {
    final markerPaint = Paint()
      ..color = Colors.grey.withOpacity(0.5)
      ..strokeWidth = 0.8;

    final textStyle = TextStyle(color: Colors.grey.shade600, fontSize: 10);

    // Draw 1mV and -1mV markers
    for (int mv in [-1, 1]) {
      final y = centerY - (mv * pixelsPerMv);
      if (y >= 0 && y <= size.height) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), markerPaint);

        final textPainter = TextPainter(
          text: TextSpan(text: '${mv}mV', style: textStyle),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(4, y - 8));
      }
    }
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
          fontSize: 16, // Increased font size
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
      ..strokeWidth = 2.5
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
        text: '1mV Cal',
        style: TextStyle(
          color: Colors.black87,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
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

/// ECG Chart Widget - IMPROVED PERFORMANCE
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
      // IMPROVED COMMAND SEQUENCE with proper timing
      await btService.write('S'); // Stop
      await Future.delayed(const Duration(milliseconds: 500));

      await btService.write('R'); // Reset
      await Future.delayed(const Duration(milliseconds: 500));

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
      await Future.delayed(const Duration(milliseconds: 500));

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
    const hrBpm = 72.0; // More realistic heart rate

    // IMPROVED MOCK DATA with more realistic ECG morphology
    _mockTimer = Timer.periodic(Duration(microseconds: (1e6 / fs).round()), (
      _,
    ) {
      // Generate realistic ECG-like signal
      final rrInterval = 60.0 / hrBpm;
      final phase = (t % rrInterval) / rrInterval;

      // Enhanced ECG morphology with proper P, QRS, T waves
      double ecgSignal = 0.0;

      // P wave (0.08-0.12s duration)
      if (phase >= 0.15 && phase <= 0.25) {
        final pPhase = (phase - 0.15) / 0.10;
        ecgSignal += 0.2 * sin(pi * pPhase) * exp(-pow(pPhase - 0.5, 2) / 0.1);
      }

      // QRS complex (0.06-0.10s duration)
      if (phase >= 0.35 && phase <= 0.45) {
        final qrsPhase = (phase - 0.35) / 0.10;
        // Q wave (negative deflection)
        if (qrsPhase <= 0.2) {
          ecgSignal += -0.15 * sin(5 * pi * qrsPhase);
        }
        // R wave (positive dominant deflection)
        else if (qrsPhase <= 0.6) {
          final rPhase = (qrsPhase - 0.2) / 0.4;
          ecgSignal +=
              1.2 * sin(pi * rPhase) * exp(-pow(rPhase - 0.5, 2) / 0.1);
        }
        // S wave (negative deflection)
        else {
          final sPhase = (qrsPhase - 0.6) / 0.4;
          ecgSignal += -0.25 * sin(pi * sPhase);
        }
      }

      // T wave (0.15-0.25s duration)
      if (phase >= 0.60 && phase <= 0.85) {
        final tPhase = (phase - 0.60) / 0.25;
        ecgSignal += 0.35 * sin(pi * tPhase) * exp(-pow(tPhase - 0.5, 2) / 0.2);
      }

      // Add realistic physiological variations
      ecgSignal += 0.02 * sin(2 * pi * 0.3 * t); // Respiratory modulation
      ecgSignal += 0.01 * sin(2 * pi * 0.1 * t); // Baseline wander
      ecgSignal += (rng.nextDouble() - 0.5) * 0.015; // Random noise

      // Generate lead-specific variations with proper scaling
      final leadVariations = {
        'I': ecgSignal * 0.8,
        'II': ecgSignal * 1.0, // Reference lead
        'III': ecgSignal * 0.6,
        'aVR': -ecgSignal * 0.5, // Inverted
        'aVL': ecgSignal * 0.4,
        'aVF': ecgSignal * 0.7,
        'V1':
            ecgSignal * 0.6 +
            0.1 * sin(2 * pi * 5 * t), // Slight high-frequency content
        'V2': ecgSignal * 0.9,
        'V3': ecgSignal * 1.2, // Higher amplitude in precordial leads
        'V4': ecgSignal * 1.4,
        'V5': ecgSignal * 1.1,
        'V6': ecgSignal * 0.95,
      };

      // Update buffers with mock data
      for (var entry in leadVariations.entries) {
        final queue = waveController.leadBuffers[entry.key]!;
        queue.add(entry.value);
        while (queue.length > samplesWindow) {
          queue.removeFirst();
        }
      }

      waveController.tick.value++;
      t += dt;
    });

    setState(() {
      useMock = true;
      statusMessage = 'Mock ECG data active (${hrBpm} BPM)';
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, Colors.grey.shade50],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.1),
            spreadRadius: 2,
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
        border: Border.all(color: Colors.grey.shade200, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with device connection status
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF2c3385).withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF2c3385).withOpacity(0.1),
                  width: 1,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      // Connection status icon
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: connectedDevice != null
                              ? Colors.green.withOpacity(0.1)
                              : Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          connectedDevice != null
                              ? Icons.bluetooth_connected_rounded
                              : Icons.bluetooth_searching_rounded,
                          color: connectedDevice != null
                              ? Colors.green.shade600
                              : Colors.orange.shade600,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),

                      // Device info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              connectedDevice != null
                                  ? 'Connected Device'
                                  : 'Searching for Device',
                              style: GoogleFonts.montserrat(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[600],
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              connectedDevice != null
                                  ? '${connectedDevice!.name ?? connectedDevice!.address}'
                                  : 'ECGREC-232401-177...',
                              style: GoogleFonts.montserrat(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: const Color(0xFF2c3385),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isAcquiring
                                    ? Colors.green.withOpacity(0.1)
                                    : Colors.grey.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                statusMessage,
                                style: GoogleFonts.montserrat(
                                  color: isAcquiring
                                      ? Colors.green.shade700
                                      : Colors.grey.shade600,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Device selection button
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF2c3385).withOpacity(0.2),
                              spreadRadius: 0,
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          onPressed: _showDeviceDialog,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2c3385),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.devices_rounded, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                connectedDevice != null
                                    ? 'Change Device'
                                    : 'Select Device',
                                style: GoogleFonts.montserrat(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Device stats section (show when connected)
            if (lastECGData != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.analytics_rounded,
                          color: const Color(0xFF2c3385),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Device Statistics',
                          style: GoogleFonts.montserrat(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF2c3385),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Stats grid
                    Row(
                      children: [
                        // Battery status
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.battery_full_rounded,
                                      color: Colors.green.shade600,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Battery',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  lastECGData!.batteryStatus,
                                  style: GoogleFonts.montserrat(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.green.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(width: 12),

                        // Sample rate
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.speed_rounded,
                                      color: Colors.blue.shade600,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Sample Rate',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${waveController.actualSampleRate.toStringAsFixed(1)} Hz',
                                  style: GoogleFonts.montserrat(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.blue.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Lead status
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.cable_rounded,
                            color: Colors.purple.shade600,
                            size: 16,
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Lead Connection Status',
                                style: GoogleFonts.montserrat(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey[600],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                lastECGData!.leadStatus,
                                style: GoogleFonts.montserrat(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.purple.shade700,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ],
                      ),
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

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, Colors.grey.shade50],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.1),
            spreadRadius: 2,
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
        border: Border.all(color: Colors.grey.shade200, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            // Settings Section
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF2c3385).withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF2c3385).withOpacity(0.1),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.settings,
                        color: const Color(0xFF2c3385),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'ECG Settings',
                        style: GoogleFonts.montserrat(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF2c3385),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      // Gain Section
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Gain Amplification',
                              style: GoogleFonts.montserrat(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[700],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: currentGain,
                                  isExpanded: true,
                                  icon: Icon(
                                    Icons.keyboard_arrow_down,
                                    color: const Color(0xFF2c3385),
                                  ),
                                  style: GoogleFonts.montserrat(
                                    color: const Color(0xFF2c3385),
                                    fontWeight: FontWeight.w600,
                                  ),
                                  items: [1, 2, 3, 4, 6, 8, 12]
                                      .map(
                                        (g) => DropdownMenuItem(
                                          value: g,
                                          child: Text('${g}x Gain'),
                                        ),
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
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      // Calibration Section
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Signal Calibration',
                              style: GoogleFonts.montserrat(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[700],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: Column(
                                children: [
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      activeTrackColor: const Color(0xFF2c3385),
                                      inactiveTrackColor: Colors.grey.shade300,
                                      thumbColor: const Color(0xFF2c3385),
                                      overlayColor: const Color(
                                        0xFF2c3385,
                                      ).withOpacity(0.2),
                                      trackHeight: 4,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 8,
                                      ),
                                    ),
                                    child: Slider(
                                      value: calibration,
                                      min: 0.001,
                                      max: 0.01,
                                      divisions: 100,
                                      onChanged: (v) {
                                        setState(() => calibration = v);
                                        waveController.setRawToMv(v);
                                      },
                                    ),
                                  ),
                                  Text(
                                    '${(calibration * 1000000).toStringAsFixed(1)}µV/count',
                                    style: GoogleFonts.montserrat(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: const Color(0xFF2c3385),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Control Buttons Section
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.control_camera,
                        color: const Color(0xFF2c3385),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Recording Controls',
                        style: GoogleFonts.montserrat(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF2c3385),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Action Buttons Row
                  Row(
                    children: [
                      Expanded(
                        child: _buildActionButton(
                          onPressed: isConnected && !isAcquiring
                              ? _startAcquisition
                              : null,
                          icon: Icons.play_arrow_rounded,
                          label: 'Start ECG',
                          color: Colors.green.shade600,
                          isEnabled: isConnected && !isAcquiring,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildActionButton(
                          onPressed: isAcquiring ? _stopAcquisition : null,
                          icon: Icons.stop_rounded,
                          label: 'Stop',
                          color: Colors.red.shade600,
                          isEnabled: isAcquiring,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildActionButton(
                          onPressed: isConnected ? _disconnect : null,
                          icon: Icons.bluetooth_disabled_rounded,
                          label: 'Disconnect',
                          color: Colors.orange.shade600,
                          isEnabled: isConnected,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildActionButton(
                          onPressed: waveController.clear,
                          icon: Icons.clear_all_rounded,
                          label: 'Clear',
                          color: Colors.grey.shade600,
                          isEnabled: true,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Mock Data Toggle
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.science_rounded,
                          color: useMock
                              ? const Color(0xFF2c3385)
                              : Colors.grey.shade500,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Mock Data Generator',
                                style: GoogleFonts.montserrat(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: useMock
                                      ? const Color(0xFF2c3385)
                                      : Colors.grey.shade700,
                                ),
                              ),
                              Text(
                                'Generate simulated ECG signals for testing',
                                style: GoogleFonts.montserrat(
                                  fontSize: 11,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Transform.scale(
                          scale: 0.9,
                          child: Switch(
                            value: useMock,
                            activeColor: const Color(0xFF2c3385),
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
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    required Color color,
    required bool isEnabled,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: isEnabled ? color : Colors.grey.shade300,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
          disabledForegroundColor: Colors.grey.shade500,
          elevation: isEnabled ? 2 : 0,
          shadowColor: color.withOpacity(0.3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.montserrat(
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
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
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          child: Column(
            children: [
              // Summary info
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.1),
                      spreadRadius: 1,
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.favorite,
                          color: Colors.red.shade600,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Heart Rate: ${_calculateHeartRate()}',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.analytics,
                          color: Colors.blue.shade600,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Samples: ${waveController.totalSamplesProcessed}',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: Colors.green.shade600,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Success Rate: ${(parser.packetSuccessRate * 100).toStringAsFixed(1)}%',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Lead groups
              ...leadGroups.asMap().entries.map((groupEntry) {
                final groupIndex = groupEntry.key;
                final leads = groupEntry.value;

                return Column(
                  children: [
                    if (groupIndex > 0) const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),

                      child: Text(
                        _getGroupName(groupIndex),
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: const Color(0xFF2c3385),
                        ),
                      ),
                    ),
                    ...leads.asMap().entries.map((leadEntry) {
                      final leadIndex = leadEntry.key;
                      final lead = leadEntry.value;
                      final colorIndex = groupIndex * 3 + leadIndex;
                      final samples = waveController.getSamples(lead);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: ECGChart(
                          leadName: lead,
                          samples: samples,
                          color: colors[colorIndex % colors.length],
                          height: 100,
                          showCalibration: groupIndex == 0 && leadIndex == 0,
                          pmm: pixelsPerMmDefault,
                        ),
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
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.1),
                spreadRadius: 1,
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            children: [
              // Lead selection and stats row
              Row(
                children: [
                  Icon(
                    Icons.show_chart,
                    color: const Color(0xFF2c3385),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Lead:',
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF2c3385),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedLead,
                        style: GoogleFonts.montserrat(
                          color: const Color(0xFF2c3385),
                          fontWeight: FontWeight.w600,
                        ),
                        items: allLeads
                            .map(
                              (l) => DropdownMenuItem(
                                value: l,
                                child: Text('Lead $l'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() {
                          if (v != null) selectedLead = v;
                        }),
                      ),
                    ),
                  ),
                  const Spacer(),
                  ValueListenableBuilder(
                    valueListenable: waveController.tick,
                    builder: (context, _, __) {
                      final samples = waveController.getSamples(selectedLead);
                      return Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.blue.withOpacity(0.2),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.analytics,
                                  color: Colors.blue.shade600,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Samples: ${samples.length}',
                                  style: GoogleFonts.montserrat(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            if (samples.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                'Range: ${samples.reduce(min).toStringAsFixed(2)} to ${samples.reduce(max).toStringAsFixed(2)} mV',
                                style: GoogleFonts.montserrat(
                                  fontSize: 10,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Technical parameters row
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.tune,
                          color: const Color(0xFF2c3385),
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Gain: ${currentGain}x',
                          style: GoogleFonts.montserrat(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.straighten,
                          color: const Color(0xFF2c3385),
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Calibration: ${(calibration * 1000000).toStringAsFixed(1)}µV/count',
                          style: GoogleFonts.montserrat(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.speed,
                          color: const Color(0xFF2c3385),
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Paper Speed: ${mmPerSecond}mm/s',
                          style: GoogleFonts.montserrat(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.aspect_ratio,
                          color: const Color(0xFF2c3385),
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Scale: ${pixelsPerMmDefault}px/mm',
                          style: GoogleFonts.montserrat(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.1),
                  spreadRadius: 1,
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
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
        ),
        const SizedBox(height: 16),
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
                        _buildStatRow(
                          'Display Settings',
                          'Scale: ${pixelsPerMmDefault}px/mm, Speed: ${mmPerSecond}mm/s',
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
                        'Lead Sample Counts & Recent Values',
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
                                leadName.length > 2
                                    ? leadName.substring(0, 2)
                                    : leadName,
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            label: Text(
                              '$leadName: $sampleCount${hasData ? " (${samples.last.toStringAsFixed(2)}mV)" : ""}',
                              style: const TextStyle(fontSize: 11),
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

              // Signal Quality Assessment
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Signal Quality Assessment',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildSignalQualityIndicators(),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Recent values visualization - IMPROVED
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

  Widget _buildSignalQualityIndicators() {
    final leadIISamples = waveController.getSamples('II');
    if (leadIISamples.isEmpty) {
      return const Text('No signal data available');
    }

    // Calculate signal quality metrics
    final amplitude = _calculateSignalAmplitude(leadIISamples);
    final noiseLevel = _calculateNoiseLevel(leadIISamples);
    final signalToNoise = amplitude > 0
        ? amplitude / max(noiseLevel, 0.001)
        : 0;
    final baselineDrift = _calculateBaselineDrift(leadIISamples);

    return Column(
      children: [
        _buildQualityIndicator(
          'Signal Amplitude',
          '${amplitude.toStringAsFixed(3)} mV',
          amplitude > 0.1 ? Colors.green : Colors.orange,
        ),
        _buildQualityIndicator(
          'Noise Level',
          '${noiseLevel.toStringAsFixed(3)} mV',
          noiseLevel < 0.05 ? Colors.green : Colors.red,
        ),
        _buildQualityIndicator(
          'Signal-to-Noise',
          '${signalToNoise.toStringAsFixed(1)}',
          signalToNoise > 10 ? Colors.green : Colors.orange,
        ),
        _buildQualityIndicator(
          'Baseline Drift',
          '${baselineDrift.toStringAsFixed(3)} mV',
          baselineDrift < 0.1 ? Colors.green : Colors.orange,
        ),
      ],
    );
  }

  Widget _buildQualityIndicator(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          ),
        ],
      ),
    );
  }

  double _calculateSignalAmplitude(List<double> samples) {
    if (samples.isEmpty) return 0.0;
    return samples.reduce(max) - samples.reduce(min);
  }

  double _calculateNoiseLevel(List<double> samples) {
    if (samples.length < 3) return 0.0;

    // Calculate high-frequency noise by examining sample-to-sample variations
    double totalVariation = 0.0;
    for (int i = 1; i < samples.length; i++) {
      totalVariation += (samples[i] - samples[i - 1]).abs();
    }
    return totalVariation / (samples.length - 1);
  }

  double _calculateBaselineDrift(List<double> samples) {
    if (samples.length < 100) return 0.0;

    // Calculate baseline drift by comparing means of first and last quarters
    final quarterSize = samples.length ~/ 4;
    final firstQuarter = samples.take(quarterSize).toList();
    final lastQuarter = samples.skip(samples.length - quarterSize).toList();

    final firstMean =
        firstQuarter.reduce((a, b) => a + b) / firstQuarter.length;
    final lastMean = lastQuarter.reduce((a, b) => a + b) / lastQuarter.length;

    return (lastMean - firstMean).abs();
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

    // IMPROVED R-wave detection with adaptive thresholding
    int peakCount = 0;
    double adaptiveThreshold = 0.3;
    bool wasAboveThreshold = false;
    int samplesAboveThreshold = 0;
    int lastPeakIndex = -1000; // Prevent double counting
    final minPeakDistance = (samplingRate * 0.3)
        .round(); // 300ms minimum between peaks

    // Calculate adaptive threshold based on signal statistics
    if (samples.isNotEmpty) {
      final maxVal = samples.reduce(max);
      final minVal = samples.reduce(min);
      final range = maxVal - minVal;

      if (range > 0.1) {
        // Only if we have significant signal
        adaptiveThreshold =
            minVal + (range * 0.6); // 60% of range above minimum
      }
    }

    for (int i = 1; i < samples.length; i++) {
      final current = samples[i];
      final previous = samples[i - 1];

      if (current > adaptiveThreshold) {
        samplesAboveThreshold++;
        if (!wasAboveThreshold &&
            previous <= adaptiveThreshold &&
            (i - lastPeakIndex) > minPeakDistance) {
          // Rising edge detected with minimum distance constraint
          peakCount++;
          lastPeakIndex = i;
        }
        wasAboveThreshold = true;
      } else {
        samplesAboveThreshold = 0;
        wasAboveThreshold = false;
      }
    }

    if (peakCount < 2) return 'Detecting...';

    final timeSpan = samples.length / samplingRate;
    final bpm = ((peakCount - 1) / timeSpan * 60).round().clamp(30, 250);

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

  // Add this header method to your ECG monitor class
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ECG Monitor',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
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
        ),
        floatingActionButton: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (connectedDevice == null)
              FloatingActionButton(
                heroTag: 'connect',
                mini: true,
                onPressed: _showDeviceDialog,
                backgroundColor: const Color(0xFF2c3385),
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

  // Add this header method to your ECG monitor class
  Widget _buildHeader() {
    const Color primaryBlue = Color(0xFF2c3385);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: BoxDecoration(
            color: primaryBlue.withOpacity(0.9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              // Main header section
              Container(
                height: 90,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.keyboard_backspace,
                        size: 30,
                        color: Colors.white,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ECG Monitor',
                            style: GoogleFonts.raleway(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Real-time cardiac monitoring & analysis',
                            style: GoogleFonts.raleway(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.devices),
                          onPressed: _showDeviceDialog,
                          tooltip: 'Device Selection',
                          color: Colors.white,
                          iconSize: 24,
                        ),
                        IconButton(
                          icon: const Icon(Icons.bluetooth_searching),
                          onPressed: btService.startScan,
                          tooltip: 'Start Bluetooth Scan',
                          color: Colors.white,
                          iconSize: 24,
                        ),
                        Container(
                          margin: const EdgeInsets.only(right: 4),
                          child: IconButton(
                            icon: Icon(
                              isAcquiring
                                  ? Icons.pause_circle
                                  : Icons.play_circle,
                              color: Colors.white,
                            ),
                            onPressed: connectedDevice != null
                                ? (isAcquiring
                                      ? _stopAcquisition
                                      : _startAcquisition)
                                : null,
                            tooltip: isAcquiring ? 'Stop ECG' : 'Start ECG',
                            iconSize: 32,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Tab bar section
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                  ),
                ),
                child: AnimatedBuilder(
                  animation: tabController,
                  builder: (context, child) {
                    return TabBar(
                      controller: tabController,
                      indicatorColor: Colors.white,
                      indicatorWeight: 3,
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white70,
                      labelStyle: GoogleFonts.montserrat(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                      unselectedLabelStyle: GoogleFonts.montserrat(
                        fontWeight: FontWeight.normal,
                        fontSize: 12,
                      ),
                      tabs: [
                        Tab(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeInOut,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.grid_view,
                                  size: 20,
                                  color: tabController.index == 0
                                      ? Colors.white
                                      : Colors.white70,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '12-Lead ECG',
                                  style: TextStyle(
                                    color: tabController.index == 0
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Tab(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeInOut,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.show_chart,
                                  size: 20,
                                  color: tabController.index == 1
                                      ? Colors.white
                                      : Colors.white70,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Single Lead',
                                  style: TextStyle(
                                    color: tabController.index == 1
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Tab(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeInOut,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.analytics,
                                  size: 20,
                                  color: tabController.index == 2
                                      ? Colors.white
                                      : Colors.white70,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Analysis',
                                  style: TextStyle(
                                    color: tabController.index == 2
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
