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

class AppColors {
  static const bg = Color(0xFF0F0F1A);
  static const surface = Color(0xFF1A1A2E);
  static const surfaceLight = Color(0xFF232340);
  static const primary = Color(0xFF6C63FF);
  static const primaryDark = Color(0xFF4B45B3);
  static const neon = Color(0xFF00F0FF);
  static const success = Color(0xFF00E676);
  static const danger = Color(0xFFFF1744);
  static const amber = Color(0xFFFFC107);
}

class SweatAndScrollApp extends StatelessWidget {
  const SweatAndScrollApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sweat & Scroll',
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.bg,
        fontFamily: 'Cairo',
        brightness: Brightness.dark,
        primaryColor: AppColors.primary,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.neon,
        ),
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

class _MainScreenState extends State<MainScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const platform =
      MethodChannel('com.example.sweat_and_scroll_app/overlay');

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
  PoseDetector? _poseDetector;

  int points = 0;
  UserLevel level = UserLevel.beginner;
  int squatsCount = 0;
  int pushUpsCount = 0;

  bool _isDetecting = false;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  String? _cameraError;

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

  // لرسم الهيكل النيوني فوق الكاميرا
  Pose? _latestPose;
  Size? _imageSize; // الأبعاد بعد مراعاة الـ rotation (وليس raw image)
  bool _isFrontCamera = true;

  late final AnimationController _pulseController;
  late final AnimationController _repController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _repController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      lowerBound: 0.9,
      upperBound: 1.15,
      value: 1.0,
    );

    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.accurate,
        mode: PoseDetectionMode.stream,
      ),
    );

    _loadData();
    _checkAndRequestPermissions();
    _initializeCamera();
    _startUsageLimitTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _repController.dispose();
    _stopStreamSafely();
    controller?.dispose();
    _poseDetector?.close();
    _scrollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = controller;
    if (cam == null || !cam.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // إيقاف الـ stream عند الخروج من التطبيق: يوفر بطارية ويمنع كراشات
      // الكاميرا الشائعة عند عودة التطبيق من الخلفية.
      _stopStreamSafely();
    } else if (state == AppLifecycleState.resumed) {
      if (_isAppBlocked) {
        _forceCloseBackgroundApps();
      }
      if (_isCameraInitialized && !_isStreaming) {
        _startStreamSafely();
      }
    }
  }

  Future<void> _checkAndRequestPermissions() async {
    try {
      await platform.invokeMethod('requestPermissions');
    } on PlatformException catch (e) {
      _showErrorSnackBar("مشكلة في الصلاحيات: ${e.message}");
    } on MissingPluginException {
      // القناة الأصلية (native) لسه مش مضافة على المنصة الحالية أثناء التطوير
      debugPrint("overlay channel غير متاح على هذه المنصة بعد.");
    }
  }

  void _startUsageLimitTimer() {
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
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
    } on PlatformException catch (e) {
      debugPrint("blockScreen فشلت: ${e.message}");
    } on MissingPluginException {
      debugPrint("blockScreen غير متاحة على هذه المنصة.");
    }
  }

  void _addBonusTime(int seconds) {
    if (!mounted) return;
    setState(() {
      _allowedScrollTime =
          (_allowedScrollTime + seconds).clamp(0, _maxScrollTime);
      _isAppBlocked = false;
      _showSuccessFlash = true;
    });

    HapticFeedback.mediumImpact();
    _repController.forward().then((_) {
      if (mounted) _repController.reverse();
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showSuccessFlash = false);
    });

    try {
      platform.invokeMethod('unblockScreen');
    } on MissingPluginException {
      // متاح فقط على المنصة الفعلية
    } catch (_) {}
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _loadData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        points = prefs.getInt('points') ?? 0;
        squatsCount = prefs.getInt('squatsCount') ?? 0;
        pushUpsCount = prefs.getInt('pushUpsCount') ?? 0;
        final savedLevel = prefs.getInt('level') ?? 0;
        level = UserLevel.values[savedLevel.clamp(0, UserLevel.values.length - 1)];
      });
    } catch (e) {
      debugPrint("فشل تحميل البيانات المحفوظة: $e");
    }
  }

  Future<void> _saveData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('points', points);
      await prefs.setInt('squatsCount', squatsCount);
      await prefs.setInt('pushUpsCount', pushUpsCount);
      await prefs.setInt('level', level.index);
    } catch (e) {
      debugPrint("فشل حفظ البيانات: $e");
    }
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      setState(() => _cameraError = "لم يتم العثور على كاميرا في هذا الجهاز.");
      return;
    }
    final camera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras[0],
    );
    _isFrontCamera = camera.lensDirection == CameraLensDirection.front;

    controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );

    try {
      await controller!.initialize();
      if (!mounted) return;
      await _startStreamSafely();
      setState(() {
        _isCameraInitialized = true;
        _cameraError = null;
      });
    } on CameraException catch (e) {
      setState(() => _cameraError = "تعذر تشغيل الكاميرا: ${e.description ?? e.code}");
    } catch (e) {
      setState(() => _cameraError = "حدث خطأ غير متوقع في تشغيل الكاميرا.");
    }
  }

  Future<void> _startStreamSafely() async {
    final cam = controller;
    if (cam == null || !cam.value.isInitialized || _isStreaming) return;
    try {
      await cam.startImageStream((image) {
        if (!_isDetecting) {
          _isDetecting = true;
          _processImage(image);
        }
      });
      _isStreaming = true;
    } catch (e) {
      debugPrint("فشل بدء بث الصور: $e");
    }
  }

  Future<void> _stopStreamSafely() async {
    final cam = controller;
    if (cam == null || !_isStreaming) return;
    try {
      if (cam.value.isStreamingImages) {
        await cam.stopImageStream();
      }
    } catch (e) {
      debugPrint("فشل إيقاف بث الصور: $e");
    } finally {
      _isStreaming = false;
    }
  }

  Future<void> _processImage(CameraImage image) async {
    final detector = _poseDetector;
    if (detector == null) {
      _isDetecting = false;
      return;
    }

    final result = _inputImageFromCameraImage(image);
    if (result == null) {
      _isDetecting = false;
      return;
    }

    try {
      final poses = await detector.processImage(result.inputImage);
      if (!mounted) return;
      if (poses.isNotEmpty) {
        _trackSquatImproved(poses.first);
        _trackPushUpImproved(poses.first);
        setState(() {
          _latestPose = poses.first;
          _imageSize = result.adjustedSize;
        });
      } else {
        // لا يوجد شخص واضح بالكاميرا: نمسح الرسم القديم بدل تجميده على آخر وضعية
        if (_latestPose != null) {
          setState(() => _latestPose = null);
        }
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
      points += (level == UserLevel.beginner)
          ? 10
          : (level == UserLevel.intermediate)
              ? 20
              : 30;
    });
    _saveData();
  }

  @override
  Widget build(BuildContext context) {
    double progress = _allowedScrollTime / _maxScrollTime;
    final isLow = _allowedScrollTime <= 10 && !_isAppBlocked;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bg, Color(0xFF15152A)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildTimeCard(progress, isLow),
              const SizedBox(height: 16),
              Expanded(flex: 5, child: _buildCameraArea()),
              const SizedBox(height: 16),
              Expanded(flex: 4, child: _buildStatsPanel()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [AppColors.neon, AppColors.primary],
            ).createShader(bounds),
            child: const Text(
              'SWEAT & SCROLL',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 22,
                letterSpacing: 1.5,
                color: Colors.white,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                const Icon(Icons.stars_rounded, color: AppColors.amber, size: 18),
                const SizedBox(width: 4),
                Text('$points',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeCard(double progress, bool isLow) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final glowStrength = (isLow || _isAppBlocked) ? _pulseController.value : 0.0;
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: (_isAppBlocked ? AppColors.danger : AppColors.primary)
                    .withOpacity(0.3 + glowStrength * 0.4),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: (_isAppBlocked ? AppColors.danger : AppColors.primary)
                      .withOpacity(0.15 + glowStrength * 0.15),
                  blurRadius: 20,
                  spreadRadius: 1,
                )
              ],
            ),
            child: child,
          );
        },
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _isAppBlocked ? Icons.lock_clock_rounded : Icons.timer_outlined,
                      color: _isAppBlocked ? AppColors.danger : AppColors.amber,
                      size: 26,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isAppBlocked ? 'الوقت خلص! مارس تمرين' : 'الرصيد المتاح',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
                Text(
                  '$_allowedScrollTime ث',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: _isAppBlocked ? AppColors.danger : Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 400),
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 12,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _isAppBlocked ? AppColors.danger : AppColors.success,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraArea() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ScaleTransition(
        scale: _repController,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.primary, width: 2.5),
                boxShadow: const [
                  BoxShadow(color: Color(0x4D6C63FF), blurRadius: 24, spreadRadius: 2)
                ],
              ),
              child: _buildCameraContent(),
            ),
            if (_showSuccessFlash) ...[
              Container(
                decoration: BoxDecoration(
                  color: AppColors.success.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              const Icon(Icons.check_circle_rounded,
                  color: AppColors.success, size: 90),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCameraContent() {
    if (_cameraError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 48),
              const SizedBox(height: 12),
              Text(_cameraError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () {
                  setState(() => _cameraError = null);
                  _initializeCamera();
                },
                icon: const Icon(Icons.refresh_rounded, color: AppColors.neon),
                label: const Text('إعادة المحاولة',
                    style: TextStyle(color: AppColors.neon)),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isCameraInitialized || controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    // نلف الكاميرا والرسم مع بعض في نفس الـ Transform حتى يفضلوا متزامنين
    // تماماً في حالة كانت الكاميرا الأمامية (mirrored)، بدل ما يتحسب كل واحد لوحده.
    return Transform(
      alignment: Alignment.center,
      transform: _isFrontCamera ? Matrix4.rotationY(math.pi) : Matrix4.identity(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(controller!),
          if (_latestPose != null && _imageSize != null)
            CustomPaint(
              painter: NeonSkeletonPainter(_latestPose!, _imageSize!),
            ),
        ],
      ),
    );
  }

  Widget _buildStatsPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(36),
          topRight: Radius.circular(36),
        ),
        boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 15, offset: Offset(0, -5))],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatCard('سكوات', squatsCount, AppColors.success,
                  Icons.accessibility_new_rounded),
              _buildStatCard('النقاط', points, AppColors.amber, Icons.stars_rounded,
                  isLarge: true),
              _buildStatCard('ضغط', pushUpsCount, AppColors.danger,
                  Icons.fitness_center_rounded),
            ],
          ),
          Column(
            children: [
              const Text('مستوى الصعوبة',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
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
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, int value, Color color, IconData icon,
      {bool isLarge = false}) {
    return Container(
      width: isLarge ? 120 : 100,
      padding: EdgeInsets.symmetric(vertical: isLarge ? 18 : 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.5), width: 2),
        boxShadow: [BoxShadow(color: color.withOpacity(0.15), blurRadius: 10, spreadRadius: 1)],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: isLarge ? 35 : 28),
          const SizedBox(height: 8),
          Text(title,
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: isLarge ? 16 : 14,
                  fontWeight: FontWeight.bold)),
          Text('$value',
              style: TextStyle(
                  color: color, fontSize: isLarge ? 28 : 24, fontWeight: FontWeight.w900)),
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
      selectedColor: AppColors.primary,
      backgroundColor: Colors.transparent,
      labelStyle: TextStyle(color: isSelected ? Colors.white : Colors.white60),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    );
  }

  /// يبني الـ InputImage للـ ML Kit، ويرجع معه أبعاد الصورة الصحيحة
  /// بعد مراعاة التدوير (rotation) عشان نستخدمها في الـ scaling الخاص بالرسام.
  _InputImageResult? _inputImageFromCameraImage(CameraImage image) {
    final cam = controller;
    if (cam == null) return null;
    final camera = cam.description;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[cam.value.deviceOrientation];
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

    final rawSize = Size(image.width.toDouble(), image.height.toDouble());

    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: rawSize,
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );

    // لما التدوير 90 أو 270 درجة، الصورة الفعلية (upright) بتكون العرض
    // والارتفاع معكوسين عن raw sensor size -- ده اللي بيخلي الهيكل يتشوه
    // لو استخدمنا image.width/height مباشرة بدون تعديل.
    final isRotated90or270 =
        rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final adjustedSize =
        isRotated90or270 ? Size(rawSize.height, rawSize.width) : rawSize;

    return _InputImageResult(inputImage: inputImage, adjustedSize: adjustedSize);
  }
}

