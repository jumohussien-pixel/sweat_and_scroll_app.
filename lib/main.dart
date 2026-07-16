// =================================================================
// 1. استدعاء المكتبات الأساسية للتطبيق
// =================================================================
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

// متغير لحفظ قائمة الكاميرات المتاحة في الموبايل
List<CameraDescription> cameras = [];

Future<void> main() async {
  // التأكد من تهيئة كل حاجة قبل تشغيل التطبيق
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("خطأ في تحميل الكاميرات: $e");
  }
  // تشغيل التطبيق
  runApp(const SweatAndScrollApp());
}

// تحديد مستويات الصعوبة
enum UserLevel { beginner, intermediate, advanced }

// =================================================================
// 2. إعدادات التطبيق الأساسية (الألوان والخطوط)
// =================================================================
class SweatAndScrollApp extends StatelessWidget {
  const SweatAndScrollApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sweat & Scroll',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF121212), // خلفية داكنة فخمة
        fontFamily: 'Cairo', // خط عربي مميز لو حبيت تضيفه
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF6C63FF), // لون نيون أزرق/بنفسجي
      ),
      home: const MainScreen(),
    );
  }
}

// =================================================================
// 3. الشاشة الرئيسية للتطبيق
// =================================================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  // قناة الاتصال مع كود الأندرويد اللي عملناه لقفل الشاشة
  static const platform = MethodChannel('com.example.sweat_and_scroll_app/overlay');

  // أدوات الكاميرا والذكاء الاصطناعي
  CameraController? controller;
  final PoseDetector _poseDetector = PoseDetector(options: PoseDetectorOptions());

  // الإحصائيات والأرقام
  int points = 0;
  UserLevel level = UserLevel.beginner;
  int squatsCount = 0;
  int pushUpsCount = 0;

  // حالات الكاميرا
  bool _isDetecting = false;
  bool _isCameraInitialized = false;

  // حالات التمارين (فوق أو تحت)
  String _squatState = "up";
  String _pushUpState = "up";

  // نظام الوقت
  int _allowedScrollTime = 30; // الوقت المبدئي 30 ثانية
  final int _maxScrollTime = 300; // أقصى وقت 5 دقائق عشان المستخدم ميدمنش
  Timer? _scrollTimer;
  bool _isAppBlocked = false;

  // تأثير بصري عند نجاح العدة
  bool _showSuccessFlash = false;

  // =================================================================
  // 4. دورة حياة التطبيق (بداية التشغيل والإغلاق)
  // =================================================================
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // مراقبة حالة التطبيق
    _loadData();
    _checkAndRequestPermissions();
    _initializeCamera();
    _startUsageLimitTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose(); // قفل الكاميرا لتوفير البطارية
    _poseDetector.close(); // قفل الـ AI
    _scrollTimer?.cancel(); // إيقاف العداد
    super.dispose();
  }

  // الدالة دي بتراقب لو طلعت بره التطبيق ورجعت
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // لو التطبيق رجع يشتغل وكان المفروض مقفول، اقفله تاني
      if (_isAppBlocked) {
        _forceCloseBackgroundApps();
      }
    }
  }

  // =================================================================
  // 5. أوامر الأندرويد (الصلاحيات والقفل)
  // =================================================================
  Future<void> _checkAndRequestPermissions() async {
    try {
      await platform.invokeMethod('requestPermissions');
    } on PlatformException catch (e) {
      _showErrorSnackBar("مشكلة في الصلاحيات: ${e.message}");
    }
  }

  // عداد الوقت اللي بيقل كل ثانية
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

  // أمر طرد المستخدم من التطبيقات التانية
  Future<void> _forceCloseBackgroundApps() async {
    try {
      await platform.invokeMethod('blockScreen');
    } catch (_) {}
  }

  // تزويد الوقت لما تعمل تمرين
  void _addBonusTime(int seconds) {
    setState(() {
      _allowedScrollTime = (_allowedScrollTime + seconds).clamp(0, _maxScrollTime);
      _isAppBlocked = false;
      _showSuccessFlash = true; // تشغيل الوميض الأخضر
    });

    // إخفاء الوميض بعد نص ثانية
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showSuccessFlash = false);
    });

    try {
      platform.invokeMethod('unblockScreen');
    } catch (_) {}
  }

  // رسالة تظهر للمستخدم لو حصل خطأ
  void _showErrorSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
      );
    }
  }

  // =================================================================
  // 6. حفظ البيانات في ذاكرة الموبايل (عشان متضيعش لو التطبيق اتقفل)
  // =================================================================
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

  // =================================================================
  // 7. تشغيل الكاميرا والذكاء الاصطناعي
  // =================================================================
  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      _showErrorSnackBar("لم يتم العثور على كاميرا في هذا الجهاز.");
      return;
    }
    // اختيار الكاميرا الأمامية
    final camera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras[0],
    );

    controller = CameraController(camera, ResolutionPreset.medium, enableAudio: false);

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

  // إرسال الصورة للذكاء الاصطناعي
  Future<void> _processImage(CameraImage image) async {
    final inputImage = _inputImageFromCameraImage(image);
    if (inputImage == null) {
      _isDetecting = false;
      return;
    }
    try {
      final poses = await _poseDetector.processImage(inputImage);
      if (poses.isNotEmpty) {
        // لو لقى شخص في الصورة، ابدأ احسب التمارين
        _trackSquatImproved(poses.first);
        _trackPushUpImproved(poses.first);
      }
    } catch (_) {}
    finally {
      _isDetecting = false;
    }
  }

  // =================================================================
  // 8. عبقرية الـ AI (حساب الزوايا بدقة تامة)
  // =================================================================
  double _calculateAngle(PoseLandmark first, PoseLandmark mid, PoseLandmark last) {
    double radians = math.atan2(last.y - mid.y, last.x - mid.x) -
                     math.atan2(first.y - mid.y, first.x - mid.x);
    double angle = (radians * 180 / math.pi).abs();
    return angle > 180.0 ? 360.0 - angle : angle;
  }

  void _trackSquatImproved(Pose pose) {
    final hip = pose.landmarks[PoseLandmarkType.leftHip];
    final knee = pose.landmarks[PoseLandmarkType.leftKnee];
    final ankle = pose.landmarks[PoseLandmarkType.leftAnkle];

    if (hip != null && knee != null && ankle != null) {
      double angle = _calculateAngle(hip, knee, ankle);
      // زاوية النزول
      if (angle < 100.0) {
        _squatState = "down";
      }
      // زاوية الطلوع والوقوف المفرود
      else if (angle > 160.0 && _squatState == "down") {
        _squatState = "up";
        _onExerciseDetected(isSquat: true);
        _addBonusTime(20); // مكافأة السكوات 20 ثانية
      }
    }
  }

  void _trackPushUpImproved(Pose pose) {
    final shoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final elbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final wrist = pose.landmarks[PoseLandmarkType.leftWrist];

    if (shoulder != null && elbow != null && wrist != null) {
      double angle = _calculateAngle(shoulder, elbow, wrist);
      if (angle < 90.0) {
        _pushUpState = "down";
      } else if (angle > 160.0 && _pushUpState == "down") {
        _pushUpState = "up";
        _onExerciseDetected(isSquat: false);
        _addBonusTime(30); // مكافأة الضغط 30 ثانية
      }
    }
  }

  void _onExerciseDetected({required bool isSquat}) {
    setState(() {
      if (isSquat) {
        squatsCount++;
      } else {
        pushUpsCount++;
      }
      // حساب النقاط حسب المستوى
      points += (level == UserLevel.beginner) ? 10 : (level == UserLevel.intermediate) ? 20 : 30;
    });
    _saveData();
  }

  // =================================================================
  // 9. تصميم الواجهة (UI) الخرافي
  // =================================================================
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
          // شريط الوقت المتبقي
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

          // شاشة الكاميرا مع تأثير النجاح
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

                  // الوميض الأخضر اللي بيظهر لما تعمل تمرينة صح
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

          // لوحة الإحصائيات والأزرار
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

                  // اختيار مستوى الصعوبة
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A3D),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
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

  // تصميم كروت الإحصائيات بشكل بارز ومجسم
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

  // تصميم أزرار المستويات
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

  // =================================================================
  // 10. محول الصور للذكاء الاصطناعي (أكواد معقدة متلعبش فيها)
  // =================================================================
  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = controller!.description;
    final rotation = camera.lensDirection == CameraLensDirection.front
        ? InputImageRotation.rotation270deg
        : InputImageRotationValue.fromRawValue(camera.sensorOrientation) ?? InputImageRotation.rotation0deg;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);

    if (format == InputImageFormat.yuv420 || format == InputImageFormat.yuv_420_888) {
      final allBytes = WriteBuffer();
      for (final plane in image.planes) { allBytes.putUint8List(plane.bytes); }
      return InputImage.fromBytes(
        bytes: allBytes.done().buffer.asUint8List(),
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
    }
    return null;
  }
}