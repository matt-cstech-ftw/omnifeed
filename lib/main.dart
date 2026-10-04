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

  StreamMessage({
    required this.platform,
    required this.user,
    required this.text,
    required this.badgeBg,
    this.host,
    this.roles = const [],
  });
}

class OmniFeedApp extends StatelessWidget {
  const OmniFeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniFeed HUD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F13),
        cardColor: const Color(0xFF16161D),
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
  final Map<String, bool> _enabled = {
    'TT': true,
    'TW': true,
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
    'YT': const Color(0xFFFF0000),
  };

  final Map<String, Color> _factoryColors = {
    'TT': const Color(0xFF25F4EE),
    'TW': const Color(0xFF9146FF),
    'KC': const Color(0xFF53FC18),
    'YT': const Color(0xFFFF0000),
  };

  final Map<String, Color> _hostColors = {};
  final List<Color> _hostPalette = [
    const Color(0xFF00E5FF),
    const Color(0xFFFF4081),
    const Color(0xFFFFD600),
    const Color(0xFF7C4DFF),
    const Color(0xFF00E676),
    const Color(0xFFFF6E40),
    const Color(0xFF40C4FF),
    const Color(0xFFE040FB),
  ];

  static const Color _neonPink = Color(0xFFFF06B5);
  static const Color _cyanAccent = Color(0xFF00E5FF);
  static const Color _cutoutBg = Color(0xFF161620);

  double _chatFontSize = 11.0;
  Color _chatTextColor = Colors.white;
  Color _chatUserColor = Colors.white;
  final Color _defaultChatTextColor = Colors.white;
  final Color _defaultChatUserColor = Colors.white;

  final List<StreamMessage> _chat = [];
  final List<StreamMessage> _events = [];
  final List<String> _ttHosts = [];
  final Set<String> _promptedHosts = {};
  final Map<String, int> _gifterScores = {};

  // Velocity Tracking & Stopwatch
  final Map<String, List<DateTime>> _messageTimestamps = {};
  Timer? _velocityTimer;
  Timer? _stopwatchTimer;
  int _sessionSeconds = 0;

  // Stats Visibility Toggles
  bool _showVelocity = true;
  bool _showStopwatch = true;
  bool _showTopSupporter = true;

  // Hype Animation for 100% velocity
  late AnimationController _hypeController;
  late Animation<double> _hypeAnimation;

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
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);

    _hypeAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _hypeController, curve: Curves.easeInOut),
    );

    _velocityTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pruneOldTimestamps();
      if (mounted) setState(() {});
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
    _chatScrollController.dispose();
    _eventsScrollController.dispose();
    _ttPrimaryInput.dispose();
    _twInput.dispose();
    _kcInput.dispose();
    _ytInput.dispose();
    super.dispose();
  }

  void _recordMessageForVelocity(String key) {
    final now = DateTime.now();
    _messageTimestamps.putIfAbsent(key, () => []).add(now);
  }

  void _pruneOldTimestamps() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    for (final key in _messageTimestamps.keys) {
      _messageTimestamps[key]!.removeWhere((t) => t.isBefore(cutoff));
    }
  }

  int _getVelocityFor(String key) {
    return _messageTimestamps[key]?.length ?? 0;
  }

  int _getScaledVelocityStep(int count) {
    const int maxTarget = 30; // 30 msgs/min = 100%
    if (count <= 0) return 0;
    final pct = (count / maxTarget * 100).clamp(0, 100).toInt();
    return ((pct / 10).round() * 10).clamp(0, 100);
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
    if (host == null || host.isEmpty) return const Color(0xFF00E5FF);
    final key = host.toLowerCase().replaceAll('@', '').trim();
    if (!_hostColors.containsKey(key)) {
      final next = _hostPalette[_hostColors.length % _hostPalette.length];
      _hostColors[key] = next;
    }
    return _hostColors[key]!;
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
        backgroundColor: const Color(0xFF16161D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.install_mobile_rounded, color: Color(0xFF00E5FF), size: 22),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Install OmniFeed App',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isIOS) ...[
                const Text('To install on iPhone / iPad (Safari):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                const SizedBox(height: 8),
                _buildInstallStep('1', 'Tap the Share icon (square with upward arrow) at the bottom of Safari.'),
                const SizedBox(height: 6),
                _buildInstallStep('2', 'Scroll down and tap "Add to Home Screen".'),
                const SizedBox(height: 6),
                _buildInstallStep('3', 'Tap "Add" in the top right to launch OmniFeed in full-screen standalone mode.'),
              ] else if (isAndroid) ...[
                const Text('To install on Android (Chrome / Edge):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                const SizedBox(height: 8),
                _buildInstallStep('1', 'Tap the three dots (⋮) in the top-right corner of your browser.'),
                const SizedBox(height: 6),
                _buildInstallStep('2', 'Select "Install app" or "Add to Home screen".'),
                const SizedBox(height: 6),
                _buildInstallStep('3', 'Confirm installation to add the app icon directly to your launcher.'),
              ] else ...[
                const Text('To install on Desktop (Chrome / Edge):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                const SizedBox(height: 8),
                _buildInstallStep('1', 'Click the Install icon (computer with down arrow) in the address bar.'),
                const SizedBox(height: 6),
                _buildInstallStep('2', 'Click "Install" to run OmniFeed in a clean, dedicated window.'),
              ],
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got It', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildInstallStep(String step, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFF00E5FF), width: 1),
          ),
          child: Text(step, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF))),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.white70, height: 1.35)),
        ),
      ],
    );
  }

  void _showStatsConfigModal() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setDState) => AlertDialog(
          backgroundColor: const Color(0xFF16161D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.0),
          ),
          title: const Row(
            children: [
              Icon(Icons.tune_rounded, color: Color(0xFF00E5FF), size: 18),
              SizedBox(width: 8),
              Text('Stats Display Toggles', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                dense: true,
                activeColor: const Color(0xFF00E5FF),
                checkColor: Colors.black,
                title: const Text('Chat Velocity Gauges', style: TextStyle(fontSize: 12)),
                subtitle: const Text('0-100 Competition Bar per streamer', style: TextStyle(fontSize: 10, color: Colors.white54)),
                value: _showVelocity,
                onChanged: (v) {
                  setState(() => _showVelocity = v ?? true);
                  setDState(() {});
                },
              ),
              CheckboxListTile(
                dense: true,
                activeColor: const Color(0xFF00E5FF),
                checkColor: Colors.black,
                title: const Text('Session Runtime Stopwatch', style: TextStyle(fontSize: 12)),
                subtitle: const Text('Tracks elapsed live stream uptime', style: TextStyle(fontSize: 10, color: Colors.white54)),
                value: _showStopwatch,
                onChanged: (v) {
                  setState(() => _showStopwatch = v ?? true);
                  setDState(() {});
                },
              ),
              CheckboxListTile(
                dense: true,
                activeColor: const Color(0xFF00E5FF),
                checkColor: Colors.black,
                title: const Text('Top Supporter Readout', style: TextStyle(fontSize: 12)),
                subtitle: const Text('Displays session top diamond contributor', style: TextStyle(fontSize: 10, color: Colors.white54)),
                value: _showTopSupporter,
                onChanged: (v) {
                  setState(() => _showTopSupporter = v ?? true);
                  setDState(() {});
                },
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
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
          backgroundColor: const Color(0xFF16161D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.verified_user_rounded, color: Color(0xFF00E5FF), size: 22),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome to OmniFeed HUD',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Multi-Stream Aggregator • Community Edition',
                      style: TextStyle(fontSize: 10, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'OmniFeed unites chats, co-hosts, battle participants, and gift events into a single, real-time second-screen view.',
                    style: TextStyle(fontSize: 12, height: 1.35, color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  _buildAgreementPoint(
                    icon: Icons.shield_outlined,
                    title: '1. Zero Data Collection & Privacy',
                    description: 'We do not collect, store, sell, or track personal data. OmniFeed never asks for or accesses your streaming account logins, passwords, or credentials. It operates solely by listening to public stream telemetry.',
                  ),
                  const SizedBox(height: 10),
                  _buildAgreementPoint(
                    icon: Icons.speed_rounded,
                    title: '2. Early-Stage Development & Resources',
                    description: 'OmniFeed runs on limited resources until development is further along. Safeguards are in place, but you may occasionally see brief capacity holds or minor latency during peak periods.',
                  ),
                  const SizedBox(height: 10),
                  _buildAgreementPoint(
                    icon: Icons.alt_route_rounded,
                    title: '3. Platform Independence',
                    description: 'OmniFeed acts strictly as an external viewer and listener. We are not affiliated with, sponsored by, or endorsed by TikTok, Twitch, Kick, or YouTube. Your broadcasts remain subject to each platform’s rules.',
                  ),
                  const SizedBox(height: 10),
                  _buildAgreementPoint(
                    icon: Icons.handshake_outlined,
                    title: '4. Fair Usage & Community Powered',
                    description: 'Please do not run automated scrapers or spam relay connections. Tool development and server hosting rely directly on creator feedback and voluntary community support.',
                  ),
                  const Divider(height: 20, color: Color(0xFF2A2A38)),
                  InkWell(
                    onTap: () {
                      setDState(() {
                        dontShowAgain = !dontShowAgain;
                      });
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: dontShowAgain,
                              activeColor: const Color(0xFF00E5FF),
                              checkColor: Colors.black,
                              onChanged: (v) {
                                setDState(() {
                                  dontShowAgain = v ?? false;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            "Don't show this again",
                            style: TextStyle(fontSize: 11, color: Colors.white70),
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
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onPressed: () async {
                if (dontShowAgain) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('omnifeed_agreement_accepted', true);
                }
                Navigator.pop(ctx);
              },
              child: const Text(
                'Agree & Continue',
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
              ),
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
        Icon(icon, color: const Color(0xFF00E5FF), size: 17),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 2),
              Text(description, style: const TextStyle(fontSize: 11, color: Colors.white70, height: 1.35)),
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
        backgroundColor: const Color(0xFF16161D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.sync_rounded, color: Color(0xFF00E5FF), size: 22),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'System Update in Progress',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OmniFeed is being updated, please wait a moment.',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            SizedBox(height: 8),
            Text(
              'Our relay is currently rebuilding with fresh optimizations. Service usually resumes automatically within 30 to 60 seconds.',
              style: TextStyle(fontSize: 11, color: Colors.white70, height: 1.35),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Okay', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showAtCapacityModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16161D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFFFE2C55), width: 1.2),
        ),
        title: const Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFFE2C55), size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'OmniFeed is at capacity. Please try again shortly!',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, height: 1.25),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF24151C),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFE2C55).withValues(alpha: 0.4), width: 1),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2.0),
                      child: Icon(Icons.favorite, color: Color(0xFFFE2C55), size: 16),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        "We're experiencing high demand! As an early-stage project, OmniFeed relies on community support to scale our infrastructure. Contributing financially directly supports server and development costs, but spreading the word is just as valuable in helping the tool grow.",
                        style: TextStyle(fontSize: 11, color: Colors.white70, height: 1.4),
                      ),
                    ),
                  ],
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
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFE2C55)),
            onPressed: () {
              Navigator.pop(ctx);
              _showSupportModal();
            },
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.favorite, size: 14, color: Colors.white),
                SizedBox(width: 5),
                Text('Support Development', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              ],
            ),
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
        backgroundColor: const Color(0xFF16161D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
        ),
        title: const Row(
          children: [
            Icon(Icons.admin_panel_settings_rounded, color: Color(0xFF00E5FF), size: 20),
            SizedBox(width: 8),
            Text('Relay Admin Gate', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
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
              decoration: const InputDecoration(
                hintText: 'Admin Key',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            onPressed: () async {
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
            },
            child: const Text('Authenticate', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
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
    final handles = (data['tracked_handles'] as List? ?? []);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16161D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
        ),
        title: const Row(
          children: [
            Icon(Icons.analytics_outlined, color: Color(0xFF00E5FF), size: 20),
            SizedBox(width: 8),
            Text('Relay Live Telemetry', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStatRow('Active Web Clients:', '$clients'),
              _buildStatRow('Active TikTok Streams:', '$streams'),
              _buildStatRow('Cached User IDs:', '$cached'),
              const Divider(height: 18, color: Color(0xFF2E2E3D)),
              const Text('Active Host Streams:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 6),
              if (handles.isEmpty)
                const Text('No active streams connected', style: TextStyle(fontSize: 11, color: Colors.white54))
              else
                ...handles.map((h) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('@$h', style: const TextStyle(fontSize: 12, color: Color(0xFF00E5FF), fontWeight: FontWeight.bold)),
                      const Text('Live Tracking', style: TextStyle(fontSize: 10, color: Colors.greenAccent)),
                    ],
                  ),
                )),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF))),
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
              BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 4),
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
        backgroundColor: const Color(0xFF16161D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.menu_book_rounded, color: Color(0xFF00E5FF), size: 22),
            ),
            const SizedBox(width: 10),
            const Text(
              'OmniFeed Manual',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHelpStep('1', 'Select Ingestion Feeds', 'Toggle platform pills to reveal handle input boxes for TikTok, Twitch, Kick, and YouTube.'),
              const SizedBox(height: 10),
              _buildHelpStep('2', 'Enter Handles / IDs', 'Input your creator usernames or YouTube Live Video IDs.'),
              const SizedBox(height: 10),
              _buildHelpStep('3', 'Manage Active Co-Hosts', 'Tap the +0 group badge under TikTok to view co-hosts and customize neon badge colors.'),
              const SizedBox(height: 10),
              _buildHelpStep('4', 'Automatic Co-Host / Battle Detection', 'When linked anchors join a box or battle, an instant prompt allows you to merge their chat with a single tap.'),
              const SizedBox(height: 10),
              _buildHelpStep('5', 'Customize Chat Appearance', 'Tap the text icon (tT) in the toolbar to adjust font sizing across all panes and set custom chat colors.'),
              const SizedBox(height: 10),
              _buildHelpStep('6', 'Landscape & Portrait Responsive', 'Operates in 3 split panes in landscape, or a focused vertical feed with tabbed bottom panels in portrait.'),
              const SizedBox(height: 10),
              _buildHelpStep('7', 'Go Live', 'Tap CONNECT to aggregate live chats, subscriber badges, alerts, and diamonds simultaneously.'),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
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
            color: const Color(0xFF00E5FF).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFF00E5FF), width: 1),
          ),
          child: Text(
            step,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF00E5FF)),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 2),
              Text(description, style: const TextStyle(fontSize: 11, color: Colors.white70, height: 1.3)),
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
        backgroundColor: const Color(0xFF16161D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.hub_rounded, color: Color(0xFF00E5FF), size: 22),
            ),
            const SizedBox(width: 10),
            const Text(
              'What is OmniFeed?',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'OmniFeed is a unified, real-time live stream HUD built for content creators and streamers.',
                style: TextStyle(fontSize: 13, height: 1.4, color: Colors.white),
              ),
              const SizedBox(height: 12),
              _buildAboutPoint(Icons.alt_route_rounded, 'Multi-Platform Aggregation', 'Combines chats and viewer interactions from TikTok, Twitch, Kick, and YouTube into one seamless, unified stream view.'),
              const SizedBox(height: 10),
              _buildAboutPoint(Icons.group_add_rounded, 'TikTok Co-Host & Battle Detection', 'Automatically detects rival anchors and co-hosts during TikTok Live sessions, allowing you to merge their live feeds with custom color coding.'),
              const SizedBox(height: 10),
              _buildAboutPoint(Icons.devices_rounded, 'Second-Screen HUD', 'Designed to run cleanly on a phone, tablet, or secondary monitor so you can easily read chat, moderate, and engage without cluttering your main broadcast display.'),
              const SizedBox(height: 10),
              _buildAboutPoint(Icons.card_giftcard_rounded, 'Live Alerts, Gifts & Session Stats', 'Tracks gifts, diamond values, top session supporters, and system connection events in dedicated real-time panels.'),
              const Divider(height: 24, color: Color(0xFF2A2A38)),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E28),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFFE2C55).withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.favorite, color: Color(0xFFFE2C55), size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Enjoying the tool? Tap the heart icon in the toolbar to support ongoing development!',
                        style: TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got It', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutPoint(IconData icon, String title, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFF00E5FF), size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 2),
              Text(description, style: const TextStyle(fontSize: 11, color: Colors.white70, height: 1.3)),
            ],
          ),
        ),
      ],
    );
  }

  void _showChatAppearanceModal() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setDState) => AlertDialog(
          backgroundColor: const Color(0xFF16161D),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: const Row(
            children: [
              Icon(Icons.format_size_rounded, color: Color(0xFF00E5FF), size: 20),
              SizedBox(width: 8),
              Text('Chat & HUD Appearance', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Global Pane Text Size:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    Text('${_chatFontSize.toInt()} pt', style: const TextStyle(fontSize: 12, color: Color(0xFF00E5FF))),
                  ],
                ),
                Slider(
                  value: _chatFontSize,
                  min: 9.0,
                  max: 22.0,
                  divisions: 13,
                  label: '${_chatFontSize.toInt()} pt',
                  activeColor: const Color(0xFF00E5FF),
                  onChanged: (v) {
                    setState(() => _chatFontSize = v);
                    setDState(() {});
                  },
                ),
                const Divider(height: 20),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Chat Text Color', style: TextStyle(fontSize: 12)),
                  trailing: InkWell(
                    onTap: () {
                      Color pick = _chatTextColor;
                      showDialog(
                        context: context,
                        builder: (subCtx) => AlertDialog(
                          title: const Text('Text Color'),
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
                              child: const Text('Default White'),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                setState(() => _chatTextColor = pick);
                                setDState(() {});
                                Navigator.pop(subCtx);
                              },
                              child: const Text('Apply'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      width: 22,
                      height: 22,
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
                  title: const Text('Username Color', style: TextStyle(fontSize: 12)),
                  trailing: InkWell(
                    onTap: () {
                      Color pick = _chatUserColor;
                      showDialog(
                        context: context,
                        builder: (subCtx) => AlertDialog(
                          title: const Text('Username Color'),
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
                              child: const Text('Default White'),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                setState(() => _chatUserColor = pick);
                                setDState(() {});
                                Navigator.pop(subCtx);
                              },
                              child: const Text('Apply'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      width: 22,
                      height: 22,
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
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _scrollToBottom(ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openColorPicker(String platformKey) {
    Color pickerColor = _colors[platformKey]!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$platformKey Accent Color'),
        content: SingleChildScrollView(
          child: ColorPicker(pickerColor: pickerColor, onColorChanged: (c) => pickerColor = c, paletteType: PaletteType.hsvWithHue, enableAlpha: false),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _colors[platformKey] = _factoryColors[platformKey]!);
              Navigator.pop(ctx);
            },
            child: const Text('Reset Default'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _colors[platformKey] = pickerColor);
              Navigator.pop(ctx);
            },
            child: const Text('Apply'),
          ),
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
        title: Text('@$clean Badge Color'),
        content: SingleChildScrollView(
          child: ColorPicker(pickerColor: pickerColor, onColorChanged: (c) => pickerColor = c, paletteType: PaletteType.hsvWithHue, enableAlpha: false),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _hostColors.remove(clean));
              onUpdate();
              Navigator.pop(ctx);
            },
            child: const Text('Reset Default'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _hostColors[clean] = pickerColor);
              onUpdate();
              Navigator.pop(ctx);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  void _toggleConnection() {
    FocusManager.instance.primaryFocus?.unfocus();

    if (_isConnected) {
      _disconnectAll();
      _stopwatchTimer?.cancel();
      _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Feeds Disconnected', badgeBg: const Color(0xFF00E5FF)));
      setState(() {
        _isConnected = false;
        _statusText = 'Disconnected';
        _sessionSeconds = 0;
      });
      return;
    }

    _saveHandles();

    setState(() {
      _isConnected = true;
      _statusText = 'Connected';
      _isMenuExpanded = false;
      _sessionSeconds = 0;
    });

    _stopwatchTimer?.cancel();
    _stopwatchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isConnected && mounted) {
        setState(() => _sessionSeconds++);
      }
    });

    _connectStreams();
  }

  void _disconnectSingleHost(String handle) {
    final clean = handle.toLowerCase().replaceAll('@', '').trim();
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
        backgroundColor: const Color(0xFF16161D),
        title: const Row(
          children: [
            Icon(Icons.person_add_alt_1_rounded, color: Color(0xFF00E5FF), size: 20),
            SizedBox(width: 8),
            Text('Co-Host Detected', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '@$cohostHandle is currently co-hosting.\nWould you like to add their chat feed to the unified view?',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Ignore', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            onPressed: () {
              Navigator.pop(ctx);
              _attachSingleTikTokHost(cohostHandle);
            },
            child: const Text('Add Chat', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
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

    if (kIsWeb) {
      _connectTikTokWebRelay(cleanHandle);
      return;
    }

    runZonedGuarded(() async {
      final client = TikTokLiveClient(cleanHandle);
      _ttClientsMap[cleanHandle.toLowerCase()] = client;

      client.on(EventType.connected, (evt) {
        _addEvent(StreamMessage(
          platform: 'SYS',
          user: 'System',
          text: 'Connected to co-host @$cleanHandle',
          badgeBg: const Color(0xFF00E5FF),
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

    _addEvent(StreamMessage(
      platform: 'SYS',
      user: 'System',
      text: 'Connecting to Cloud Relay for @$cleanHandle...',
      badgeBg: const Color(0xFF00E5FF),
    ));

    try {
      final channel = WebSocketChannel.connect(bridgeUri);
      _ttWebChannelsMap[cleanHandle.toLowerCase()] = channel;

      channel.sink.add(jsonEncode({'action': 'connect', 'handle': cleanHandle}));

      channel.stream.listen((raw) {
        final data = jsonDecode(raw.toString());
        final event = data['event'];

        if (event == 'connected') {
          _addEvent(StreamMessage(
            platform: 'SYS',
            user: 'System',
            text: 'Connected to TikTok @${data['handle']}',
            badgeBg: const Color(0xFF00E5FF),
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
          if (data['code'] == 503 || data['message']?.toString().contains('capacity') == true) {
            _showAtCapacityModal();
          } else {
            _showUpdatingModal();
          }
          _addEvent(StreamMessage(
            platform: 'SYS',
            user: 'Error',
            text: 'TT: ${data['message']}',
            badgeBg: Colors.redAccent,
          ));
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
      }

      if (kIsWeb) {
        for (final handle in _ttHosts) {
          _connectTikTokWebRelay(handle);
        }
      } else {
        for (final handle in _ttHosts) {
          runZonedGuarded(() async {
            final client = TikTokLiveClient(handle);
            _ttClientsMap[handle.toLowerCase()] = client;

            _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Connecting to @$handle...', badgeBg: const Color(0xFF00E5FF)));

            client.on(EventType.connected, (evt) {
              _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Connected to @$handle', badgeBg: const Color(0xFF00E5FF), host: handle));
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
        try {
          _twitchChannel = WebSocketChannel.connect(Uri.parse('wss://irc-ws.chat.twitch.tv:443'));
          _twitchChannel!.sink.add('CAP REQ :twitch.tv/tags twitch.tv/commands');
          _twitchChannel!.sink.add('PASS oauth:SCHMOOPIIE');
          _twitchChannel!.sink.add('NICK justinfan${10000 + DateTime.now().millisecond}');
          _twitchChannel!.sink.add('JOIN #$user');

          _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Connected to Twitch #$user', badgeBg: const Color(0xFF00E5FF)));

          _twitchChannel!.stream.listen((raw) {
            final msg = raw.toString();
            if (msg.startsWith('PING')) {
              _twitchChannel!.sink.add('PONG :tmi.twitch.tv');
            } else if (msg.contains('PRIVMSG')) {
              final parts = msg.split(' :');
              if (parts.length >= 3) {
                final text = parts.sublist(2).join(' :').trim();
                final userMatch = RegExp(r':(\w+)!').firstMatch(msg);
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
        _connectKick(kickSlug);
      }
    }

    // 4. YouTube Ingestion
    if (_enabled['YT']!) {
      final ytId = _ytInput.text.trim();
      if (ytId.isNotEmpty) {
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

        _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Connected to Kick #$slug', badgeBg: const Color(0xFF00E5FF)));

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
    _addEvent(StreamMessage(platform: 'SYS', user: 'System', text: 'Polling YouTube Live stream', badgeBg: const Color(0xFF00E5FF)));

    _ytTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      try {
        final cleanId = channelOrVideoId.replaceAll('https://www.youtube.com/watch?v=', '');
        final url = 'https://www.youtube.com/live_chat?v=$cleanId';
        final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'});
        if (res.statusCode == 200) {
          final body = res.body;
          final match = RegExp(r'"liveChatTextMessageRenderer":\{"message":\{"runs":\[\{"text":"(.*?)"\}\]\},"authorName":\{"simpleText":"(.*?)"\}').allMatches(body);
          for (final m in match) {
            final text = m.group(1) ?? '';
            final sender = m.group(2) ?? 'YTUser';
            _recordMessageForVelocity('YouTube');
            _addChat(StreamMessage(
              platform: 'YT',
              user: sender,
              text: text,
              badgeBg: _colors['YT']!,
            ));
          }
        }
      } catch (_) {}
    });
  }

  void _recordGift(String user, int value) {
    setState(() {
      _gifterScores[user] = (_gifterScores[user] ?? 0) + value;
    });
  }

  void _addChat(StreamMessage msg) {
    setState(() {
      _chat.add(msg);
      if (_chat.length > 250) _chat.removeAt(0);
    });
    _scrollToBottom(_chatScrollController);
  }

  void _addEvent(StreamMessage msg) {
    setState(() {
      _events.add(msg);
      if (_events.length > 200) _events.removeAt(0);
    });
    _scrollToBottom(_eventsScrollController);
  }

  void _openHostModal() {
    final entry = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16161D),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setMState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              height: 320,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Manage TikTok Co-Hosts', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(controller: entry, decoration: const InputDecoration(hintText: 'Handle @', isDense: true)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle, color: Color(0xFF00E5FF)),
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
                      )
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _ttHosts.length,
                      itemBuilder: (c, idx) {
                        final hostHandle = _ttHosts[idx];
                        final hostColor = _getColorForHost(hostHandle);
                        return ListTile(
                          dense: true,
                          leading: InkWell(
                            onTap: () {
                              _openHostColorPicker(hostHandle, () {
                                setMState(() {});
                              });
                            },
                            child: Tooltip(
                              message: 'Change Badge Color',
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: hostColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white60, width: 1.5),
                                ),
                              ),
                            ),
                          ),
                          title: Text('@$hostHandle', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('Tap color circle to customize', style: TextStyle(fontSize: 10, color: Colors.grey)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18),
                            onPressed: () {
                              final removed = _ttHosts.removeAt(idx);
                              _disconnectSingleHost(removed);
                              setState(() {});
                              setMState(() {});
                            },
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
                  color: const Color(0xFF00E5FF),
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
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 12 : 9, vertical: isDesktop ? 6 : 4.5),
        decoration: BoxDecoration(
          color: const Color(0xFF0A2B35),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF00E5FF), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.28),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.install_mobile_rounded, size: isDesktop ? 16 : 14, color: const Color(0xFF00E5FF)),
            const SizedBox(width: 5),
            Text(
              'Install App',
              style: TextStyle(
                fontSize: isDesktop ? 12 : 11,
                color: const Color(0xFF00E5FF),
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
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
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 14 : 10, vertical: isDesktop ? 8 : 6),
        decoration: BoxDecoration(
          color: const Color(0xFF0E2230),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF00E5FF), width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.help_outline_rounded, size: isDesktop ? 16 : 14, color: const Color(0xFF00E5FF)),
            const SizedBox(width: 5),
            Text(
              'What is OmniFeed?',
              style: TextStyle(fontSize: isDesktop ? 12.5 : 11, color: const Color(0xFF00E5FF), fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectButton({bool isDesktop = false}) {
    return InkWell(
      onTap: _toggleConnection,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: isDesktop ? 40 : 36,
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 18 : 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _isConnected ? _cyanAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _cyanAccent, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: _cyanAccent.withValues(alpha: _isConnected ? 0.35 : 0.15),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Text(
          _isConnected ? 'Disconnect' : 'Connect',
          style: TextStyle(
            fontSize: isDesktop ? 13 : 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: _isConnected ? _cutoutBg : _cyanAccent,
          ),
        ),
      ),
    );
  }

  Widget _buildPersistentTopBar({required bool isDesktop}) {
    return Container(
      height: isDesktop ? 50 : 46,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF141419),
        border: Border(bottom: BorderSide(color: Color(0xFF22222D), width: 1)),
      ),
      child: Row(
        children: [
          _buildBrandLogo(isDesktop: isDesktop),
          const SizedBox(width: 8),
          Container(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 8 : 6, vertical: isDesktop ? 3.5 : 2.5),
            decoration: BoxDecoration(
              color: _isConnected ? Colors.green.withValues(alpha: 0.18) : Colors.white10,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: _isConnected ? Colors.greenAccent : Colors.white24, width: 0.8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(radius: isDesktop ? 4 : 3.5, backgroundColor: _isConnected ? Colors.greenAccent : Colors.white38),
                const SizedBox(width: 4),
                Text(
                  _isConnected ? 'LIVE' : 'IDLE',
                  style: TextStyle(
                    fontSize: isDesktop ? 11 : 9.5,
                    fontWeight: FontWeight.w800,
                    color: _isConnected ? Colors.greenAccent : Colors.white54,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          _buildInstallAppButton(isDesktop: isDesktop),
        ],
      ),
    );
  }

  Widget _buildBottomToggleBar({required bool isDesktop}) {
    return InkWell(
      onTap: () => setState(() => _isMenuExpanded = !_isMenuExpanded),
      child: Container(
        height: isDesktop ? 26 : 22,
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Color(0xFF1B1B24),
          border: Border(
            top: BorderSide(color: Color(0xFF242432), width: 1),
            bottom: BorderSide(color: Color(0xFF22222D), width: 1),
          ),
        ),
        child: Center(
          child: Container(
            width: isDesktop ? 160 : 130,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF232330),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: AnimatedRotation(
                turns: _isMenuExpanded ? 0.0 : 0.5,
                duration: const Duration(milliseconds: 200),
                child: Transform.scale(
                  scaleX: 5.0,
                  scaleY: 1.0,
                  child: Icon(
                    Icons.keyboard_arrow_up_rounded,
                    color: const Color(0xFF00E5FF),
                    size: isDesktop ? 20 : 16,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitAccordionDrawer() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: !_isMenuExpanded
          ? const SizedBox.shrink()
          : Container(
              decoration: const BoxDecoration(
                color: Color(0xFF161620),
                border: Border(bottom: BorderSide(color: _neonPink, width: 1.0)),
              ),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildTogglePill('TT', 'TikTok', isDesktop: false),
                      const SizedBox(width: 6),
                      _buildTogglePill('TW', 'Twitch', isDesktop: false),
                      const SizedBox(width: 6),
                      _buildTogglePill('KC', 'Kick', isDesktop: false),
                      const SizedBox(width: 6),
                      _buildTogglePill('YT', 'YouTube', isDesktop: false),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ..._buildInputsOnlyList(isDesktop: false),
                        _buildConnectButton(isDesktop: false),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Divider(height: 8, color: Color(0xFF242432)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        iconSize: 27,
                        padding: const EdgeInsets.all(8),
                        icon: const Icon(Icons.favorite_outline, color: Color(0xFFFE2C55)),
                        tooltip: 'Support OmniFeed',
                        onPressed: _showSupportModal,
                      ),
                      IconButton(
                        iconSize: 27,
                        padding: const EdgeInsets.all(8),
                        icon: const Icon(Icons.format_size_rounded, color: Color(0xFF00E5FF)),
                        tooltip: 'Chat Appearance (Text Size & Color)',
                        onPressed: _showChatAppearanceModal,
                      ),
                      IconButton(
                        iconSize: 27,
                        padding: const EdgeInsets.all(8),
                        icon: const Icon(Icons.color_lens_outlined, color: Colors.grey),
                        tooltip: 'Reset Colors',
                        onPressed: () => setState(() {
                          _colors.addAll(_factoryColors);
                          _hostColors.clear();
                          _chatTextColor = _defaultChatTextColor;
                          _chatUserColor = _defaultChatUserColor;
                          _chatFontSize = 11.0;
                        }),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: _showHelpDialog,
                        child: const Text('Need Help?', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11)),
                      ),
                      const SizedBox(width: 10),
                      _buildWhatIsOmniFeedBadge(isDesktop: false),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildLandscapeAccordionDrawer() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: !_isMenuExpanded
          ? const SizedBox.shrink()
          : Container(
              decoration: const BoxDecoration(
                color: Color(0xFF161620),
                border: Border(bottom: BorderSide(color: _neonPink, width: 1.0)),
              ),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Row(
                            children: [
                              _buildTogglePill('TT', 'TikTok', isDesktop: true),
                              const SizedBox(width: 6),
                              _buildTogglePill('TW', 'Twitch', isDesktop: true),
                              const SizedBox(width: 6),
                              _buildTogglePill('KC', 'Kick', isDesktop: true),
                              const SizedBox(width: 6),
                              _buildTogglePill('YT', 'YouTube', isDesktop: true),
                            ],
                          ),
                        ),
                        const VerticalDivider(width: 24, indent: 4, endIndent: 4),
                        ..._buildInputsOnlyList(isDesktop: true),
                        const SizedBox(width: 4),
                        _buildConnectButton(isDesktop: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Divider(height: 10, color: Color(0xFF242432)),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.favorite_outline, size: 21, color: Color(0xFFFE2C55)),
                        tooltip: 'Support OmniFeed',
                        onPressed: _showSupportModal,
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.format_size_rounded, size: 21, color: Color(0xFF00E5FF)),
                        tooltip: 'Chat Appearance (Text Size & Color)',
                        onPressed: _showChatAppearanceModal,
                      ),
                      IconButton(
                        icon: const Icon(Icons.color_lens_outlined, size: 21, color: Colors.grey),
                        tooltip: 'Reset Colors',
                        onPressed: () => setState(() {
                          _colors.addAll(_factoryColors);
                          _hostColors.clear();
                          _chatTextColor = _defaultChatTextColor;
                          _chatUserColor = _defaultChatUserColor;
                          _chatFontSize = 11.0;
                        }),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _showHelpDialog,
                        child: const Text('Need Help?', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 10),
                      _buildWhatIsOmniFeedBadge(isDesktop: true),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  List<Widget> _buildInputsOnlyList({required bool isDesktop}) {
    return [
      if (_enabled['TT']!) ...[
        _buildInputCard(
          controller: _ttPrimaryInput,
          label: 'TikTok @',
          width: isDesktop ? 135 : 110,
          platformKey: 'TT',
          isDesktop: isDesktop,
          extraAction: InkWell(
            onTap: _openHostModal,
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 6 : 5, vertical: isDesktop ? 2 : 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF102A38),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF00E5FF), width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.group_add, size: isDesktop ? 14 : 13, color: const Color(0xFF00E5FF)),
                  const SizedBox(width: 2),
                  Text(
                    '+${_ttHosts.length > 1 ? _ttHosts.length - 1 : 0}',
                    style: TextStyle(fontSize: isDesktop ? 11 : 10, color: const Color(0xFF00E5FF), fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(width: isDesktop ? 10 : 8),
      ],
      if (_enabled['TW']!) ...[
        _buildInputCard(controller: _twInput, label: 'Twitch', width: isDesktop ? 135 : 110, platformKey: 'TW', isDesktop: isDesktop),
        SizedBox(width: isDesktop ? 10 : 8),
      ],
      if (_enabled['KC']!) ...[
        _buildInputCard(controller: _kcInput, label: 'Kick', width: isDesktop ? 135 : 110, platformKey: 'KC', isDesktop: isDesktop),
        SizedBox(width: isDesktop ? 10 : 8),
      ],
      if (_enabled['YT']!) ...[
        _buildInputCard(controller: _ytInput, label: 'YouTube ID', width: isDesktop ? 135 : 110, platformKey: 'YT', isDesktop: isDesktop),
        SizedBox(width: isDesktop ? 10 : 8),
      ],
    ];
  }

  Widget _buildEventsPane() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF16161D), borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'EVENTS & ALERTS',
            style: TextStyle(fontSize: (_chatFontSize * 0.95).clamp(9.0, 16.0), fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const Divider(height: 12),
          Expanded(
            child: ListView.builder(
              controller: _eventsScrollController,
              itemCount: _events.length,
              itemBuilder: (c, i) {
                final ev = _events[i];
                final isSys = ev.platform == 'SYS';
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22222B),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      if (isSys)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E5FF).withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: const Color(0xFF00E5FF), width: 1.0),
                          ),
                          child: Text(
                            'SYS',
                            style: TextStyle(
                              color: const Color(0xFF00E5FF),
                              fontWeight: FontWeight.w900,
                              fontSize: (_chatFontSize * 0.75).clamp(8.0, 13.0),
                            ),
                          ),
                        )
                      else
                        _buildBadge(ev.platform, ev.badgeBg),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ev.user,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: _chatFontSize,
                                color: ev.badgeBg,
                              ),
                            ),
                            Text(
                              ev.text,
                              style: TextStyle(
                                fontSize: (_chatFontSize - 1).clamp(8.5, 18.0),
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
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
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF16161D), borderRadius: BorderRadius.circular(6)),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'UNIFIED CHAT',
                style: TextStyle(fontSize: (_chatFontSize * 0.95).clamp(9.0, 16.0), fontWeight: FontWeight.bold, color: Colors.grey),
              ),
              Row(
                children: [
                  const Text('Filter: ', style: TextStyle(fontSize: 10, color: Colors.grey)),
                  _buildFilterCheck('TT', 'TikTok'),
                  _buildFilterCheck('TW', 'Twitch'),
                  _buildFilterCheck('KC', 'Kick'),
                  _buildFilterCheck('YT', 'YouTube'),
                ],
              ),
            ],
          ),
          const Divider(height: 12),
          Expanded(
            child: ListView.builder(
              controller: _chatScrollController,
              itemCount: _chat.length,
              itemBuilder: (c, i) {
                final msg = _chat[i];
                if (!_chatVisible[msg.platform]!) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildBadge(msg.platform, msg.badgeBg),
                      if (msg.host != null) ...[
                        const SizedBox(width: 4),
                        Builder(builder: (ctx) {
                          final hostColor = _getColorForHost(msg.host);
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: hostColor.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: hostColor.withValues(alpha: 0.7), width: 0.9),
                            ),
                            child: Text(
                              '@${msg.host}',
                              style: TextStyle(
                                fontSize: (_chatFontSize - 2).clamp(8.0, 18.0),
                                color: hostColor,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          );
                        }),
                      ],
                      const SizedBox(width: 6),
                      Text(
                        '${msg.user}: ',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: _chatFontSize, color: _chatUserColor),
                      ),
                      Expanded(
                        child: SelectableText(
                          msg.text,
                          style: TextStyle(fontSize: _chatFontSize, color: _chatTextColor),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVelocityGaugeItem(String label, Color color) {
    final rawCount = _getVelocityFor(label);
    final step = _getScaledVelocityStep(rawCount);
    final isHype = step >= 100;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label.startsWith('@') ? label : '@$label',
                style: TextStyle(
                  fontSize: (_chatFontSize * 0.9).clamp(9.0, 15.0),
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Row(
                children: [
                  if (isHype)
                    const Padding(
                      padding: EdgeInsets.only(right: 4.0),
                      child: Text('🔥 HYPE', style: TextStyle(color: Colors.amberAccent, fontSize: 9.5, fontWeight: FontWeight.w900)),
                    ),
                  Text(
                    '$step% ($rawCount m/m)',
                    style: TextStyle(
                      fontSize: (_chatFontSize * 0.85).clamp(8.5, 14.0),
                      color: isHype ? Colors.white : Colors.white70,
                      fontWeight: isHype ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 3),
          AnimatedBuilder(
            animation: _hypeAnimation,
            builder: (ctx, child) {
              return Container(
                height: 10,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF22222E),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: isHype ? color.withValues(alpha: _hypeAnimation.value) : Colors.transparent,
                    width: 1.0,
                  ),
                  boxShadow: [
                    if (isHype)
                      BoxShadow(
                        color: color.withValues(alpha: _hypeAnimation.value * 0.6),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                  ],
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: (step / 100).clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isHype ? color : color.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStatsPane(String topSupporter) {
    // Collect active streamers for velocity competition
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
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF16161D), borderRadius: BorderRadius.circular(6)),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'SESSION STATS',
                  style: TextStyle(
                    fontSize: (_chatFontSize * 0.95).clamp(9.0, 16.0),
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                InkWell(
                  onTap: _showStatsConfigModal,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(3.0),
                    child: Icon(Icons.tune_rounded, size: (_chatFontSize * 1.1).clamp(13.0, 18.0), color: const Color(0xFF00E5FF)),
                  ),
                ),
              ],
            ),
            const Divider(height: 12),
            if (_showStopwatch) ...[
              Text('Session Stopwatch:', style: TextStyle(fontSize: (_chatFontSize * 0.85).clamp(8.5, 14.0), color: Colors.grey)),
              const SizedBox(height: 2),
              Text(
                _formatDuration(_sessionSeconds),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: (_chatFontSize * 1.25).clamp(12.0, 24.0),
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFF00E5FF),
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (_showTopSupporter) ...[
              Text('Top Supporter:', style: TextStyle(fontSize: (_chatFontSize * 0.85).clamp(8.5, 14.0), color: Colors.grey)),
              const SizedBox(height: 2),
              Text(
                topSupporter,
                style: TextStyle(
                  fontSize: (_chatFontSize * 1.1).clamp(10.0, 20.0),
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
            ],
            Text('Relay Link Status:', style: TextStyle(fontSize: (_chatFontSize * 0.85).clamp(8.5, 14.0), color: Colors.grey)),
            const SizedBox(height: 2),
            Text(
              _statusText,
              style: TextStyle(
                fontSize: (_chatFontSize * 0.9).clamp(9.0, 15.0),
                color: _isConnected ? Colors.greenAccent : Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_showVelocity && activeStreams.isNotEmpty) ...[
              const Divider(height: 16),
              Text(
                'CHAT VELOCITY (0-100)',
                style: TextStyle(fontSize: (_chatFontSize * 0.85).clamp(8.5, 14.0), fontWeight: FontWeight.bold, color: Colors.grey),
              ),
              const SizedBox(height: 6),
              ...activeStreams.map((e) => _buildVelocityGaugeItem(e.key, e.value)),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topSupporter = _gifterScores.isEmpty
        ? 'No gifts yet'
        : _gifterScores.entries.reduce((a, b) => a.value > b.value ? a : b).key;

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
              isLandscape ? _buildLandscapeAccordionDrawer() : _buildPortraitAccordionDrawer(),
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
                            const SizedBox(width: 2),
                            Expanded(flex: 2, child: _buildStatsPane(topSupporter)),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(flex: 6, child: _buildChatPane()),
                            const SizedBox(height: 6),
                            Container(
                              height: 32,
                              color: const Color(0xFF16161D),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      onTap: () => setState(() => _portraitTabIndex = 0),
                                      child: Container(
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: _portraitTabIndex == 0 ? const Color(0xFF00E5FF) : Colors.transparent,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          'EVENTS & ALERTS (${_events.length})',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: _portraitTabIndex == 0 ? Colors.white : Colors.grey,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: InkWell(
                                      onTap: () => setState(() => _portraitTabIndex = 1),
                                      child: Container(
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: _portraitTabIndex == 1 ? const Color(0xFF00E5FF) : Colors.transparent,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          'SESSION STATS',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: _portraitTabIndex == 1 ? Colors.white : Colors.grey,
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
                              child: _portraitTabIndex == 0 ? _buildEventsPane() : _buildStatsPane(topSupporter),
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

  Widget _buildTogglePill(String key, String label, {required bool isDesktop}) {
    final active = _enabled[key]!;
    return InkWell(
      onTap: () => setState(() => _enabled[key] = !active),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 12 : 8, vertical: isDesktop ? 7 : 5),
        decoration: BoxDecoration(
          color: active ? _neonPink : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: _neonPink,
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: _neonPink.withValues(alpha: active ? 0.35 : 0.12),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: isDesktop ? 12 : 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
            color: active ? _cutoutBg : _neonPink,
          ),
        ),
      ),
    );
  }

  Widget _buildInputCard({
    required TextEditingController controller,
    required String label,
    required double width,
    required String platformKey,
    required bool isDesktop,
    Widget? extraAction,
  }) {
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: isDesktop ? 40 : 36,
            child: TextField(
              controller: controller,
              style: TextStyle(fontSize: isDesktop ? 12.5 : 11),
              decoration: InputDecoration(
                labelText: label,
                labelStyle: TextStyle(fontSize: isDesktop ? 11.5 : 10),
                contentPadding: EdgeInsets.symmetric(horizontal: isDesktop ? 10 : 8, vertical: 4),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Color: ', style: TextStyle(fontSize: isDesktop ? 10.5 : 9, color: Colors.grey)),
              InkWell(
                onTap: () => _openColorPicker(platformKey),
                child: Container(
                  width: isDesktop ? 16 : 14,
                  height: isDesktop ? 16 : 14,
                  decoration: BoxDecoration(
                    color: _colors[platformKey],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              if (extraAction != null) ...[
                const SizedBox(width: 6),
                extraAction,
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterCheck(String key, String label) {
    if (!_enabled[key]!) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Checkbox(
            value: _chatVisible[key],
            onChanged: (v) => setState(() => _chatVisible[key] = v ?? true),
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 9)),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildBadge(String label, Color color) {
    final isDarkText = color.computeLuminance() > 0.5;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
      child: Text(
        label,
        style: TextStyle(color: isDarkText ? Colors.black : Colors.white, fontWeight: FontWeight.w900, fontSize: 9),
      ),
    );
  }
}