class _InputImageResult {
  final InputImage inputImage;
  final Size adjustedSize;
  const _InputImageResult({required this.inputImage, required this.adjustedSize});
}

/// رسام الهيكل النيوني الأزرق فوق الكاميرا، مع Scaling ديناميكي
/// بناءً على حجم الصورة الفعلي (بعد مراعاة التدوير) لضمان عدم تشوه الخطوط.
class NeonSkeletonPainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;
  static const double _minLikelihoodToDraw = 0.5;

  NeonSkeletonPainter(this.pose, this.imageSize);

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width == 0 || imageSize.height == 0) return;

    final linePaint = Paint()
      ..color = const Color(0xff00f0ff)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final glowPaint = Paint()
      ..color = const Color(0xff00f0ff).withOpacity(0.3)
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final dotGlowPaint = Paint()
      ..color = const Color(0xff00f0ff).withOpacity(0.5)
      ..style = PaintingStyle.fill;

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    Offset? toOffset(PoseLandmarkType type) {
      final lm = pose.landmarks[type];
      if (lm == null || lm.likelihood < _minLikelihoodToDraw) return null;
      return Offset(lm.x * scaleX, lm.y * scaleY);
    }

    void drawNeonLine(PoseLandmarkType startType, PoseLandmarkType endType) {
      final start = toOffset(startType);
      final end = toOffset(endType);
      if (start == null || end == null) return;
      canvas.drawLine(start, end, glowPaint);
      canvas.drawLine(start, end, linePaint);
    }

    void drawJoint(PoseLandmarkType type) {
      final p = toOffset(type);
      if (p == null) return;
      canvas.drawCircle(p, 7, dotGlowPaint);
      canvas.drawCircle(p, 3, dotPaint);
    }

    // مفاصل الذراعين (للضغط)
    drawNeonLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
    drawNeonLine(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
    drawNeonLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
    drawNeonLine(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);

    // مفاصل الأرجل (للسكوات)
    drawNeonLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
    drawNeonLine(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
    drawNeonLine(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
    drawNeonLine(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);

    // خط الوسط يربط الجزء العلوي بالسفلي بصرياً
    drawNeonLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip);
    drawNeonLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip);

    for (final type in [
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.leftWrist,
      PoseLandmarkType.rightWrist,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.leftAnkle,
      PoseLandmarkType.rightAnkle,
    ]) {
      drawJoint(type);
    }
  }

  @override
  bool shouldRepaint(covariant NeonSkeletonPainter oldDelegate) {
    return oldDelegate.pose != pose || oldDelegate.imageSize != imageSize;
  }
}
