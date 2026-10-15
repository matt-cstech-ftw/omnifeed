import 'dart:async';
import 'dart:convert';
import 'dart:js_interop' as js;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'tiktok_bridge.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

@js.JS('triggerPWAInstall')
external bool _triggerPWAInstallJs();

@js.JS('navigator.userAgent')
external String _getUserAgentJs();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const OmniFeedApp());
}

class StreamMessage {
  final String platform;
  final String user;
  final String text;
  final Color badgeBg;
  final String? host;
  final List<String> roles;
  final DateTime timestamp;

  StreamMessage({
    required this.platform,
    required this.user,
    required this.text,
    required this.badgeBg,
    this.host,
    this.roles = const [],
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Custom vector painter for crisp, zero-dependency platform logos (TikTok, Twitch, Kick, YouTube)
class _PlatformLogoPainter extends CustomPainter {
  final String platform;
  final Color color;

  const _PlatformLogoPainter({required this.platform, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    switch (platform) {
      case 'TT':
        final strokePaint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.17
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true;

        // Vertical stem + bottom left note loop
        final path = Path()
          ..moveTo(w * 0.60, h * 0.14)
          ..lineTo(w * 0.60, h * 0.66)
          ..arcToPoint(
            Offset(w * 0.24, h * 0.66),
            radius: Radius.circular(w * 0.18),
            clockwise: true,
          )
          ..arcToPoint(
            Offset(w * 0.46, h * 0.49),
            radius: Radius.circular(w * 0.18),
            clockwise: true,
          );

        // Top right flag curve
        final flagPath = Path()
          ..moveTo(w * 0.60, h * 0.14)
          ..quadraticBezierTo(w * 0.64, h * 0.36, w * 0.86, h * 0.38);

        canvas.drawPath(path, strokePaint);
        canvas.drawPath(flagPath, strokePaint);
        break;

      case 'TW':
        // Twitch speech-bubble glitch shape with two eyes punched out
        final outer = Path()
          ..moveTo(w * 0.22, h * 0.10)
          ..lineTo(w * 0.88, h * 0.10)
          ..lineTo(w * 0.88, h * 0.60)
          ..lineTo(w * 0.68, h * 0.78)
          ..lineTo(w * 0.50, h * 0.78)
          ..lineTo(w * 0.34, h * 0.94)
          ..lineTo(w * 0.34, h * 0.78)
          ..lineTo(w * 0.14, h * 0.78)
          ..lineTo(w * 0.14, h * 0.24)
          ..close();

        final eyes = Path()
          ..addRect(Rect.fromLTWH(w * 0.44, h * 0.28, w * 0.10, h * 0.26))
          ..addRect(Rect.fromLTWH(w * 0.64, h * 0.28, w * 0.10, h * 0.26));

        final combined = Path.combine(PathOperation.difference, outer, eyes);
        canvas.drawPath(combined, paint);
        break;

      case 'KC':
        // Kick blocky geometric 'K'
        final kPath = Path()
          // Left vertical bar
          ..addRect(Rect.fromLTWH(w * 0.16, h * 0.12, w * 0.24, h * 0.76))
          // Center connector block
          ..addRect(Rect.fromLTWH(w * 0.40, h * 0.38, w * 0.18, h * 0.24))
          // Top-right arm
          ..addRect(Rect.fromLTWH(w * 0.58, h * 0.12, w * 0.26, h * 0.26))
          // Bottom-right leg
          ..addRect(Rect.fromLTWH(w * 0.58, h * 0.62, w * 0.26, h * 0.26));
        canvas.drawPath(kPath, paint);
        break;

      case 'YT':
        // YouTube rounded screen with center play triangle punched out
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.08, h * 0.18, w * 0.84, h * 0.64),
          Radius.circular(w * 0.18),
        );
        final outer = Path()..addRRect(rrect);
        final play = Path()
          ..moveTo(w * 0.41, h * 0.33)
          ..lineTo(w * 0.67, h * 0.50)
          ..lineTo(w * 0.41, h * 0.67)
          ..close();
        final combined = Path.combine(PathOperation.difference, outer, play);
        canvas.drawPath(combined, paint);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _PlatformLogoPainter oldDelegate) {
    return oldDelegate.platform != platform || oldDelegate.color != color;
  }
}

class OmniFeedApp extends StatelessWidget {
  const OmniFeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniFeed HUD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF09090D),
        cardColor: const Color(0xFF12131A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFF06B5),
          surface: Color(0xFF12131A),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF14151E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF26293A), width: 1),
          ),
        ),
      ),
      home: const HudScreen(),
    );
  }
}

class HudScreen extends StatefulWidget {
  const HudScreen({super.key});

  @override
  State<HudScreen> createState() => _HudScreenState();
}

class _HudScreenState extends State<HudScreen> with TickerProviderStateMixin {
  // Pre-compiled Regular Expressions for hot network paths
  static final RegExp _twitchUserRegex = RegExp(r':(\w+)!');
  static final RegExp _ytMessageRegex = RegExp(
    r'"liveChatTextMessageRenderer":\{"message":\{"runs":\[\{"text":"(.*?)"\}\]\},"authorName":\{"simpleText":"(.*?)"\}',
  );

  // Core Theme Palette
  static const Color _bgDeep = Color(0xFF09090D);
  static const Color _surfaceCard = Color(0xFF12131A);
  static const Color _surfaceElevated = Color(0xFF181A24);
  static const Color _borderSubtle = Color(0xFF232634);
  static const Color _neonPink = Color(0xFFFF06B5);
  static const Color _cyanAccent = Color(0xFF00E5FF);
  static const Color _emeraldLive = Color(0xFF00E676);

  final Map<String, bool> _enabled = {
    'TT': true,
    'TW': false,
    'KC': false,
    'YT': false,
  };

  final Map<String, bool> _chatVisible = {
    'TT': true,
    'TW': true,
    'KC': true,
    'YT': true,
  };

  final Map<String, Color> _colors = {
    'TT': const Color(0xFF25F4EE),
    'TW': const Color(0xFF9146FF),
    'KC': const Color(0xFF53FC18),
    'YT': const Color(0xFFFF0033),
  };

  final Map<String, Color> _factoryColors = {
    'TT': const Color(0xFF25F4EE),
    'TW': const Color(0xFF9146FF),
    'KC': const Color(0xFF53FC18),
    'YT': const Color(0xFFFF0033),
  };

  final Map<String, Color> _hostColors = {};
  final List<Color> _hostPalette = const [
    Color(0xFF00E5FF),
    Color(0xFFFF4081),
    Color(0xFFFFD600),
    Color(0xFF7C4DFF),
    Color(0xFF00E676),
    Color(0xFFFF6E40),
    Color(0xFF40C4FF),
    Color(0xFFE040FB),
  ];

  double _chatFontSize = 12.0;
  Color _chatTextColor = const Color(0xFFEFF1F5);
  Color _chatUserColor = Colors.white;
  final Color _defaultChatTextColor = const Color(0xFFEFF1F5);
  final Color _defaultChatUserColor = Colors.white;

  // High-frequency data stores + granular ValueNotifiers to prevent full-screen rebuilds
  final List<StreamMessage> _chat = [];
  final List<StreamMessage> _events = [];
  final ValueNotifier<int> _chatVersion = ValueNotifier<int>(0);
  final ValueNotifier<int> _eventsVersion = ValueNotifier<int>(0);
  final ValueNotifier<int> _sessionSecondsNotifier = ValueNotifier<int>(0);
  final ValueNotifier<int> _velocityTickNotifier = ValueNotifier<int>(0);
  final ValueNotifier<String> _topSupporterNotifier = ValueNotifier<String>('No gifts yet');

  final List<String> _ttHosts = [];
  final Set<String> _promptedHosts = {};
  final Set<String> _ytSeenSignatures = {};
  final Map<String, int> _gifterScores = {};

  final Map<String, DateTime> _hostConnectedAt = {};
  final Map<String, List<DateTime>> _messageTimestamps = {};
  Timer? _velocityTimer;
  Timer? _stopwatchTimer;
  DateTime _lastChatScrollTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool _showVelocity = true;
  bool _showStopwatch = true;
  bool _showTopSupporter = true;

  late final AnimationController _hypeController;
  late final Animation<double> _hypeAnimation;

  final TextEditingController _ttPrimaryInput = TextEditingController();
  final TextEditingController _twInput = TextEditingController();
  final TextEditingController _kcInput = TextEditingController();
  final TextEditingController _ytInput = TextEditingController();

  final ScrollController _chatScrollController = ScrollController();
  final ScrollController _eventsScrollController = ScrollController();

  int _portraitTabIndex = 0;
  bool _isMenuExpanded = true;

  int _logoTapCount = 0;
  Timer? _logoTapTimer;

  final Map<String, TikTokLiveClient> _ttClientsMap = {};
  final Map<String, WebSocketChannel> _ttWebChannelsMap = {};
  WebSocketChannel? _twitchChannel;
  WebSocketChannel? _kickChannel;
  Timer? _ytTimer;
  bool _isConnected = false;
  String _statusText = 'Idle';

  @override
  void initState() {
    super.initState();
    _hypeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    )..repeat(reverse: true);

