import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("خطأ في تحميل الكاميرات: $e");
  }
  runApp(const SweatAndScrollApp());
}

enum UserLevel { beginner, intermediate, advanced }

class SweatAndScrollApp extends StatelessWidget {
  const SweatAndScrollApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sweat & Scroll',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF121212),
        fontFamily: 'Cairo',
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF6C63FF),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const platform = MethodChannel('com.example.sweat_and_scroll_app/overlay');

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  static const double _minLikelihood = 0.6;
  static const Duration _repCooldown = Duration(milliseconds: 600);
  static const int _smoothingWindow = 3;

  CameraController? controller;
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(
      model: PoseDetectionModel.accurate,
      mode: PoseDetectionMode.stream,
    ),
  );

  int points = 0;
  UserLevel level = UserLevel.beginner;
  int squatsCount = 0;
  int pushUpsCount = 0;

  bool _isDetecting = false;
  bool _isCameraInitialized = false;

  String _squatState = "up";
  String _pushUpState = "up";
  DateTime? _lastSquatTime;
  DateTime? _lastPushUpTime;

  final List<double> _squatAngleBuffer = [];
  final List<double> _pushUpAngleBuffer = [];

  int _allowedScrollTime = 30;
  final int _maxScrollTime = 300;
  Timer? _scrollTimer;
  bool _isAppBlocked = false;
  bool _showSuccessFlash = false;

  // لإرسال الإحداثيات للرسام النيون
  Pose? _latestPose;
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    _checkAndRequestPermissions();
    _initializeCamera();
    _startUsageLimitTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    _poseDetector.close();
    _scrollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_isAppBlocked) {
        _forceCloseBackgroundApps();
      }
    }
  }

  Future<void> _checkAndRequestPermissions() async {
    try {
      await platform.invokeMethod('requestPermissions');
    } on PlatformException catch (e) {
      _showErrorSnackBar("مشكلة في الصلاحيات: ${e.message}");
    }
  }

  void _startUsageLimitTimer() {
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_allowedScrollTime > 0) {
        setState(() => _allowedScrollTime--);
      } else {
        if (!_isAppBlocked) {
          setState(() => _isAppBlocked = true);
          _forceCloseBackgroundApps();
        }
      }
    });
  }

  Future<void> _forceCloseBackgroundApps() async {
    try {
      await platform.invokeMethod('blockScreen');
    } catch (_) {}
  }

  void _addBonusTime(int seconds) {
    setState(() {
      _allowedScrollTime = (_allowedScrollTime + seconds).clamp(0, _maxScrollTime);
      _isAppBlocked = false;
      _showSuccessFlash = true;
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showSuccessFlash = false);
    });

    try {
      platform.invokeMethod('unblockScreen');
    } catch (_) {}
  }

  void _showErrorSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      points = prefs.getInt('points') ?? 0;
      squatsCount = prefs.getInt('squatsCount') ?? 0;
      pushUpsCount = prefs.getInt('pushUpsCount') ?? 0;
      level = UserLevel.values[prefs.getInt('level') ?? 0];
    });
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('points', points);
    await prefs.setInt('squatsCount', squatsCount);
    await prefs.setInt('pushUpsCount', pushUpsCount);
    await prefs.setInt('level', level.index);
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      _showErrorSnackBar("لم يتم العثور على كاميرا في هذا الجهاز.");
      return;
    }
    final camera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras[0],
    );

    controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );

    try {
      await controller!.initialize();
      await controller!.startImageStream((image) {
        if (!_isDetecting) {
          _isDetecting = true;
          _processImage(image);
        }
      });
      if (mounted) setState(() => _isCameraInitialized = true);
    } catch (e) {
      _showErrorSnackBar("حدث خطأ في تشغيل الكاميرا.");
    }
  }

  Future<void> _processImage(CameraImage image) async {
    final inputImage = _inputImageFromCameraImage(image);
    if (inputImage == null) {
      _isDetecting = false;
      return;
    }
    try {
      final poses = await _poseDetector.processImage(inputImage);
      if (poses.isNotEmpty) {
        _trackSquatImproved(poses.first);
        _trackPushUpImproved(poses.first);
        setState(() {
          _latestPose = poses.first;
          _imageSize = Size(image.width.toDouble(), image.height.toDouble());
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint("خطأ أثناء تحليل الإطار: $e");
    } finally {
      _isDetecting = false;
    }
  }

  double _calculateAngle(PoseLandmark first, PoseLandmark mid, PoseLandmark last) {
    double radians = math.atan2(last.y - mid.y, last.x - mid.x) -
        math.atan2(first.y - mid.y, first.x - mid.x);
    double angle = (radians * 180 / math.pi).abs();
    return angle > 180.0 ? 360.0 - angle : angle;
  }

  List<PoseLandmark>? _pickReliableSide(
    Pose pose,
    PoseLandmarkType leftA,
    PoseLandmarkType leftB,
    PoseLandmarkType leftC,
    PoseLandmarkType rightA,
    PoseLandmarkType rightB,
    PoseLandmarkType rightC,
  ) {
    final left = [pose.landmarks[leftA], pose.landmarks[leftB], pose.landmarks[leftC]];
    final right = [pose.landmarks[rightA], pose.landmarks[rightB], pose.landmarks[rightC]];

    double scoreOf(List<PoseLandmark?> pts) {
      if (pts.any((p) => p == null)) return -1;
      return pts.map((p) => p!.likelihood).reduce(math.min);
    }

    final leftScore = scoreOf(left);
    final rightScore = scoreOf(right);

    if (leftScore < _minLikelihood && rightScore < _minLikelihood) return null;

    final chosen = leftScore >= rightScore ? left : right;
    return [chosen[0]!, chosen[1]!, chosen[2]!];
  }

  double _smooth(List<double> buffer, double newValue) {
    buffer.add(newValue);
    if (buffer.length > _smoothingWindow) buffer.removeAt(0);
    return buffer.reduce((a, b) => a + b) / buffer.length;
  }

  void _trackSquatImproved(Pose pose) {
    final side = _pickReliableSide(
      pose,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.leftAnkle,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.rightAnkle,
    );
    if (side == null) return;

    final angle = _smooth(_squatAngleBuffer, _calculateAngle(side[0], side[1], side[2]));

    if (angle < 100.0) {
      _squatState = "down";
    } else if (angle > 160.0 && _squatState == "down") {
      final now = DateTime.now();
      final canCount = _lastSquatTime == null || now.difference(_lastSquatTime!) > _repCooldown;
      _squatState = "up";
      if (canCount) {
        _lastSquatTime = now;
        _onExerciseDetected(isSquat: true);
        _addBonusTime(20);
      }
    }
  }

  void _trackPushUpImproved(Pose pose) {
    final side = _pickReliableSide(
      pose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.leftWrist,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.rightWrist,
    );
    if (side == null) return;

    final angle = _smooth(_pushUpAngleBuffer, _calculateAngle(side[0], side[1], side[2]));

    if (angle < 90.0) {
      _pushUpState = "down";
    } else if (angle > 160.0 && _pushUpState == "down") {
      final now = DateTime.now();
      final canCount = _lastPushUpTime == null || now.difference(_lastPushUpTime!) > _repCooldown;
      _pushUpState = "up";
      if (canCount) {
        _lastPushUpTime = now;
        _onExerciseDetected(isSquat: false);
        _addBonusTime(30);
      }
    }
  }

  void _onExerciseDetected({required bool isSquat}) {
    if (!mounted) return;
    setState(() {
      if (isSquat) {
        squatsCount++;
      } else {
        pushUpsCount++;
      }
      points += (level == UserLevel.beginner) ? 10 : (level == UserLevel.intermediate) ? 20 : 30;
    });
    _saveData();
  }

  @override
  Widget build(BuildContext context) {
    double progress = _allowedScrollTime / _maxScrollTime;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SWEAT & SCROLL',
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, color: Colors.white)),
        backgroundColor: const Color(0xFF1E1E2C),
        elevation: 10,
        shadowColor: Colors.black54,
        centerTitle: true,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: Color(0xFF1E1E2C),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 5))],
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Icon(Icons.timer_outlined, color: Colors.amber, size: 30),
                    Text(
                      'الرصيد: $_allowedScrollTime ثانية',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: _isAppBlocked ? Colors.redAccent : Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 14,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _isAppBlocked ? Colors.redAccent : const Color(0xFF00E676)
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: double.infinity,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: const Color(0xFF6C63FF), width: 3),
                      boxShadow: const [
                        BoxShadow(color: Color(0x4D6C63FF), blurRadius: 20, spreadRadius: 3)
                      ]
                    ),
                    child: !_isCameraInitialized
                        ? const Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF)))
                        : CameraPreview(controller!),
                  ),

                  // رسم الهيكل النيوني الأزرق فوق الكاميرا بدقة
                  if (_latestPose != null && _imageSize != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: NeonSkeletonPainter(_latestPose!, _imageSize!),
                      ),
                    ),

                  if (_showSuccessFlash)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  if (_showSuccessFlash)
                    const Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 100),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
              decoration: const BoxDecoration(
                color: Color(0xFF1E1E2C),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(40),
                  topRight: Radius.circular(40),
                ),
                boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 15, offset: Offset(0, -5))],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildStatCard('سكوات', squatsCount, const Color(0xFF00E676), Icons.accessibility_new_rounded),
                      _buildStatCard('النقاط', points, Colors.amber, Icons.stars_rounded, isLarge: true),
                      _buildStatCard('ضغط', pushUpsCount, const Color(0xFFFF1744), Icons.fitness_center_rounded),
                    ],
                  ),

                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A3D),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisAlignment: Maincenter,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildLevelChip('مبتدئ', UserLevel.beginner),
                        const SizedBox(width: 5),
                        _buildLevelChip('متوسط', UserLevel.intermediate),
                        const SizedBox(width: 5),
                        _buildLevelChip('وحش', UserLevel.advanced),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, int value, Color color, IconData icon, {bool isLarge = false}) {
    return Container(
      width: isLarge ? 120 : 100,
      padding: EdgeInsets.symmetric(vertical: isLarge ? 18 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3D),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.5), width: 2),
        boxShadow: [
          BoxShadow(color: color.withOpacity(0.15), blurRadius: 10, spreadRadius: 1)
        ]
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: isLarge ? 35 : 28),
          const SizedBox(height: 8),
          Text(title, style: TextStyle(color: Colors.white70, fontSize: isLarge ? 16 : 14, fontWeight: FontWeight.bold)),
          Text('$value', style: TextStyle(color: color, fontSize: isLarge ? 28 : 24, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _buildLevelChip(String label, UserLevel chipLevel) {
    bool isSelected = level == chipLevel;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => level = chipLevel);
          _saveData();
        }
      },
      selectedColor: const Color(0xFF6C63FF),
      backgroundColor: Colors.transparent,
      labelStyle: TextStyle(color: isSelected ? Colors.white : Colors.white60),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    );
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (controller == null) return null;
    final camera = controller!.description;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[controller!.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (camera.sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (camera.sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    final format = Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888;

    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }
}

// رسام النيون الأزرق المدمج مع كود كلود
class NeonSkeletonPainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;

  NeonSkeletonPainter(this.pose, this.imageSize);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff00f0ff) // أزرق نيون مشع
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final glowPaint = Paint()
      ..color = const Color(0xff00f0ff).withOpacity(0.3) // تأثير توهج نيون
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    void drawNeonLine(PoseLandmarkType startType, PoseLandmarkType endType) {
      final startLandmark = pose.landmarks[startType];
      final endLandmark = pose.landmarks[endType];

      if (startLandmark != null && endLandmark != null) {
        // حساب الـ scale ديناميكياً بناءً على حجم الكاميرا الفعلي لعدم تشوه الخطوط
        final scaleX = size.width / imageSize.width;
        final scaleY = size.height / imageSize.height;

        final start = Offset(startLandmark.x * scaleX, startLandmark.y * scaleY);
        final end = Offset(endLandmark.x * scaleX, endLandmark.y * scaleY);

        canvas.drawLine(start, end, glowPaint);
        canvas.drawLine(start, end, paint);
      }
    }

    // رسم مفاصل الذراع الأيسر والأيمن لتمارين الضغط والسكوات
    drawNeonLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
    drawNeonLine(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
    drawNeonLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
    drawNeonLine(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);
    
    // رسم مفاصل الأرجل للسكوات
    drawNeonLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
    drawNeonLine(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
    drawNeonLine(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
    drawNeonLine(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);
  }

  @override
  bool shouldRepaint(covariant NeonSkeletonPainter oldDelegate) => true;
}
