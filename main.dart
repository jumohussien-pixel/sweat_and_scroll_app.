// -----------------------------------------------------------------
// 1. استدعاء المكتبات والأدوات اللي هنستخدمها
// -----------------------------------------------------------------
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

// -----------------------------------------------------------------
// 2. متغير عالمي عشان نحفظ فيه كاميرات الموبايل
// -----------------------------------------------------------------
List<CameraDescription> cameras = [];

// -----------------------------------------------------------------
// 3. نقطة بداية تشغيل التطبيق (البوابة الرئيسية)
// -----------------------------------------------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Error: Could not get camera list: $e");
  }
  runApp(const SweatAndScrollApp());
}

// -----------------------------------------------------------------
// 4. تعريف المستويات لحساب النقاط
// -----------------------------------------------------------------
enum UserLevel { beginner, intermediate, advanced }

// -----------------------------------------------------------------
// 5. الويدجت الأساسية للتطبيق (الهيكل الخارجي)
// -----------------------------------------------------------------
class SweatAndScrollApp extends StatelessWidget {
  const SweatAndScrollApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sweat & Scroll',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF1E1E2C),
        fontFamily: 'Cairo',
        brightness: Brightness.dark,
      ),
      home: const MainScreen(),
    );
  }
}

// -----------------------------------------------------------------
// 6. الشاشة الرئيسية اللي فيها كل حاجة (StatefulWidget)
// -----------------------------------------------------------------
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // --- متغيرات الحالة ---
  CameraController? controller;
  final PoseDetector _poseDetector = PoseDetector(options: PoseDetectorOptions());

  int points = 0;
  UserLevel level = UserLevel.beginner;
  int squatsCount = 0;
  int pushUpsCount = 0; // عداد الضغط الجديد

  bool _isDetecting = false;
  bool _isCameraInitialized = false;

  bool _isInSquatPosition = false;
  bool _isInPushUpPosition = false; // مراقبة وضعية النزول في الضغط

  @override
  void initState() {
    super.initState();
    _loadData();
    _initializeCamera();
  }

  @override
  void dispose() {
    controller?.dispose();
    _poseDetector.close();
    super.dispose();
  }

  // -----------------------------------------------------------------
  // 7. دوال حفظ وتحميل البيانات
  // -----------------------------------------------------------------
  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      points = prefs.getInt('points') ?? 0;
      squatsCount = prefs.getInt('squatsCount') ?? 0;
      pushUpsCount = prefs.getInt('pushUpsCount') ?? 0; // تحميل عداد الضغط
      level = UserLevel.values[prefs.getInt('level') ?? 0];
    });
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('points', points);
    await prefs.setInt('squatsCount', squatsCount);
    await prefs.setInt('pushUpsCount', pushUpsCount); // حفظ عداد الضغط
    await prefs.setInt('level', level.index);
  }

  // -----------------------------------------------------------------
  // 8. دوال منطق التطبيق (الكاميرا والذكاء الاصطناعي)
  // -----------------------------------------------------------------
  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;

    final camera = cameras.length > 1 ? cameras[1] : cameras[0];

    controller = CameraController(
      camera,
      ResolutionPreset.low,
      enableAudio: false,
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
      debugPrint("Error initializing camera stream: $e");
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
        // تتبع الحركتين معاً في نفس الوقت
        _trackSquat(poses.first);
        _trackPushUp(poses.first);
      }
    } catch (e) {
      debugPrint("Error processing pose: $e");
    } finally {
      _isDetecting = false;
    }
  }

  // تتبع السكوات
  void _trackSquat(Pose pose) {
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final leftKnee = pose.landmarks[PoseLandmarkType.leftKnee];

    if (leftHip != null && leftKnee != null) {
      bool isCurrentlyDown = leftHip.y > leftKnee.y;

      if (isCurrentlyDown && !_isInSquatPosition) {
        setState(() => _isInSquatPosition = true);
      }
      else if (!isCurrentlyDown && _isInSquatPosition) {
        _onExerciseDetected(isSquat: true);
        setState(() => _isInSquatPosition = false);
      }
    }
  }

  // تتبع الضغط (الجديد)
  void _trackPushUp(Pose pose) {
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];

    if (leftShoulder != null && leftWrist != null) {
      // إذا تقارب الكتف من المعصم بشكل رأسي، يعني نزلنا للضغط
      double distance = (leftWrist.y - leftShoulder.y).abs();
      bool isCurrentlyDown = distance < 120; // المسافة التقريبية للنزول الكامل

      if (isCurrentlyDown && !_isInPushUpPosition) {
        setState(() => _isInPushUpPosition = true);
      }
      else if (!isCurrentlyDown && _isInPushUpPosition) {
        _onExerciseDetected(isSquat: false);
        setState(() => _isInPushUpPosition = false);
      }
    }
  }

  // دالة موحدة لزيادة العدات وحساب النقط
  void _onExerciseDetected({required bool isSquat}) {
    setState(() {
      if (isSquat) {
        squatsCount++;
      } else {
        pushUpsCount++;
      }

      int pointsToAdd = 0;
      switch (level) {
        case UserLevel.beginner: pointsToAdd = 10; break;
        case UserLevel.intermediate: pointsToAdd = 20; break;
        case UserLevel.advanced: pointsToAdd = 30; break;
      }
      points += pointsToAdd;
    });
    _saveData();
  }

  // -----------------------------------------------------------------
  // 9. بناء الواجهة النهائية
  // -----------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sweat & Scroll', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(color: const Color(0xFF4A00E0), width: 2)
                ),
                child: !_isCameraInitialized
                    ? const Center(child: CircularProgressIndicator())
                    : CameraPreview(controller!),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 40),
                    decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFF4A00E0), Color(0xFF8E2DE2)]),
                        borderRadius: BorderRadius.circular(25)),
                    child: Text('نقطة $points',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.bold)),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Text('السكوات: $squatsCount',
                          style: const TextStyle(
                              color: Color(0xFF00E676),
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                      Text('الضغط: $pushUpsCount', // عرض عداد الضغط في الواجهة
                          style: const TextStyle(
                              color: Color(0xFFFF1744),
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildLevelChip('مبتدئ', UserLevel.beginner),
                      const SizedBox(width: 10),
                      _buildLevelChip('متوسط', UserLevel.intermediate),
                      const SizedBox(width: 10),
                      _buildLevelChip('قوي', UserLevel.advanced),
                    ],
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildLevelChip(String label, UserLevel chipLevel) {
    return ChoiceChip(
      label: Text(label),
      selected: level == chipLevel,
      onSelected: (isSelected) {
        if (isSelected) {
          setState(() => level = chipLevel);
          _saveData();
        }
      },
      selectedColor: const Color(0xFF00E676),
      labelStyle: TextStyle(
          color: level == chipLevel ? Colors.black : Colors.white),
      backgroundColor: Colors.white24,
    );
  }

  // المترجم العالمي لتحويل صيغ الصور للـ AI
  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = controller!.description;
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation rotation;

    if (camera.lensDirection == CameraLensDirection.front) {
      rotation = InputImageRotation.rotation270deg;
    } else {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);

    if (format == InputImageFormat.yuv420 || format == InputImageFormat.yuv_420_888) {
      final allBytes = WriteBuffer();
      for (final plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } else if (format == InputImageFormat.bgra8888) {
      return InputImage.fromBytes(
        bytes: image.planes[0].bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.bgra8888,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } else {
      debugPrint('Image format not supported: ${image.format.group}');
      return null;
    }
  }
}