    _hypeAnimation = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _hypeController, curve: Curves.easeInOut),
    );

    _velocityTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_isConnected && mounted) {
        _pruneOldTimestamps();
        _velocityTickNotifier.value++;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAgreementStatus();
      _loadSavedHandles();
    });
  }

  @override
  void dispose() {
    _disconnectAll();
    _hypeController.dispose();
    _velocityTimer?.cancel();
    _stopwatchTimer?.cancel();
    _logoTapTimer?.cancel();
    _chatVersion.dispose();
    _eventsVersion.dispose();
    _sessionSecondsNotifier.dispose();
    _velocityTickNotifier.dispose();
    _topSupporterNotifier.dispose();
    _chatScrollController.dispose();
    _eventsScrollController.dispose();
    _ttPrimaryInput.dispose();
    _twInput.dispose();
    _kcInput.dispose();
    _ytInput.dispose();
    super.dispose();
  }

  void _markHostConnected(String key) {
    final clean = key.toLowerCase().replaceAll('@', '').trim();
    _hostConnectedAt[clean] = DateTime.now();
    _messageTimestamps[clean] = [];
    _velocityTickNotifier.value++;
  }

  bool _isHostCalibrating(String key) {
    final clean = key.toLowerCase().replaceAll('@', '').trim();
    final connectedTime = _hostConnectedAt[clean];
    if (connectedTime == null) return true;
    return DateTime.now().difference(connectedTime).inSeconds < 30;
  }

  void _recordMessageForVelocity(String key) {
    final clean = key.toLowerCase().replaceAll('@', '').trim();
    final now = DateTime.now();
    final connectedTime = _hostConnectedAt[clean];

    if (connectedTime != null && now.difference(connectedTime).inSeconds < 3) {
      return;
    }

    _messageTimestamps.putIfAbsent(clean, () => []).add(now);
  }

  void _pruneOldTimestamps() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    for (final list in _messageTimestamps.values) {
      list.removeWhere((t) => t.isBefore(cutoff));
    }
  }

  int _getVelocityFor(String key) {
    final clean = key.toLowerCase().replaceAll('@', '').trim();
    if (_isHostCalibrating(clean)) return 0;
    return _messageTimestamps[clean]?.length ?? 0;
  }

  int _getScaledVelocityStep(int countIn30s) {
    if (countIn30s <= 0) return 0;
    if (countIn30s >= 10) return 100;
    return countIn30s * 10;
  }

  String _formatDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _onLogoTapped() {
    _logoTapCount++;
    _logoTapTimer?.cancel();
    _logoTapTimer = Timer(const Duration(seconds: 2), () {
      _logoTapCount = 0;
    });

    if (_logoTapCount >= 5) {
      _logoTapCount = 0;
      _logoTapTimer?.cancel();
      _showAdminKeyPrompt();
    }
  }

  Color _getColorForHost(String? host) {
    if (host == null || host.isEmpty) return _cyanAccent;
    final key = host.toLowerCase().replaceAll('@', '').trim();
    return _hostColors.putIfAbsent(
      key,
      () => _hostPalette[_hostColors.length % _hostPalette.length],
    );
  }

  Future<void> _checkAgreementStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final agreed = prefs.getBool('omnifeed_agreement_accepted') ?? false;
    if (!agreed) {
      _showWelcomeAgreementModal();
    }
  }

  Future<void> _loadSavedHandles() async {
    final prefs = await SharedPreferences.getInstance();
    final tt = prefs.getString('saved_handle_tt') ?? '';
    final tw = prefs.getString('saved_handle_tw') ?? '';
    final kc = prefs.getString('saved_handle_kc') ?? '';
    final yt = prefs.getString('saved_handle_yt') ?? '';

    if (!mounted) return;
    setState(() {
      if (tt.isNotEmpty) _ttPrimaryInput.text = tt;
      if (tw.isNotEmpty) _twInput.text = tw;
      if (kc.isNotEmpty) _kcInput.text = kc;
      if (yt.isNotEmpty) _ytInput.text = yt;
    });
  }

  Future<void> _saveHandles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_handle_tt', _ttPrimaryInput.text.trim());
    await prefs.setString('saved_handle_tw', _twInput.text.trim());
    await prefs.setString('saved_handle_kc', _kcInput.text.trim());
    await prefs.setString('saved_handle_yt', _ytInput.text.trim());
  }

  Future<void> _launchOptOutUrl() async {
    final uri = Uri.parse('https://omnifeed-relay.onrender.com/optout');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _handleInstallButton() {
    bool launched = false;
    if (kIsWeb) {
      try {
        launched = _triggerPWAInstallJs();
      } catch (_) {}
    }

    if (!launched) {
      _showInstallInstructionsModal();
    }
  }

  // ---------------------------------------------------------------------------
  // MODALS & DIALOGS
  // ---------------------------------------------------------------------------

  void _showInstallInstructionsModal() {
    String ua = '';
    if (kIsWeb) {
      try {
        ua = _getUserAgentJs().toLowerCase();
      } catch (_) {}
    }

    final isIOS = ua.contains('iphone') || ua.contains('ipad') || ua.contains('ipod');
    final isAndroid = ua.contains('android');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: _buildModalTitle(Icons.install_mobile_rounded, 'Install OmniFeed App'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isIOS) ...[
                const Text('To install on iPhone / iPad (Safari):', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.white)),
                const SizedBox(height: 10),
                _buildStepRow('1', 'Tap the Share icon (square with upward arrow) at the bottom of Safari.'),
                const SizedBox(height: 8),
                _buildStepRow('2', 'Scroll down and tap "Add to Home Screen".'),
                const SizedBox(height: 8),
                _buildStepRow('3', 'Tap "Add" in the top right to launch OmniFeed in full-screen standalone mode.'),
              ] else if (isAndroid) ...[
                const Text('To install on Android (Chrome / Edge):', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.white)),
                const SizedBox(height: 10),
                _buildStepRow('1', 'Tap the three dots (⋮) in the top-right corner of your browser.'),
                const SizedBox(height: 8),
                _buildStepRow('2', 'Select "Install app" or "Add to Home screen".'),
                const SizedBox(height: 8),
                _buildStepRow('3', 'Confirm installation to add the app icon directly to your launcher.'),
              ] else ...[
                const Text('To install on Desktop (Chrome / Edge):', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.white)),
                const SizedBox(height: 10),
                _buildStepRow('1', 'Click the Install icon (monitor with down arrow) in the right side of the address bar.'),
                const SizedBox(height: 8),
                _buildStepRow('2', 'Click "Install" to run OmniFeed in a clean, dedicated telemetry window.'),
              ],
            ],
          ),
        ),
        actions: [
          _buildPrimaryDialogButton('Got It', () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  Widget _buildStepRow(String step, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _cyanAccent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _cyanAccent.withValues(alpha: 0.6), width: 1),
          ),
          child: Text(step, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _cyanAccent)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.4)),
        ),
      ],
    );
  }

  void _showStatsConfigModal() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setDState) => AlertDialog(
          title: _buildModalTitle(Icons.tune_rounded, 'Telemetry Modules'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                activeColor: _cyanAccent,
                title: const Text('Hype Meter Gauges', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: const Text('Real-time engagement bar per active host', style: TextStyle(fontSize: 11, color: Colors.white54)),
                value: _showVelocity,
                onChanged: (v) {
                  setState(() => _showVelocity = v);
                  setDState(() {});
                },
              ),
              const Divider(color: _borderSubtle),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                activeColor: _cyanAccent,
                title: const Text('Session Runtime Stopwatch', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: const Text('Tracks elapsed live stream uptime', style: TextStyle(fontSize: 11, color: Colors.white54)),
                value: _showStopwatch,
                onChanged: (v) {
                  setState(() => _showStopwatch = v);
                  setDState(() {});
                },
              ),
              const Divider(color: _borderSubtle),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                activeColor: _cyanAccent,
                title: const Text('Top Supporter Readout', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: const Text('Highlights session top diamond contributor', style: TextStyle(fontSize: 11, color: Colors.white54)),
                value: _showTopSupporter,
                onChanged: (v) {
                  setState(() => _showTopSupporter = v);
                  setDState(() {});
                },
              ),
            ],
          ),
          actions: [
            _buildPrimaryDialogButton('Done', () => Navigator.pop(ctx)),
          ],
        ),
      ),
    );
  }

  void _showWelcomeAgreementModal() {
    bool dontShowAgain = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setDState) => AlertDialog(
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _cyanAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _cyanAccent.withValues(alpha: 0.4)),
                ),
                child: const Icon(Icons.verified_user_rounded, color: _cyanAccent, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome to OmniFeed HUD',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Multi-Stream Aggregator • Community Edition',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'OmniFeed unites chats, co-hosts, battle participants, and gift events into a single, real-time second-screen cockpit.',
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: Colors.white),
                  ),
                  const SizedBox(height: 14),
                  _buildAgreementPoint(
                    icon: Icons.shield_outlined,
                    title: '1. Zero Data Collection & Privacy',
                    description: 'We do not collect, store, sell, or track personal data. OmniFeed never asks for or accesses your streaming account logins, passwords, or credentials. It operates solely by listening to public stream telemetry.',
                  ),
                  const SizedBox(height: 12),
                  _buildAgreementPoint(
                    icon: Icons.speed_rounded,
                    title: '2. Early-Stage Development & Resources',
                    description: 'OmniFeed runs on limited resources until development is further along. Safeguards are in place, but you may occasionally see brief capacity holds or minor latency during peak periods.',
                  ),
                  const SizedBox(height: 12),
                  _buildAgreementPoint(
                    icon: Icons.alt_route_rounded,
                    title: '3. Platform Independence & Creator Opt-Out',
                    description: 'OmniFeed acts strictly as an external viewer and listener. Streamers who prefer to exclude their channels from public aggregation can submit a global opt-out request anytime.',
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 28.0, top: 6.0),
                    child: _buildOptOutLinkButton(),
                  ),
                  const SizedBox(height: 12),
                  _buildAgreementPoint(
                    icon: Icons.handshake_outlined,
                    title: '4. Fair Usage & Community Powered',
                    description: 'Please do not run automated scrapers or spam relay connections. Tool development and server hosting rely directly on creator feedback and voluntary community support.',
                  ),
                  const Divider(height: 24, color: _borderSubtle),
                  InkWell(
                    onTap: () => setDState(() => dontShowAgain = !dontShowAgain),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: dontShowAgain,
                              activeColor: _cyanAccent,
                              checkColor: Colors.black,
                              onChanged: (v) => setDState(() => dontShowAgain = v ?? false),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            "Don't show this again",
                            style: TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            _buildPrimaryDialogButton('Agree & Continue', () async {
              if (dontShowAgain) {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('omnifeed_agreement_accepted', true);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildOptOutLinkButton() {
    return InkWell(
      onTap: _launchOptOutUrl,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _cyanAccent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _cyanAccent.withValues(alpha: 0.45), width: 1),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.open_in_new_rounded, size: 13, color: _cyanAccent),
            SizedBox(width: 6),
            Text(
              'Submit Creator Opt-Out Request',
              style: TextStyle(color: _cyanAccent, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgreementPoint({required IconData icon, required String title, required String description}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1.0),
          child: Icon(icon, color: _cyanAccent, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
              const SizedBox(height: 3),
              Text(description, style: const TextStyle(fontSize: 11.5, color: Colors.white70, height: 1.38)),
            ],
          ),
        ),
      ],
    );
  }

  void _showUpdatingModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: _buildModalTitle(Icons.sync_rounded, 'System Update in Progress'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OmniFeed is being updated, please wait a moment.',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
            ),
            SizedBox(height: 8),
            Text(
              'Our cloud relay is currently rebuilding with fresh optimizations. Service usually resumes automatically within 30 to 60 seconds.',
              style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.4),
            ),
          ],
        ),
        actions: [
          _buildPrimaryDialogButton('Okay', () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  void _showAtCapacityModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFFE2C55), width: 1.2),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFFE2C55), size: 24),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'OmniFeed is at capacity. Please try again shortly!',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: Colors.white, height: 1.25),
              ),
            ),
          ],
        ),
        content: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF24151C),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFFE2C55).withValues(alpha: 0.4), width: 1),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 2.0),
                child: Icon(Icons.favorite_rounded, color: Color(0xFFFE2C55), size: 16),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  "We're experiencing high demand! As an early-stage project, OmniFeed relies on community support to scale our infrastructure. Contributing financially directly supports server and development costs, but spreading the word is just as valuable in helping the tool grow.",
                  style: TextStyle(fontSize: 11.5, color: Colors.white70, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Dismiss', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFE2C55),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _showSupportModal();
            },
            icon: const Icon(Icons.favorite_rounded, size: 14),
            label: const Text('Support Development', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  void _showAdminKeyPrompt() {
    final entry = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: _buildModalTitle(Icons.admin_panel_settings_rounded, 'Relay Admin Gate'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter admin authorization key to inspect live relay telemetry:',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: entry,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Admin Key',
                isDense: true,
                filled: true,
                fillColor: _bgDeep,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          _buildPrimaryDialogButton('Authenticate', () async {
            final key = entry.text.trim();
            Navigator.pop(ctx);
            if (key == '#testcapacity') {
              _showAtCapacityModal();
              return;
            }
            if (key == '#testwelcome') {
              _showWelcomeAgreementModal();
              return;
            }
            if (key == '#testupdating') {
              _showUpdatingModal();
              return;
            }
            if (key.isNotEmpty) {
              await _fetchAndShowAdminStats(key);
            } else {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('ACCESS DENIED', style: TextStyle(fontWeight: FontWeight.bold)),
                  backgroundColor: Colors.redAccent,
                ),
              );
            }
          }),
        ],
      ),
    );
  }

  Future<void> _fetchAndShowAdminStats(String adminKey) async {
    final encoded = Uri.encodeComponent(adminKey);
    final uri = Uri.parse('https://omnifeed-relay.onrender.com/stats?token=$encoded');

    try {
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (!mounted) return;
        _displayAdminDashboard(data);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ACCESS DENIED', style: TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ACCESS DENIED', style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _displayAdminDashboard(Map<String, dynamic> data) {
    final clients = data['concurrent_ws_clients'] ?? 0;
    final streams = data['active_tiktok_streams'] ?? 0;
    final cached = data['cached_user_ids'] ?? 0;
    final memMb = data['memory_usage_mb'] ?? 0;
    final handles = (data['tracked_handles'] as List? ?? []);
    final blocked = (data['blocked_creators'] as List? ?? []);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: _buildModalTitle(Icons.analytics_outlined, 'Relay Live Telemetry'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatRow('Active Web Clients:', '$clients'),
                _buildStatRow('Active TikTok Streams:', '$streams'),
                _buildStatRow('Container RAM Usage:', '$memMb MB'),
                _buildStatRow('Cached User IDs:', '$cached'),
                _buildStatRow('Blocked Creators:', '${blocked.length}'),
                const Divider(height: 20, color: _borderSubtle),
                const Text('Active Host Streams:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 6),
                if (handles.isEmpty)
                  const Text('No active streams connected', style: TextStyle(fontSize: 11.5, color: Colors.white54))
                else
                  ...handles.map((h) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.5),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('@$h', style: const TextStyle(fontSize: 12, color: _cyanAccent, fontWeight: FontWeight.bold)),
                            const Text('Live Tracking', style: TextStyle(fontSize: 10.5, color: _emeraldLive)),
                          ],
                        ),
                      )),
              ],
            ),
          ),
        ),
        actions: [
          _buildPrimaryDialogButton('Close', () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _cyanAccent)),
        ],
      ),
    );
  }

  Future<void> _launchDonationUrl() async {
    final uri = Uri.parse('https://www.paypal.com/donate/?hosted_button_id=E5ZY9CWMAV9Z6');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showSupportModal() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Container(
          width: 380,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 28, spreadRadius: 4),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(
                  color: Color(0xFFF5F7FA),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                  border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
                ),
                child: Row(
                  children: [
                    const Row(
                      children: [
                        CircleAvatar(radius: 4.5, backgroundColor: Color(0xFFE2E8F0)),
                        SizedBox(width: 5),
                        CircleAvatar(radius: 4.5, backgroundColor: Color(0xFFE2E8F0)),
                        SizedBox(width: 5),
                        CircleAvatar(radius: 4.5, backgroundColor: Color(0xFFE2E8F0)),
                      ],
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () => Navigator.pop(ctx),
                      child: const Icon(Icons.close, color: Colors.grey, size: 18),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Donate to',
                      style: TextStyle(fontSize: 12, color: Color(0xFF6B7280), fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Matt | CS Tech Solutions',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Empower progress by supporting our online community tool development.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Color(0xFF4B5563), height: 1.35),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFC439),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _launchDonationUrl();
                        },
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            RichText(
                              text: const TextSpan(
                                children: [
                                  TextSpan(
                                    text: 'Pay',
                                    style: TextStyle(color: Color(0xFF003087), fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 16),
                                  ),
                                  TextSpan(
                                    text: 'Pal ',
                                    style: TextStyle(color: Color(0xFF0079C1), fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 16),
                                  ),
                                ],
                              ),
                            ),
                            const Text(
                              'Donate',
                              style: TextStyle(color: Color(0xFF111827), fontWeight: FontWeight.w700, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF008CFF),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _launchDonationUrl();
                        },
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'venmo ',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontStyle: FontStyle.italic,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              'Donate',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF003087), width: 1.4),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _launchDonationUrl();
                        },
                        child: const Text(
                          'Donate with Debit or Credit Card',
                          style: TextStyle(color: Color(0xFF003087), fontWeight: FontWeight.w700, fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: _buildModalTitle(Icons.menu_book_rounded, 'OmniFeed Manual'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHelpStep('1', 'Select Ingestion Feeds', 'Toggle platform pills (TikTok, Twitch, Kick, YouTube) to enable handle inputs.'),
                const SizedBox(height: 10),
                _buildHelpStep('2', 'Enter Handles / IDs', 'Input your creator usernames or YouTube Live Video IDs. Tap the color dot inside any input pill to customize its platform accent.'),
                const SizedBox(height: 10),
                _buildHelpStep('3', 'Manage Active Co-Hosts', 'Tap the +0 group badge inside the TikTok input pill to manually add co-hosts or customize individual host badge colors.'),
                const SizedBox(height: 10),
                _buildHelpStep('4', 'Automatic Co-Host / Battle Detection', 'When linked anchors join a TikTok box or battle, an instant prompt allows you to merge their live chat with one tap.'),
                const SizedBox(height: 10),
                _buildHelpStep('5', 'Customize Chat Appearance', 'Tap the Appearance button in the command drawer to scale font size across all panes and customize text/username colors.'),
                const SizedBox(height: 10),
                _buildHelpStep('6', 'Hype Meter & Live Competition', 'Monitors live audience engagement across all connected hosts alongside a session runtime stopwatch.'),
                const SizedBox(height: 10),
                _buildHelpStep('7', 'Creator Privacy & Global Opt-Out', 'OmniFeed listens solely to open public broadcast telemetry. Streamers who prefer to exclude their channels can submit a removal request anytime.'),
                Padding(
                  padding: const EdgeInsets.only(left: 32.0, top: 6.0),
                  child: _buildOptOutLinkButton(),
                ),
              ],
            ),
          ),
        ),
        actions: [
          _buildPrimaryDialogButton('Close', () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  Widget _buildHelpStep(String step, String title, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _cyanAccent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _cyanAccent.withValues(alpha: 0.6), width: 1),
          ),
          child: Text(
            step,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _cyanAccent),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
              const SizedBox(height: 2),
              Text(description, style: const TextStyle(fontSize: 11.5, color: Colors.white70, height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }

  void _showAboutOmniFeedModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: _buildModalTitle(Icons.hub_rounded, 'What is OmniFeed?'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'OmniFeed is a unified, real-time live stream telemetry HUD engineered for multi-platform creators and co-hosts.',
                  style: TextStyle(fontSize: 13, height: 1.4, color: Colors.white),
                ),
                const SizedBox(height: 14),
                _buildAgreementPoint(
                  icon: Icons.alt_route_rounded,
                  title: 'Multi-Platform Aggregation',
                  description: 'Combines chats, moderator badges, and viewer interactions from TikTok, Twitch, Kick, and YouTube into one unified stream.',
                ),
                const SizedBox(height: 10),
                _buildAgreementPoint(
                  icon: Icons.group_add_rounded,
                  title: 'TikTok Co-Host & Battle Detection',
                  description: 'Automatically detects rival anchors and co-hosts during TikTok Live sessions, allowing you to merge their live feeds with custom neon color coding.',
                ),
                const SizedBox(height: 10),
                _buildAgreementPoint(
                  icon: Icons.speed_rounded,
                  title: 'Hype Meter & Stopwatch',
                  description: 'Tracks live audience engagement per host to gamify chat interaction during co-host battles, paired with an automated session runtime stopwatch.',
                ),
                const SizedBox(height: 10),
                _buildAgreementPoint(
                  icon: Icons.devices_rounded,
                  title: 'Second-Screen PWA Cockpit',
                  description: 'Runs natively as an installable web app on phones, tablets, or secondary monitors without cluttering your primary broadcast scenes.',
                ),
                const SizedBox(height: 10),
                _buildAgreementPoint(
                  icon: Icons.privacy_tip_outlined,
                  title: 'Creator Opt-Out',
                  description: 'Streamers who prefer to exclude their channels from public aggregation can request global exclusion at any time.',
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 28.0, top: 6.0),
                  child: _buildOptOutLinkButton(),
                ),
                const Divider(height: 24, color: _borderSubtle),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E141D),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFE2C55).withValues(alpha: 0.35)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.favorite_rounded, color: Color(0xFFFE2C55), size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Enjoying OmniFeed? Tap the Support button in the command bar to support ongoing server & feature development!',
                          style: TextStyle(fontSize: 11.5, color: Colors.white70, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          _buildPrimaryDialogButton('Got It', () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  void _showChatAppearanceModal() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setDState) => AlertDialog(
          title: _buildModalTitle(Icons.format_size_rounded, 'HUD Typography & Colors'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Global HUD Text Scale:', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _cyanAccent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('${_chatFontSize.toInt()} pt', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _cyanAccent)),
                    ),
                  ],
                ),
                Slider(
                  value: _chatFontSize,
                  min: 9.0,
                  max: 22.0,
                  divisions: 13,
                  label: '${_chatFontSize.toInt()} pt',
                  activeColor: _cyanAccent,
                  onChanged: (v) {
                    setState(() => _chatFontSize = v);
                    setDState(() {});
                  },
                ),
                const Divider(height: 20, color: _borderSubtle),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Chat Message Color', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  trailing: InkWell(
                    onTap: () {
                      Color pick = _chatTextColor;
                      showDialog(
                        context: context,
                        builder: (subCtx) => AlertDialog(
                          title: const Text('Message Text Color', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          content: SingleChildScrollView(
                            child: ColorPicker(pickerColor: pick, onColorChanged: (cl) => pick = cl, enableAlpha: false),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {
                                setState(() => _chatTextColor = _defaultChatTextColor);
                                setDState(() {});
                                Navigator.pop(subCtx);
                              },
                              child: const Text('Default'),
                            ),
                            _buildPrimaryDialogButton('Apply', () {
                              setState(() => _chatTextColor = pick);
                              setDState(() {});
                              Navigator.pop(subCtx);
                            }),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: _chatTextColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white54, width: 1.5),
                      ),
                    ),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Username Color', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  trailing: InkWell(
                    onTap: () {
                      Color pick = _chatUserColor;
                      showDialog(
                        context: context,
                        builder: (subCtx) => AlertDialog(
                          title: const Text('Username Color', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          content: SingleChildScrollView(
                            child: ColorPicker(pickerColor: pick, onColorChanged: (cl) => pick = cl, enableAlpha: false),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {
                                setState(() => _chatUserColor = _defaultChatUserColor);
                                setDState(() {});
                                Navigator.pop(subCtx);
                              },
                              child: const Text('Default'),
                            ),
                            _buildPrimaryDialogButton('Apply', () {
                              setState(() => _chatUserColor = pick);
                              setDState(() {});
                              Navigator.pop(subCtx);
                            }),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: _chatUserColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white54, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            _buildPrimaryDialogButton('Done', () => Navigator.pop(ctx)),
          ],
        ),
      ),
    );
  }

  Widget _buildModalTitle(IconData icon, String title) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: _cyanAccent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _cyanAccent.withValues(alpha: 0.35)),
          ),
          child: Icon(icon, color: _cyanAccent, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 0.3),
          ),
        ),
      ],
    );
  }

  Widget _buildPrimaryDialogButton(String label, VoidCallback onPressed) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: _cyanAccent,
        foregroundColor: Colors.black,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }

  // ---------------------------------------------------------------------------
  // SCROLL & COLOR PICKER HELPERS
  // ---------------------------------------------------------------------------

  void _scrollToBottom(ScrollController controller, {bool isChat = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final pos = controller.position;
      if (pos.maxScrollExtent - pos.pixels > 140) return;

      final now = DateTime.now();
      if (isChat && now.difference(_lastChatScrollTime).inMilliseconds < 120) {
        controller.jumpTo(pos.maxScrollExtent);
      } else {
        if (isChat) _lastChatScrollTime = now;
        controller.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _openColorPicker(String platformKey) {
    Color pickerColor = _colors[platformKey]!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$platformKey Accent Color', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (c) => pickerColor = c,
            paletteType: PaletteType.hsvWithHue,
            enableAlpha: false,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _colors[platformKey] = _factoryColors[platformKey]!);
              Navigator.pop(ctx);
            },
            child: const Text('Reset Default'),
          ),
          _buildPrimaryDialogButton('Apply', () {
            setState(() => _colors[platformKey] = pickerColor);
            Navigator.pop(ctx);
          }),
        ],
      ),
    );
  }

  void _openHostColorPicker(String handle, VoidCallback onUpdate) {
    final clean = handle.toLowerCase().replaceAll('@', '').trim();
    Color pickerColor = _getColorForHost(clean);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('@$clean Badge Color', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (c) => pickerColor = c,
            paletteType: PaletteType.hsvWithHue,
            enableAlpha: false,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _hostColors.remove(clean));
              _chatVersion.value++;
              _velocityTickNotifier.value++;
              onUpdate();
              Navigator.pop(ctx);
            },
            child: const Text('Reset Default'),
          ),
          _buildPrimaryDialogButton('Apply', () {
            setState(() => _hostColors[clean] = pickerColor);
            _chatVersion.value++;
            _velocityTickNotifier.value++;
            onUpdate();
            Navigator.pop(ctx);
          }),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // STREAM INGESTION & RELAY LOGIC
  // ---------------------------------------------------------------------------

  void _toggleConnection() {
    FocusManager.instance.primaryFocus?.unfocus();

    if (_isConnected) {
      _disconnectAll();
      _stopwatchTimer?.cancel();
      _hostConnectedAt.clear();
      _messageTimestamps.clear();
      _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'All telemetry feeds disconnected', badgeBg: _cyanAccent));
      setState(() {
        _isConnected = false;
        _statusText = 'Disconnected';
      });
      _sessionSecondsNotifier.value = 0;
      _velocityTickNotifier.value++;
      return;
    }

    _saveHandles();

    setState(() {
      _isConnected = true;
      _statusText = 'Connected';
      _isMenuExpanded = false;
    });
    _sessionSecondsNotifier.value = 0;

    _stopwatchTimer?.cancel();
    _stopwatchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isConnected && mounted) {
        _sessionSecondsNotifier.value++;
      }
    });

    _connectStreams();
  }

  void _disconnectSingleHost(String handle) {
    final clean = handle.toLowerCase().replaceAll('@', '').trim();
    _hostConnectedAt.remove(clean);
    _messageTimestamps.remove(clean);
    if (kIsWeb) {
      final ch = _ttWebChannelsMap.remove(clean);
      try {
        ch?.sink.close();
      } catch (_) {}
    } else {
      final cl = _ttClientsMap.remove(clean);
      try {
        cl?.disconnect();
      } catch (_) {}
    }
    _velocityTickNotifier.value++;
  }

  void _disconnectAll() {
    for (final cl in _ttClientsMap.values) {
      try {
        cl.disconnect();
      } catch (_) {}
    }
    _ttClientsMap.clear();

    for (final ch in _ttWebChannelsMap.values) {
      try {
        ch.sink.close();
      } catch (_) {}
    }
    _ttWebChannelsMap.clear();
    _promptedHosts.clear();
    _ytSeenSignatures.clear();
    _hostConnectedAt.clear();
    _messageTimestamps.clear();

    try {
      _twitchChannel?.sink.close();
    } catch (_) {}
    _twitchChannel = null;

    try {
      _kickChannel?.sink.close();
    } catch (_) {}
    _kickChannel = null;

    _ytTimer?.cancel();
    _ytTimer = null;
  }

  void _showCoHostPrompt(String cohostHandle) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: _buildModalTitle(Icons.person_add_alt_1_rounded, 'Co-Host Detected'),
        content: Text(
          '@$cohostHandle is currently co-hosting or battling.\nWould you like to merge their live chat feed into your HUD?',
          style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Ignore', style: TextStyle(color: Colors.white54)),
          ),
          _buildPrimaryDialogButton('Merge Chat', () {
            Navigator.pop(ctx);
            _attachSingleTikTokHost(cohostHandle);
          }),
        ],
      ),
    );
  }

  void _attachSingleTikTokHost(String handle) {
    final cleanHandle = handle.replaceAll('@', '').trim();
    if (_ttHosts.contains(cleanHandle)) return;

    setState(() {
      _ttHosts.add(cleanHandle);
      _getColorForHost(cleanHandle);
    });

    _markHostConnected(cleanHandle);

    if (kIsWeb) {
      _connectTikTokWebRelay(cleanHandle);
      return;
    }

    runZonedGuarded(() async {
      final client = TikTokLiveClient(cleanHandle);
      _ttClientsMap[cleanHandle.toLowerCase()] = client;

      client.on(EventType.connected, (evt) {
        _markHostConnected(cleanHandle);
        _addEvent(StreamMessage(
          platform: 'SYS',
          user: 'System',
          text: 'Connected to co-host @$cleanHandle',
          badgeBg: _cyanAccent,
          host: cleanHandle,
        ));
      });

      client.on(EventType.chat, (evt) {
        final data = evt.data as Map<String, dynamic>?;
        final userMap = data?['user'] as Map<String, dynamic>?;
        final sender = userMap?['nickname']?.toString() ?? userMap?['uniqueId']?.toString() ?? 'TikTokUser';
        final comment = data?['content']?.toString() ?? '';
        final isMod = userMap?['isModerator'] == true;

        if (comment.isNotEmpty) {
          _recordMessageForVelocity(cleanHandle);
          _addChat(StreamMessage(
            platform: 'TT',
            user: sender,
            text: comment,
            badgeBg: _colors['TT']!,
            host: cleanHandle,
            roles: [if (isMod) 'MOD'],
          ));
        }
      });

      client.on(EventType.gift, (evt) {
        final data = evt.data as Map<String, dynamic>?;
        final userMap = data?['user'] as Map<String, dynamic>?;
        final sender = userMap?['nickname']?.toString() ?? userMap?['uniqueId']?.toString() ?? 'TikTokUser';
        final giftMap = data?['gift'] as Map<String, dynamic>?;
        final giftName = giftMap?['name']?.toString() ?? 'Gift';
        final count = int.tryParse(data?['repeatCount']?.toString() ?? '1') ?? 1;
        final diamondCount = int.tryParse(giftMap?['diamondCount']?.toString() ?? '1') ?? 1;

        _recordGift(sender, diamondCount * count);
        _addEvent(StreamMessage(
          platform: 'TT',
          user: sender,
          text: 'sent $count x $giftName',
          badgeBg: _getColorForHost(cleanHandle),
          host: cleanHandle,
        ));
      });

      await client.connect();
    }, (error, stack) {});
  }

  void _connectTikTokWebRelay(String handle) {
    final cleanHandle = handle.replaceAll('@', '').trim();
    final bridgeUri = Uri.parse('wss://omnifeed-relay.onrender.com/ws');

    _markHostConnected(cleanHandle);

    _addEvent(StreamMessage(
      platform: 'SYS',
      user: 'System',
      text: 'Connecting to Cloud Relay for @$cleanHandle...',
      badgeBg: _cyanAccent,
    ));

    try {
      final channel = WebSocketChannel.connect(bridgeUri);
      _ttWebChannelsMap[cleanHandle.toLowerCase()] = channel;

      channel.sink.add(jsonEncode({'action': 'connect', 'handle': cleanHandle}));

      channel.stream.listen((raw) {
        final data = jsonDecode(raw.toString());
        final event = data['event'];

        if (event == 'connected') {
          _markHostConnected(cleanHandle);
          _addEvent(StreamMessage(
            platform: 'SYS',
            user: 'System',
            text: 'Connected to TikTok @${data['handle']}',
            badgeBg: _cyanAccent,
            host: data['handle'],
          ));
        } else if (event == 'chat') {
          final hostKey = data['host']?.toString() ?? cleanHandle;
          _recordMessageForVelocity(hostKey);
          _addChat(StreamMessage(
            platform: 'TT',
            user: data['user'] ?? 'TikTokUser',
            text: data['comment'] ?? '',
            badgeBg: _colors['TT']!,
            host: data['host'],
            roles: [if (data['isMod'] == true) 'MOD'],
          ));
        } else if (event == 'gift') {
          final count = data['count'] ?? 1;
          final giftName = data['giftName'] ?? 'Gift';
          final diamonds = (data['diamondCount'] ?? 1) * count;
          final recipientHost = data['host']?.toString() ?? cleanHandle;
          _recordGift(data['user'] ?? 'TikTokUser', diamonds);
          _addEvent(StreamMessage(
            platform: 'TT',
            user: data['user'] ?? 'TikTokUser',
            text: 'sent $count x $giftName',
            badgeBg: _getColorForHost(recipientHost),
            host: data['host'],
          ));
        } else if (event == 'cohost_detected') {
          final cohost = data['handle']?.toString() ?? '';
          if (cohost.isNotEmpty &&
              !_ttHosts.map((h) => h.toLowerCase()).contains(cohost.toLowerCase()) &&
              !_promptedHosts.contains(cohost.toLowerCase())) {
            _promptedHosts.add(cohost.toLowerCase());
            if (mounted) {
              _showCoHostPrompt(cohost);
            }
          }
        } else if (event == 'error') {
          final code = data['code'];
          final msg = data['message']?.toString() ?? 'Relay Error';

          if (code == 403) {
            _disconnectSingleHost(cleanHandle);
            setState(() {
              _ttHosts.removeWhere((h) => h.toLowerCase() == cleanHandle.toLowerCase());
            });
            _addEvent(StreamMessage(
              platform: 'SYS',
              user: 'Blocked',
              text: msg,
              badgeBg: Colors.redAccent,
            ));

            final bool hasOtherTikTok = _ttWebChannelsMap.isNotEmpty || _ttClientsMap.isNotEmpty;
            final bool hasOtherFeeds = _twitchChannel != null || _kickChannel != null || _ytTimer != null;

            if (!hasOtherTikTok && !hasOtherFeeds) {
              _stopwatchTimer?.cancel();
              setState(() {
                _isConnected = false;
                _statusText = 'Opted Out';
              });
              _sessionSecondsNotifier.value = 0;
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(msg, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    backgroundColor: Colors.redAccent.shade700,
                    duration: const Duration(seconds: 5),
                  ),
                );
              }
            }
          } else if (code == 503 || msg.contains('capacity')) {
            _showAtCapacityModal();
            _addEvent(StreamMessage(
              platform: 'SYS',
              user: 'Error',
              text: 'TT: $msg',
              badgeBg: Colors.redAccent,
            ));
          } else {
            _showUpdatingModal();
            _addEvent(StreamMessage(
              platform: 'SYS',
              user: 'Error',
              text: 'TT: $msg',
              badgeBg: Colors.redAccent,
            ));
          }
        }
      }, onError: (err) {
        final errStr = err.toString();
        if (errStr.contains('503') || errStr.contains('capacity')) {
          _showAtCapacityModal();
        } else {
          _showUpdatingModal();
        }
        _addEvent(StreamMessage(
          platform: 'SYS',
          user: 'Error',
          text: 'Relay connection error: $err',
          badgeBg: Colors.redAccent,
        ));
      });
    } catch (e) {
      _showUpdatingModal();
      _addEvent(StreamMessage(
        platform: 'SYS',
        user: 'Error',
        text: 'Connection failed: $e',
        badgeBg: Colors.redAccent,
      ));
    }
  }

  void _connectStreams() {
    _disconnectAll();

    // 1. TikTok Ingestion
    if (_enabled['TT']!) {
      final prim = _ttPrimaryInput.text.trim().replaceAll('@', '');
      if (prim.isNotEmpty) {
        if (!_ttHosts.contains(prim)) {
          _ttHosts.insert(0, prim);
        } else {
          final idx = _ttHosts.indexOf(prim);
          if (idx != 0) {
            _ttHosts.removeAt(idx);
            _ttHosts.insert(0, prim);
          }
        }
        _getColorForHost(prim);
        _markHostConnected(prim);
      }

      if (kIsWeb) {
        for (final handle in _ttHosts) {
          _connectTikTokWebRelay(handle);
        }
      } else {
        for (final handle in _ttHosts) {
          _markHostConnected(handle);
          runZonedGuarded(() async {
            final client = TikTokLiveClient(handle);
            _ttClientsMap[handle.toLowerCase()] = client;

            _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Connecting to @$handle...', badgeBg: _cyanAccent));

            client.on(EventType.connected, (evt) {
              _markHostConnected(handle);
              _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Connected to @$handle', badgeBg: _cyanAccent, host: handle));
            });

            client.on(EventType.chat, (evt) {
              final data = evt.data as Map<String, dynamic>?;
              final userMap = data?['user'] as Map<String, dynamic>?;
              final sender = userMap?['nickname']?.toString() ?? userMap?['uniqueId']?.toString() ?? 'TikTokUser';
              final comment = data?['content']?.toString() ?? '';
              final isMod = userMap?['isModerator'] == true;

              if (comment.isNotEmpty) {
                _recordMessageForVelocity(handle);
                _addChat(StreamMessage(
                  platform: 'TT',
                  user: sender,
                  text: comment,
                  badgeBg: _colors['TT']!,
                  host: _ttHosts.length > 1 ? handle : null,
                  roles: [if (isMod) 'MOD'],
                ));
              }
            });

            client.on(EventType.gift, (evt) {
              final data = evt.data as Map<String, dynamic>?;
              final userMap = data?['user'] as Map<String, dynamic>?;
              final sender = userMap?['nickname']?.toString() ?? userMap?['uniqueId']?.toString() ?? 'TikTokUser';
              final giftMap = data?['gift'] as Map<String, dynamic>?;
              final giftName = giftMap?['name']?.toString() ?? 'Gift';
              final count = int.tryParse(data?['repeatCount']?.toString() ?? '1') ?? 1;
              final diamondCount = int.tryParse(giftMap?['diamondCount']?.toString() ?? '1') ?? 1;

              _recordGift(sender, diamondCount * count);
              _addEvent(StreamMessage(
                platform: 'TT',
                user: sender,
                text: 'sent $count x $giftName',
                badgeBg: _getColorForHost(handle),
                host: _ttHosts.length > 1 ? handle : null,
              ));
            });

            try {
              await client.connect();
            } catch (e) {
              _addEvent(StreamMessage(platform: 'SYS', user: 'Error', text: 'TT @$handle: $e', badgeBg: Colors.redAccent));
            }
          }, (error, stack) {
            if (!error.toString().contains('Software caused connection abort')) {
              _addEvent(StreamMessage(platform: 'SYS', user: 'Error', text: 'TT @$handle: $error', badgeBg: Colors.redAccent));
            }
          });
        }
      }
    }

    // 2. Twitch Ingestion
    if (_enabled['TW']!) {
      final user = _twInput.text.trim().toLowerCase();
      if (user.isNotEmpty) {
        _markHostConnected('Twitch');
        try {
          _twitchChannel = WebSocketChannel.connect(Uri.parse('wss://irc-ws.chat.twitch.tv:443'));
          _twitchChannel!.sink.add('CAP REQ :twitch.tv/tags twitch.tv/commands');
          _twitchChannel!.sink.add('PASS oauth:SCHMOOPIIE');
          _twitchChannel!.sink.add('NICK justinfan${10000 + DateTime.now().millisecond}');
          _twitchChannel!.sink.add('JOIN #$user');

          _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Connected to Twitch #$user', badgeBg: _cyanAccent));

          _twitchChannel!.stream.listen((raw) {
            final msg = raw.toString();
            if (msg.startsWith('PING')) {
              _twitchChannel!.sink.add('PONG :tmi.twitch.tv');
            } else if (msg.contains('PRIVMSG')) {
              final parts = msg.split(' :');
              if (parts.length >= 3) {
                final text = parts.sublist(2).join(' :').trim();
                final userMatch = _twitchUserRegex.firstMatch(msg);
                final sender = userMatch?.group(1) ?? 'TwitchUser';
                final isMod = msg.contains('mod=1') || msg.contains('badges=broadcaster');

                _recordMessageForVelocity('Twitch');
                _addChat(StreamMessage(
                  platform: 'TW',
                  user: sender,
                  text: text,
                  badgeBg: _colors['TW']!,
                  roles: [if (isMod) 'MOD'],
                ));
              }
            }
          }, onError: (_) {});
        } catch (_) {}
      }
    }

    // 3. Kick Ingestion
    if (_enabled['KC']!) {
      final kickSlug = _kcInput.text.trim().toLowerCase();
      if (kickSlug.isNotEmpty) {
        _markHostConnected('Kick');
        _connectKick(kickSlug);
      }
    }

    // 4. YouTube Ingestion
    if (_enabled['YT']!) {
      final ytId = _ytInput.text.trim();
      if (ytId.isNotEmpty) {
        _markHostConnected('YouTube');
        _startYTPolling(ytId);
      }
    }
  }

  Future<void> _connectKick(String slug) async {
    try {
      final res = await http.get(
        Uri.parse('https://kick.com/api/v2/channels/$slug'),
        headers: {'Accept': 'application/json', 'User-Agent': 'Mozilla/5.0'},
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final chatroomId = data['chatroom']?['id'];
        if (chatroomId == null) return;

        _kickChannel = WebSocketChannel.connect(
          Uri.parse('wss://ws-us2.pusher.com/app/eb1d5f28308142926088?protocol=7&client=js&version=7.6.0&flash=false'),
        );

        _kickChannel!.sink.add(jsonEncode({
          'event': 'pusher:subscribe',
          'data': {'auth': '', 'channel': 'chatrooms.$chatroomId.v2'}
        }));

        _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Connected to Kick #$slug', badgeBg: _cyanAccent));

        _kickChannel!.stream.listen((raw) {
          final packet = jsonDecode(raw.toString());
          if (packet['event'] == 'App\\Events\\ChatMessageEvent') {
            final chatData = jsonDecode(packet['data']);
            final sender = chatData['sender']?['username'] ?? 'KickUser';
            final text = chatData['content'] ?? '';

            _recordMessageForVelocity('Kick');
            _addChat(StreamMessage(
              platform: 'KC',
              user: sender,
              text: text,
              badgeBg: _colors['KC']!,
            ));
          }
        }, onError: (_) {});
      }
    } catch (_) {}
  }

  void _startYTPolling(String channelOrVideoId) {
    _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Polling YouTube Live stream', badgeBg: _cyanAccent));

    _ytTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      try {
        final cleanId = channelOrVideoId.replaceAll('https://www.youtube.com/watch?v=', '');
        final url = 'https://www.youtube.com/live_chat?v=$cleanId';
        final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'});
        if (res.statusCode == 200) {
          final body = res.body;
          final matches = _ytMessageRegex.allMatches(body);
          for (final m in matches) {
            final text = m.group(1) ?? '';
            final sender = m.group(2) ?? 'YTUser';
            final sig = '$sender:$text';
            if (_ytSeenSignatures.add(sig)) {
              if (_ytSeenSignatures.length > 500) {
                _ytSeenSignatures.remove(_ytSeenSignatures.first);
              }
              _recordMessageForVelocity('YouTube');
              _addChat(StreamMessage(
                platform: 'YT',
                user: sender,
                text: text,
                badgeBg: _colors['YT']!,
              ));
            }
          }
        }
      } catch (_) {}
    });
  }

  void _recordGift(String user, int value) {
    final nextScore = (_gifterScores[user] ?? 0) + value;
    _gifterScores[user] = nextScore;

    String topUser = user;
    int maxVal = nextScore;
    _gifterScores.forEach((k, v) {
      if (v > maxVal) {
        maxVal = v;
        topUser = k;
      }
    });
    _topSupporterNotifier.value = '$topUser ($maxVal 💎)';
  }

  void _addChat(StreamMessage msg) {
    _chat.add(msg);
    if (_chat.length > 300) {
      _chat.removeRange(0, 50);
    }
    _chatVersion.value++;
    _scrollToBottom(_chatScrollController, isChat: true);
  }

  void _addEvent(StreamMessage msg) {
    _events.add(msg);
    if (_events.length > 240) {
      _events.removeRange(0, 40);
    }
    _eventsVersion.value++;
    _scrollToBottom(_eventsScrollController);
  }

  void _openHostModal() {
    final entry = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        side: BorderSide(color: _borderSubtle, width: 1),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setMState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, MediaQuery.of(ctx).viewInsets.bottom + 16),
            child: SizedBox(
              height: 340,
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.group_add_rounded, color: _cyanAccent, size: 20),
                          SizedBox(width: 8),
                          Text('Manage TikTok Co-Hosts', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: entry,
                          style: const TextStyle(fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Add co-host @handle',
                            isDense: true,
                            filled: true,
                            fillColor: _bgDeep,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: _borderSubtle),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _cyanAccent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () {
                          final val = entry.text.trim().replaceAll('@', '');
                          if (val.isNotEmpty && !_ttHosts.contains(val)) {
                            setState(() {
                              _ttHosts.add(val);
                              _getColorForHost(val);
                            });
                            if (_isConnected) {
                              _attachSingleTikTokHost(val);
                            }
                            setMState(() {});
                            entry.clear();
                          }
                        },
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                      ),
                    ],
                  ),
                  const Divider(height: 20, color: _borderSubtle),
                  Expanded(
                    child: _ttHosts.isEmpty
                        ? const Center(
                            child: Text(
                              'No co-hosts added yet.\nAdd a handle above or wait for auto-detection.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: Colors.white38, height: 1.4),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _ttHosts.length,
                            itemBuilder: (c, idx) {
                              final hostHandle = _ttHosts[idx];
                              final hostColor = _getColorForHost(hostHandle);
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                decoration: BoxDecoration(
                                  color: _surfaceElevated,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: _borderSubtle),
                                ),
                                child: ListTile(
                                  dense: true,
                                  leading: InkWell(
                                    onTap: () {
                                      _openHostColorPicker(hostHandle, () {
                                        setMState(() {});
                                      });
                                    },
                                    child: Tooltip(
                                      message: 'Customize Host Badge Color',
                                      child: Container(
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          color: hostColor,
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.white70, width: 1.5),
                                          boxShadow: [
                                            BoxShadow(color: hostColor.withValues(alpha: 0.4), blurRadius: 6),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  title: Text('@$hostHandle', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                                  subtitle: Text(
                                    idx == 0 ? 'Primary Host • Tap circle to recolor' : 'Co-Host • Tap circle to recolor',
                                    style: const TextStyle(fontSize: 10.5, color: Colors.white54),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 19),
                                    onPressed: () {
                                      final removed = _ttHosts.removeAt(idx);
                                      _disconnectSingleHost(removed);
                                      setState(() {});
                                      setMState(() {});
                                    },
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
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TOP HEADER & COMMAND DRAWER WIDGETS
  // ---------------------------------------------------------------------------

  Widget _buildBrandLogo({bool isDesktop = false}) {
    return InkWell(
      onTap: _onLogoTapped,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 12 : 9, vertical: isDesktop ? 5 : 3.5),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B24),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF2E2E3D), width: 1),
        ),
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: 'OMNI',
                style: TextStyle(
                  fontFamily: 'Orbitron',
                  fontSize: isDesktop ? 18 : 15,
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              TextSpan(
                text: 'FEED',
                style: TextStyle(
                  fontFamily: 'Orbitron',
                  fontSize: isDesktop ? 22 : 19,
                  color: _cyanAccent,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstallAppButton({bool isDesktop = false}) {
    return InkWell(
      onTap: _handleInstallButton,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 12 : 9, vertical: isDesktop ? 6 : 5),
        decoration: BoxDecoration(
          color: _cyanAccent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _cyanAccent.withValues(alpha: 0.55), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.install_mobile_rounded, size: isDesktop ? 15 : 13.5, color: _cyanAccent),
            const SizedBox(width: 5),
            Text(
              'Install App',
              style: TextStyle(
                fontSize: isDesktop ? 11.5 : 10.5,
                color: _cyanAccent,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWhatIsOmniFeedBadge({bool isDesktop = false}) {
    return InkWell(
      onTap: _showAboutOmniFeedModal,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 11 : 9, vertical: isDesktop ? 6 : 5),
        decoration: BoxDecoration(
          color: _surfaceElevated,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: _borderSubtle, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline_rounded, size: isDesktop ? 14 : 13, color: _cyanAccent),
            const SizedBox(width: 5),
            Text(
              'What is OmniFeed?',
              style: TextStyle(fontSize: isDesktop ? 11.5 : 10.5, color: Colors.white70, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectButton({bool isDesktop = false}) {
    return InkWell(
      onTap: _toggleConnection,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: isDesktop ? 36 : 34,
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 16 : 13),
        decoration: BoxDecoration(
          color: _isConnected ? const Color(0xFF28121B) : _cyanAccent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _isConnected ? const Color(0xFFFE2C55) : _cyanAccent,
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: (_isConnected ? const Color(0xFFFE2C55) : _cyanAccent).withValues(alpha: 0.28),
              blurRadius: 10,
              spreadRadius: 0.5,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isConnected ? Icons.power_settings_new_rounded : Icons.bolt_rounded,
              size: isDesktop ? 15 : 14,
              color: _isConnected ? const Color(0xFFFE2C55) : Colors.black,
            ),
            const SizedBox(width: 5),
            Text(
              _isConnected ? 'DISCONNECT' : 'CONNECT',
              style: TextStyle(
                fontSize: isDesktop ? 11.5 : 10.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.6,
                color: _isConnected ? const Color(0xFFFE2C55) : Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPersistentTopBar({required bool isDesktop}) {
    return Container(
      height: isDesktop ? 50 : 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0E0F16),
        border: Border(bottom: BorderSide(color: _borderSubtle, width: 1)),
      ),
      child: Row(
        children: [
          _buildBrandLogo(isDesktop: isDesktop),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
            decoration: BoxDecoration(
              color: _isConnected ? _emeraldLive.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _isConnected ? _emeraldLive.withValues(alpha: 0.5) : Colors.white12,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6.5,
                  height: 6.5,
                  decoration: BoxDecoration(
                    color: _isConnected ? _emeraldLive : Colors.white38,
                    shape: BoxShape.circle,
                    boxShadow: [
                      if (_isConnected) BoxShadow(color: _emeraldLive.withValues(alpha: 0.6), blurRadius: 6),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _isConnected ? 'LIVE' : 'STANDBY',
                  style: TextStyle(
                    fontSize: isDesktop ? 10 : 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                    color: _isConnected ? _emeraldLive : Colors.white54,
                  ),
                ),
              ],
            ),
          ),
          if (_isConnected && _showStopwatch) ...[
            const SizedBox(width: 8),
            ValueListenableBuilder<int>(
              valueListenable: _sessionSecondsNotifier,
              builder: (_, secs, _) => Text(
                _formatDuration(secs),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: isDesktop ? 12 : 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (!_isMenuExpanded) ...[
            _buildConnectButton(isDesktop: false),
            const SizedBox(width: 8),
          ],
          _buildInstallAppButton(isDesktop: isDesktop),
        ],
      ),
    );
  }

  Widget _buildBottomToggleBar({required bool isDesktop}) {
    return InkWell(
      onTap: () => setState(() => _isMenuExpanded = !_isMenuExpanded),
      child: Container(
        height: isDesktop ? 24 : 22,
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Color(0xFF101119),
          border: Border(
            bottom: BorderSide(color: _borderSubtle, width: 1),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: _surfaceElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _borderSubtle, width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _isMenuExpanded ? 'HIDE CONTROLS' : 'CONFIGURE STREAMS',
                    style: const TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _isMenuExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: _cyanAccent,
                    size: 14,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandDrawer({required bool isDesktop}) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: !_isMenuExpanded
          ? const SizedBox.shrink()
          : Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: _surfaceCard,
                border: Border(bottom: BorderSide(color: Color(0xFF282B3D), width: 1)),
              ),
              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 14 : 10, vertical: isDesktop ? 10 : 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Row 1: Platform Toggles + Inputs + Compact Connect CTA
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: _bgDeep,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: _borderSubtle),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTogglePill('TT', 'TikTok', isDesktop: isDesktop),
                            const SizedBox(width: 4),
                            _buildTogglePill('TW', 'Twitch', isDesktop: isDesktop),
                            const SizedBox(width: 4),
                            _buildTogglePill('KC', 'Kick', isDesktop: isDesktop),
                            const SizedBox(width: 4),
                            _buildTogglePill('YT', 'YouTube', isDesktop: isDesktop),
                          ],
                        ),
                      ),
                      ..._buildInputsOnlyList(isDesktop: isDesktop),
                      _buildConnectButton(isDesktop: isDesktop),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: _borderSubtle),
                  const SizedBox(height: 6),
                  // Row 2: Utility Toolbar
                  Row(
                    children: [
                      _buildToolbarIconBtn(
                        icon: Icons.favorite_rounded,
                        color: const Color(0xFFFE2C55),
                        label: isDesktop ? 'Support' : null,
                        tooltip: 'Support OmniFeed',
                        onTap: _showSupportModal,
                      ),
                      const SizedBox(width: 6),
                      _buildToolbarIconBtn(
                        icon: Icons.format_size_rounded,
                        color: _cyanAccent,
                        label: isDesktop ? 'Appearance' : null,
                        tooltip: 'Chat Typography & Colors',
                        onTap: _showChatAppearanceModal,
                      ),
                      const SizedBox(width: 6),
                      _buildToolbarIconBtn(
                        icon: Icons.restart_alt_rounded,
                        color: Colors.white60,
                        label: isDesktop ? 'Reset Theme' : null,
                        tooltip: 'Reset Default Colors & Size',
                        onTap: () => setState(() {
                          _colors.addAll(_factoryColors);
                          _hostColors.clear();
                          _chatTextColor = _defaultChatTextColor;
                          _chatUserColor = _defaultChatUserColor;
                          _chatFontSize = 12.0;
                          _chatVersion.value++;
                        }),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: _showHelpDialog,
                        borderRadius: BorderRadius.circular(6),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          child: Text(
                            'Manual',
                            style: TextStyle(color: _cyanAccent, fontSize: 11.5, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _buildWhatIsOmniFeedBadge(isDesktop: isDesktop),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildToolbarIconBtn({
    required IconData icon,
    required Color color,
    String? label,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: label != null ? 10 : 8, vertical: 5),
          decoration: BoxDecoration(
            color: _surfaceElevated,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: _borderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              if (label != null) ...[
                const SizedBox(width: 5),
                Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white70)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildInputsOnlyList({required bool isDesktop}) {
    return [
      if (_enabled['TT']!)
        _buildCapsuleInput(
          controller: _ttPrimaryInput,
          hint: 'TikTok @handle',
          width: isDesktop ? 185 : 165,
          platformKey: 'TT',
          isDesktop: isDesktop,
          trailingWidget: InkWell(
            onTap: _openHostModal,
            borderRadius: BorderRadius.circular(5),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _cyanAccent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: _cyanAccent.withValues(alpha: 0.5), width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.group_add_rounded, size: 12, color: _cyanAccent),
                  const SizedBox(width: 3),
                  Text(
                    '+${_ttHosts.length > 1 ? _ttHosts.length - 1 : 0}',
                    style: const TextStyle(fontSize: 10, color: _cyanAccent, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (_enabled['TW']!)
        _buildCapsuleInput(
          controller: _twInput,
          hint: 'Twitch channel',
          width: isDesktop ? 145 : 130,
          platformKey: 'TW',
          isDesktop: isDesktop,
        ),
      if (_enabled['KC']!)
        _buildCapsuleInput(
          controller: _kcInput,
          hint: 'Kick slug',
          width: isDesktop ? 135 : 120,
          platformKey: 'KC',
          isDesktop: isDesktop,
        ),
      if (_enabled['YT']!)
        _buildCapsuleInput(
          controller: _ytInput,
          hint: 'YouTube Live ID',
          width: isDesktop ? 150 : 135,
          platformKey: 'YT',
          isDesktop: isDesktop,
        ),
    ];
  }

  Widget _buildCapsuleInput({
    required TextEditingController controller,
    required String hint,
    required double width,
    required String platformKey,
    required bool isDesktop,
    Widget? trailingWidget,
  }) {
    final accent = _colors[platformKey]!;
    return Container(
      width: width,
      height: isDesktop ? 36 : 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _bgDeep,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.45), width: 1),
      ),
      child: Row(
        children: [
          Tooltip(
            message: 'Customize $platformKey Accent Color',
            child: InkWell(
              onTap: () => _openColorPicker(platformKey),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white70, width: 1),
                ),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: TextField(
              controller: controller,
              style: TextStyle(fontSize: isDesktop ? 12 : 11.5, color: Colors.white, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(fontSize: isDesktop ? 11.5 : 10.5, color: Colors.white38, fontWeight: FontWeight.normal),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (trailingWidget != null) ...[
            const SizedBox(width: 4),
            trailingWidget,
          ],
        ],
      ),
    );
  }

  Widget _buildTogglePill(String key, String label, {required bool isDesktop}) {
    final active = _enabled[key]!;
    return InkWell(
      onTap: () => setState(() => _enabled[key] = !active),
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 11 : 9, vertical: isDesktop ? 5.5 : 4.5),
        decoration: BoxDecoration(
          color: active ? _neonPink : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            if (active)
              BoxShadow(
                color: _neonPink.withValues(alpha: 0.35),
                blurRadius: 8,
              ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: Size(isDesktop ? 12 : 11, isDesktop ? 12 : 11),
              painter: _PlatformLogoPainter(
                platform: key,
                color: active ? Colors.white : Colors.white60,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: isDesktop ? 11.5 : 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
                color: active ? Colors.white : Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // CORE HUD PANELS (EVENTS, UNIFIED CHAT, TELEMETRY STATS)
  // ---------------------------------------------------------------------------

  Widget _buildEventsPane() {
    return Container(
      decoration: BoxDecoration(
        color: _surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _borderSubtle, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: _surfaceElevated,
              borderRadius: BorderRadius.vertical(top: Radius.circular(9)),
              border: Border(bottom: BorderSide(color: _borderSubtle, width: 1)),
            ),
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 15, color: _cyanAccent),
                const SizedBox(width: 6),
                Text(
                  'EVENTS & ALERTS',
                  style: TextStyle(
                    fontSize: (_chatFontSize * 0.85).clamp(9.5, 14.0),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                    color: Colors.white70,
                  ),
                ),
                const Spacer(),
                ValueListenableBuilder<int>(
                  valueListenable: _eventsVersion,
                  builder: (_, _, _) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${_events.length}',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white54),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _eventsVersion,
              builder: (context, _, _) {
                if (_events.isEmpty) {
                  return const Center(
                    child: Text(
                      'Waiting for gifts & system events...',
                      style: TextStyle(fontSize: 11.5, color: Colors.white24),
                    ),
                  );
                }
                return ListView.builder(
                  controller: _eventsScrollController,
                  padding: const EdgeInsets.all(8),
                  itemCount: _events.length,
                  itemBuilder: (c, i) {
                    final ev = _events[i];
                    final isSys = ev.platform == 'SYS';
                    final accentColor = isSys ? _cyanAccent : ev.badgeBg;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                      decoration: BoxDecoration(
                        color: _surfaceElevated,
                        borderRadius: BorderRadius.circular(7),
                        border: Border(
                          left: BorderSide(color: accentColor, width: 3),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1.5),
                            child: isSys
                                ? _buildBadge('SYS', _cyanAccent, isOutline: true)
                                : _buildBadge(ev.platform, ev.badgeBg),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  fontSize: (_chatFontSize * 0.95).clamp(10.0, 18.0),
                                  height: 1.3,
                                ),
                                children: [
                                  TextSpan(
                                    text: '${ev.user} ',
                                    style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
                                  ),
                                  if (ev.host != null && !isSys)
                                    TextSpan(
                                      text: '(@${ev.host}) ',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: _getColorForHost(ev.host),
                                        fontSize: (_chatFontSize * 0.85).clamp(9.0, 16.0),
                                      ),
                                    ),
                                  TextSpan(
                                    text: ev.text,
                                    style: TextStyle(
                                      color: isSys ? Colors.white70 : const Color(0xFFFFD600),
                                      fontWeight: isSys ? FontWeight.normal : FontWeight.w600,
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
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatPane() {
    return Container(
      decoration: BoxDecoration(
        color: _surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _borderSubtle, width: 1),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: const BoxDecoration(
              color: _surfaceElevated,
              borderRadius: BorderRadius.vertical(top: Radius.circular(9)),
              border: Border(bottom: BorderSide(color: _borderSubtle, width: 1)),
            ),
            child: Row(
              children: [
                const Icon(Icons.forum_rounded, size: 14, color: _cyanAccent),
                const SizedBox(width: 6),
                Text(
                  'UNIFIED CHAT',
                  style: TextStyle(
                    fontSize: (_chatFontSize * 0.85).clamp(9.5, 14.0),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                    color: Colors.white70,
                  ),
                ),
                const Spacer(),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFilterChip('TT', 'TikTok'),
                      _buildFilterChip('TW', 'Twitch'),
                      _buildFilterChip('KC', 'Kick'),
                      _buildFilterChip('YT', 'YouTube'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _chatVersion,
              builder: (context, _, _) {
                if (_chat.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sensors_rounded, size: 28, color: Colors.white.withValues(alpha: 0.12)),
                        const SizedBox(height: 6),
                        const Text(
                          'Connect a live stream to begin ingesting chat',
                          style: TextStyle(fontSize: 12, color: Colors.white24),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  itemCount: _chat.length,
                  itemBuilder: (c, i) {
                    final msg = _chat[i];
                    if (!_chatVisible[msg.platform]!) return const SizedBox.shrink();

                    final hostColor = msg.host != null ? _getColorForHost(msg.host) : null;
                    final isMod = msg.roles.contains('MOD');

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3.5),
                      child: SelectableText.rich(
                        TextSpan(
                          style: TextStyle(
                            fontSize: _chatFontSize,
                            height: 1.38,
                          ),
                          children: [
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 5),
                                child: _buildBadge(msg.platform, msg.badgeBg),
                              ),
                            ),
                            if (msg.host != null && hostColor != null)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 5),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: hostColor.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: hostColor.withValues(alpha: 0.65), width: 0.9),
                                    ),
                                    child: Text(
                                      '@${msg.host}',
                                      style: TextStyle(
                                        fontSize: (_chatFontSize - 2.5).clamp(8.0, 15.0),
                                        color: hostColor,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (isMod)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 5),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: _emeraldLive.withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(color: _emeraldLive.withValues(alpha: 0.7), width: 0.8),
                                    ),
                                    child: Text(
                                      'MOD',
                                      style: TextStyle(
                                        fontSize: (_chatFontSize - 3).clamp(7.5, 13.0),
                                        color: _emeraldLive,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            TextSpan(
                              text: '${msg.user}: ',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: _chatUserColor,
                              ),
                            ),
                            TextSpan(
                              text: msg.text,
                              style: TextStyle(
                                color: _chatTextColor,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVelocityGaugeItem(String label, Color color) {
    final clean = label.toLowerCase().replaceAll('@', '').trim();
    final isCalibrating = _isHostCalibrating(clean);
    final rawCount = _getVelocityFor(clean);
    final step = _getScaledVelocityStep(rawCount);
    final isHype = step >= 100 && !isCalibrating;

    Widget gaugeBar = Container(
      height: 9,
      width: double.infinity,
      decoration: BoxDecoration(
        color: _bgDeep,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _borderSubtle, width: 0.8),
      ),
      child: isCalibrating
          ? LinearProgressIndicator(
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(color.withValues(alpha: 0.25)),
              borderRadius: BorderRadius.circular(5),
            )
          : AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerLeft,
              widthFactor: (step / 100).clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [color.withValues(alpha: 0.7), color],
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
    );

    if (isHype) {
      gaugeBar = RepaintBoundary(
        child: AnimatedBuilder(
          animation: _hypeAnimation,
          builder: (ctx, child) {
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: _hypeAnimation.value * 0.65),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: gaugeBar,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  label.startsWith('@') ? label : '@$label',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: (_chatFontSize * 0.88).clamp(9.5, 14.0),
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
              if (isCalibrating)
                Text(
                  'Calibrating...',
                  style: TextStyle(
                    fontSize: (_chatFontSize * 0.78).clamp(8.5, 12.0),
                    color: Colors.white38,
                    fontStyle: FontStyle.italic,
                  ),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isHype)
                      const Padding(
                        padding: EdgeInsets.only(right: 3.0),
                        child: Text('🔥', style: TextStyle(fontSize: 10)),
                      ),
                    Text(
                      '$step%',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: (_chatFontSize * 0.85).clamp(9.0, 13.5),
                        color: isHype ? Colors.white : Colors.white70,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          gaugeBar,
        ],
      ),
    );
  }

  Widget _buildStatsPane() {
    final List<MapEntry<String, Color>> activeStreams = [];
    if (_enabled['TT']!) {
      for (final h in _ttHosts) {
        activeStreams.add(MapEntry(h, _getColorForHost(h)));
      }
    }
    if (_enabled['TW']! && _twInput.text.trim().isNotEmpty) {
      activeStreams.add(MapEntry('Twitch', _colors['TW']!));
    }
    if (_enabled['KC']! && _kcInput.text.trim().isNotEmpty) {
      activeStreams.add(MapEntry('Kick', _colors['KC']!));
    }
    if (_enabled['YT']! && _ytInput.text.trim().isNotEmpty) {
      activeStreams.add(MapEntry('YouTube', _colors['YT']!));
    }

    return Container(
      decoration: BoxDecoration(
        color: _surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _borderSubtle, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: _surfaceElevated,
              borderRadius: BorderRadius.vertical(top: Radius.circular(9)),
              border: Border(bottom: BorderSide(color: _borderSubtle, width: 1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.insights_rounded, size: 15, color: _cyanAccent),
                    const SizedBox(width: 6),
                    Text(
                      'TELEMETRY',
                      style: TextStyle(
                        fontSize: (_chatFontSize * 0.85).clamp(9.5, 14.0),
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.7,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
                InkWell(
                  onTap: _showStatsConfigModal,
                  borderRadius: BorderRadius.circular(5),
                  child: const Padding(
                    padding: EdgeInsets.all(2.0),
                    child: Icon(Icons.tune_rounded, size: 15, color: _cyanAccent),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_showStopwatch) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _surfaceElevated,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'SESSION UPTIME',
                            style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: Colors.white54),
                          ),
                          const SizedBox(height: 4),
                          ValueListenableBuilder<int>(
                            valueListenable: _sessionSecondsNotifier,
                            builder: (_, secs, _) => Text(
                              _formatDuration(secs),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: (_chatFontSize * 1.35).clamp(14.0, 24.0),
                                fontWeight: FontWeight.w900,
                                color: _cyanAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_showTopSupporter) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _surfaceElevated,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'TOP SUPPORTER',
                            style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: Colors.white54),
                          ),
                          const SizedBox(height: 4),
                          ValueListenableBuilder<String>(
                            valueListenable: _topSupporterNotifier,
                            builder: (_, topSupporter, _) => Text(
                              topSupporter,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: (_chatFontSize * 1.0).clamp(11.0, 18.0),
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: _surfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _borderSubtle),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'RELAY LINK',
                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: Colors.white54),
                        ),
                        Text(
                          _statusText.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: _isConnected ? _emeraldLive : Colors.white60,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_showVelocity && activeStreams.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        Icon(Icons.local_fire_department_rounded, size: 13, color: _neonPink),
                        SizedBox(width: 4),
                        Text(
                          'HYPE METER',
                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: Colors.white54),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ValueListenableBuilder<int>(
                      valueListenable: _velocityTickNotifier,
                      builder: (_, _, _) => Column(
                        children: activeStreams.map((e) => _buildVelocityGaugeItem(e.key, e.value)).toList(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String key, String tooltipLabel) {
    if (!_enabled[key]!) return const SizedBox.shrink();
    final visible = _chatVisible[key]!;
    final color = _colors[key]!;

    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: Tooltip(
        message: 'Toggle $tooltipLabel Chat',
        child: InkWell(
          onTap: () {
            setState(() => _chatVisible[key] = !visible);
            _chatVersion.value++;
          },
          borderRadius: BorderRadius.circular(5),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3.5),
            decoration: BoxDecoration(
              color: visible ? color.withValues(alpha: 0.18) : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: visible ? color : Colors.white24,
                width: 1,
              ),
            ),
            child: CustomPaint(
              size: const Size(11, 11),
              painter: _PlatformLogoPainter(
                platform: key,
                color: visible ? Colors.white : Colors.white38,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBadge(String label, Color color, {bool isOutline = false}) {
    final isDarkText = color.computeLuminance() > 0.55;
    final fgColor = isOutline ? color : (isDarkText ? Colors.black : Colors.white);
    final isPlatformLogo = label == 'TT' || label == 'TW' || label == 'KC' || label == 'YT';

    if (isPlatformLogo) {
      final iconSize = (_chatFontSize - 1).clamp(10.0, 14.0);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 2.5),
        decoration: BoxDecoration(
          color: isOutline ? color.withValues(alpha: 0.15) : color,
          borderRadius: BorderRadius.circular(4),
          border: isOutline ? Border.all(color: color, width: 1) : null,
        ),
        child: CustomPaint(
          size: Size(iconSize, iconSize),
          painter: _PlatformLogoPainter(platform: label, color: fgColor),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: isOutline ? color.withValues(alpha: 0.15) : color,
        borderRadius: BorderRadius.circular(4),
        border: isOutline ? Border.all(color: color, width: 1) : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fgColor,
          fontWeight: FontWeight.w900,
          fontSize: (_chatFontSize - 3).clamp(8.0, 12.0),
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: Column(
            children: [
              _buildPersistentTopBar(isDesktop: isLandscape),
              _buildCommandDrawer(isDesktop: isLandscape),
              _buildBottomToggleBar(isDesktop: isLandscape),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(6.0),
                  child: isLandscape
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 3, child: _buildEventsPane()),
                            const SizedBox(width: 6),
                            Expanded(flex: 5, child: _buildChatPane()),
                            const SizedBox(width: 6),
                            Expanded(flex: 2, child: _buildStatsPane()),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(flex: 6, child: _buildChatPane()),
                            const SizedBox(height: 6),
                            // Segmented Pill Bar for Portrait Mode
                            Container(
                              height: 34,
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: _surfaceCard,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: _borderSubtle),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      onTap: () => setState(() => _portraitTabIndex = 0),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Container(
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: _portraitTabIndex == 0 ? _surfaceElevated : Colors.transparent,
                                          borderRadius: BorderRadius.circular(6),
                                          border: _portraitTabIndex == 0
                                              ? Border.all(color: _cyanAccent.withValues(alpha: 0.5), width: 1)
                                              : null,
                                        ),
                                        child: ValueListenableBuilder<int>(
                                          valueListenable: _eventsVersion,
                                          builder: (_, _, _) => Text(
                                            'EVENTS & ALERTS (${_events.length})',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 0.5,
                                              color: _portraitTabIndex == 0 ? _cyanAccent : Colors.white54,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: InkWell(
                                      onTap: () => setState(() => _portraitTabIndex = 1),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Container(
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: _portraitTabIndex == 1 ? _surfaceElevated : Colors.transparent,
                                          borderRadius: BorderRadius.circular(6),
                                          border: _portraitTabIndex == 1
                                              ? Border.all(color: _cyanAccent.withValues(alpha: 0.5), width: 1)
                                              : null,
                                        ),
                                        child: Text(
                                          'TELEMETRY & HYPE',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.5,
                                            color: _portraitTabIndex == 1 ? _cyanAccent : Colors.white54,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Expanded(
                              flex: 4,
                              child: _portraitTabIndex == 0 ? _buildEventsPane() : _buildStatsPane(),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}