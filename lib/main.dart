import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Error loading cameras: $e");
  }
  runApp(const SweatAndScrollApp());
}

class SweatAndScrollApp extends StatelessWidget {
  const SweatAndScrollApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sweat & Scroll',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const WorkoutScreen(),
    );
  }
}

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key});

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  CameraController? controller;
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(
      model: PoseDetectionModel.base, // استخدام النموذج السريع للتخلص من التهنيج
      mode: PoseDetectionMode.stream,
    ),
  );

  bool _isDetecting = false;
  bool _isCameraInitialized = false;

  int squatsCount = 0;
  int pushUpsCount = 0;

  String _squatState = "up";
  String _pushUpState = "up";

  DateTime? _lastSquatTime;
  DateTime? _lastPushUpTime;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void dispose() {
    controller?.dispose();
    _poseDetector.close();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;

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
      debugPrint("Camera init error: $e");
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
        _detectSquat(poses.first);
        _detectPushUp(poses.first);
      }
    } catch (e) {
      debugPrint("Error detecting pose: $e");
    } finally {
      // السماح لمعالجة الفريم التالي بسرعة
      _isDetecting = false;
    }
  }

  // حساب الزاوية البسيطة والمباشرة
  double _calculateAngle(PoseLandmark p1, PoseLandmark p2, PoseLandmark p3) {
    double radians = math.atan2(p3.y - p2.y, p3.x - p2.x) -
        math.atan2(p1.y - p2.y, p1.x - p2.x);
    double angle = (radians * 180 / math.pi).abs();
    return angle > 180.0 ? 360.0 - angle : angle;
  }

  // 1. منطق السكوات المظبوط (الركبة)
  void _detectSquat(Pose pose) {
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final leftKnee = pose.landmarks[PoseLandmarkType.leftKnee];
    final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];

    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];
    final rightKnee = pose.landmarks[PoseLandmarkType.rightKnee];
    final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];

    PoseLandmark? hip, knee, ankle;

    if (leftKnee != null && (leftKnee.likelihood) > 0.5) {
      hip = leftHip; knee = leftKnee; ankle = leftAnkle;
    } else if (rightKnee != null && (rightKnee.likelihood) > 0.5) {
      hip = rightHip; knee = rightKnee; ankle = rightAnkle;
    }

    if (hip == null || knee == null || ankle == null) return;

    double angle = _calculateAngle(hip, knee, ankle);

    if (angle < 110.0) {
      _squatState = "down";
    } else if (angle > 150.0 && _squatState == "down") {
      final now = DateTime.now();
      if (_lastSquatTime == null || now.difference(_lastSquatTime!) > const Duration(milliseconds: 500)) {
        _lastSquatTime = now;
        _squatState = "up";
        setState(() => squatsCount++);
      }
    }
  }

  // 2. منطق الضغط المعدل بدقة عالية (الكوع والكتف)
  void _detectPushUp(Pose pose) {
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final leftElbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];

    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final rightElbow = pose.landmarks[PoseLandmarkType.rightElbow];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];

    PoseLandmark? shoulder, elbow, wrist;

    // اختيار الذراع الأكثر وضوحاً للكاميرا
    double leftScore = (leftElbow?.likelihood ?? 0);
    double rightScore = (rightElbow?.likelihood ?? 0);

    if (leftScore > 0.5 && leftScore >= rightScore) {
      shoulder = leftShoulder; elbow = leftElbow; wrist = leftWrist;
    } else if (rightScore > 0.5) {
      shoulder = rightShoulder; elbow = rightElbow; wrist = rightWrist;
    }

    if (shoulder == null || elbow == null || wrist == null) return;

    double angle = _calculateAngle(shoulder, elbow, wrist);

    // زاوية النزول للضغط تعدلت لـ 110 تسهيلاً للكاميرا
    if (angle < 110.0) {
      _pushUpState = "down";
    } else if (angle > 150.0 && _pushUpState == "down") {
      final now = DateTime.now();
      if (_lastPushUpTime == null || now.difference(_lastPushUpTime!) > const Duration(milliseconds: 500)) {
        _lastPushUpTime = now;
        _pushUpState = "up";
        setState(() => pushUpsCount++);
      }
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (controller == null) return null;
    final camera = controller!.description;

    final format = Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888;
    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }

    return InputImage.fromBytes(
      bytes: allBytes.done().buffer.asUint8List(),
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation0deg,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sweat & Scroll - Test Mode'), centerTitle: true),
      body: Column(
        children: [
          Expanded(
            child: _isCameraInitialized
                ? CameraPreview(controller!)
                : const Center(child: CircularProgressIndicator()),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            color: const Color(0xFF1E1E2C),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStat('سكوات', squatsCount, Colors.green),
                _buildStat('ضغط', pushUpsCount, Colors.orange),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildStat(String title, int count, Color color) {
    return Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 18, color: Colors.white70)),
        const SizedBox(height: 5),
        Text('$count', style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}