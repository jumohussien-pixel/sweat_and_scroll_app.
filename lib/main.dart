import 'dart:async';
import 'math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SweatAndScrollApp());
}

class SweatAndScrollApp extends StatelessWidget {
  const SweatAndScrollApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xff0d0e15),
        primaryColor: Colors.blueAccent,
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
  // القنوات الخاصة بالاتصال بنظام الأندروID (لقفل/فتح السوشيال ميديا)
  static const platform = MethodChannel('com.sweatandscroll.app/blocker');

  CameraController? _controller;
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(model: PoseDetectionModel.accurate),
  );

  int _pushUpCount = 0;
  bool _isDown = false;
  String _statusMessage = "ابدأ التمرين لفتح السوشيال ميديا!";
  Pose? _latestPose;
  Size? _imageSize;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _lockSocialMedia(); // قفل السوشيال ميديا فور تشغيل التطبيق
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _controller!.initialize();
    _controller!.startImageStream((image) {
      if (!_isProcessing) {
        _isProcessing = true;
        _processCameraImage(image);
      }
    });
    setState(() {});
  }

  Future<void> _processCameraImage(CameraImage image) async {
    try {
      final inputImage = _convertCameraImage(image);
      final poses = await _poseDetector.processImage(inputImage);

      if (poses.isNotEmpty) {
        _analyzePose(poses.first);
        setState(() {
          _latestPose = poses.first;
          _imageSize = Size(image.width.toDouble(), image.height.toDouble());
        });
      }
    } catch (e) {
      debugPrint("Error processing frame: $e");
    } finally {
      _isProcessing = false;
    }
  }

  void _analyzePose(Pose pose) {
    final shoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final elbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final wrist = pose.landmarks[PoseLandmarkType.leftWrist];

    if (shoulder != null && elbow != null && wrist != null) {
      double angle = _calculateAngle(shoulder, elbow, wrist);

      // منطق عد الضغط (Push-Up Logic)
      if (angle < 95 && !_isDown) {
        _isDown = true; // المستخدم نزل للأسفل
      }

      if (angle > 160 && _isDown) {
        _isDown = false; // المستخدم صعد للأعلى
        setState(() {
          _pushUpCount++;
          if (_pushUpCount >= 10) {
            _statusMessage = "عاش يا بطل! تم فتح السوشيال ميديا 🎉";
            _unlockSocialMedia(); // النشر والفتح (Push & Post)
          } else {
            _statusMessage = "فاضل لك ${10 - _pushUpCount} ضغطات!";
          }
        });
      }
    }
  }

  double _calculateAngle(PoseLandmark a, PoseLandmark b, PoseLandmark c) {
    double radians = math.atan2(c.y - b.y, c.x - b.x) - math.atan2(a.y - b.y, a.x - b.x);
    double angle = (radians * 180 / math.pi).abs();
    return angle > 180 ? 360 - angle : angle;
  }

  // دالة قفل التطبيقات (تتصل بـ Android Background Service)
  Future<void> _lockSocialMedia() async {
    try {
      await platform.invokeMethod('lockApps');
    } on PlatformException catch (e) {
      debugPrint("Failed to lock apps: ${e.message}");
    }
  }

  // دالة الفتح بعد النشر وإتمام التمرين
  Future<void> _unlockSocialMedia() async {
    try {
      await platform.invokeMethod('unlockApps');
    } on PlatformException catch (e) {
      debugPrint("Failed to unlock apps: ${e.message}");
    }
  }

  InputImage _convertCameraImage(CameraImage image) {
    return InputImage.fromBytes(
      bytes: image.planes[0].bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation270deg,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _poseDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. عرض الكاميرا في الخلفية
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(child: CameraPreview(_controller!))
          else
            const Center(child: CircularProgressIndicator(color: Colors.blueAccent)),

          // 2. رسم الهيكل العظمي بالنيون الأزرق
          if (_latestPose != null && _imageSize != null)
            Positioned.fill(
              child: CustomPaint(
                painter: NeonSkeletonPainter(_latestPose!, _imageSize!),
              ),
            ),

          // 3. واجهة المستخدم (UI) الاحترافية للبلاد ستور
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 24),
              decoration: BoxDecoration(
                color: const Color(0xdd12131a), // تأثير زجاجي داكن
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(30),
                  topRight: Radius.circular(30),
                ),
                border: Border.all(color: Colors.blueAccent.withOpacity(0.2)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("العداد:", style: TextStyle(fontSize: 22, color: Colors.grey)),
                      const SizedBox(width: 12),
                      Text(
                        "$_pushUpCount",
                        style: const TextStyle(fontSize: 50, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// رسام النيون الأزرق للمفاصل
class NeonSkeletonPainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;

  NeonSkeletonPainter(this.pose, this.imageSize);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff00f0ff) // نيون أزرق سيان توب
      ..strokeWidth = 5.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final blurPaint = Paint()
      ..color = const Color(0xff00f0ff).withOpacity(0.4)
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    void drawNeonLine(PoseLandmarkType startType, PoseLandmarkType endType) {
      final startLandmark = pose.landmarks[startType];
      final endLandmark = pose.landmarks[endType];

      if (startLandmark != null && endLandmark != null) {
        // تحجيم النقاط لتتناسب مع أبعاد الشاشة الحالية
        final scaleX = size.width / imageSize.width;
        final scaleY = size.height / imageSize.height;

        final start = Offset(startLandmark.x * scaleX, startLandmark.y * scaleY);
        final end = Offset(endLandmark.x * scaleX, endLandmark.y * scaleY);

        canvas.drawLine(start, end, blurPaint); // تأثير الوهج
        canvas.drawLine(start, end, paint);     // الخط الأساسي
      }
    }

    // رسم الذراع الأيسر (كتف -> كوع -> معصم)
    drawNeonLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
    drawNeonLine(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
  }

  @override
  bool shouldRepaint(covariant NeonSkeletonPainter oldDelegate) => true;
}