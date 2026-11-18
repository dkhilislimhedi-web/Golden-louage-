import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'station_data.dart';

final ValueNotifier<Locale> appLocale = ValueNotifier<Locale>(
  const Locale('ar'),
);

Future<void> changeAppLanguage(String languageCode) async {
  final code = languageCode == 'en' ? 'en' : 'ar';
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('app_language', code);
  appLocale.value = Locale(code);
}

Widget languageSwitch() {
  return ValueListenableBuilder<Locale>(
    valueListenable: appLocale,
    builder: (context, locale, child) {
      return TextButton(
        onPressed: () {
          changeAppLanguage(locale.languageCode == 'ar' ? 'en' : 'ar');
        },
        child: Text(
          locale.languageCode == 'ar' ? 'English' : 'العربية',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    },
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.android);

  final prefs = await SharedPreferences.getInstance();
  final savedLanguage = prefs.getString('app_language') ?? 'ar';
  appLocale.value = Locale(savedLanguage == 'en' ? 'en' : 'ar');

  runApp(const GoldenLouageApp());
}

class GoldenLouageApp extends StatelessWidget {
  const GoldenLouageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: appLocale,
      builder: (context, locale, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Golden Louage',
          locale: locale,
          supportedLocales: const [Locale('ar'), Locale('en')],
          builder: (context, child) {
            return Directionality(
              textDirection: locale.languageCode == 'ar'
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: child ?? const SizedBox.shrink(),
            );
          },
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFDAA520),
            ),
            fontFamily: 'Roboto',
          ),
          home: const PassengerHome(),
        );
      },
    );
  }
}

class PassengerHome extends StatefulWidget {
  const PassengerHome({super.key});

  @override
  State<PassengerHome> createState() => _PassengerHomeState();
}

class _PassengerHomeState extends State<PassengerHome> {
  List<StationOption> stations = [];
  String? originId;
  String? destinationId;
  bool stationsLoading = true;

  @override
  void initState() {
    super.initState();
    loadStations();
  }

  Future<void> loadStations() async {
    try {
      final loaded = await StationData.load();
      if (!mounted) return;
      setState(() {
        stations = loaded;
        stationsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => stationsLoading = false);
      showMessage('تعذر تحميل قائمة المحطات.');
    }
  }

  StationOption? findStation(String? id) {
    for (final station in stations) {
      if (station.id == id) return station;
    }
    return null;
  }

  Future<void> searchTrips() async {
    final selectedOrigin = findStation(originId);
    final selectedDestination = findStation(destinationId);

    if (selectedOrigin == null || selectedDestination == null) {
      showMessage('يرجى اختيار محطة الانطلاق والوصول');
      return;
    }

    if (selectedOrigin.id == selectedDestination.id) {
      showMessage('محطة الانطلاق والوصول لا يمكن أن تكونا متطابقتين');
      return;
    }

    final auth = FirebaseAuth.instance;

    if (auth.currentUser == null) {
      final loggedIn = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => const AccountScreen(createAccount: false),
        ),
      );

      if (!mounted || loggedIn != true) return;
    }

    try {
      final user = auth.currentUser;
      if (user == null) {
        showMessage('يرجى تسجيل الدخول أولاً');
        return;
      }

      final token = await user.getIdToken(true);
      final response = await http
          .get(
            Uri.parse(
              'https://workerv541js.dkhilislimhedi.workers.dev/passengers/me',
            ),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 25));

      final data = jsonDecode(response.body);

      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          data is! Map ||
          data['success'] != true ||
          data['passenger'] is! Map ||
          data['passenger']['role'] != 'passenger') {
        showMessage(
          data is Map
              ? data['error']?.toString() ?? 'تعذر التحقق من حساب المسافر'
              : 'استجابة غير صالحة من الخادم',
        );
        return;
      }

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SearchResultsScreen(
            origin: selectedOrigin.value,
            destination: selectedDestination.value,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        showMessage('تعذر التحقق من الحساب: $e');
      }
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: appLocale.value.languageCode == 'ar'
          ? TextDirection.rtl
          : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        appBar: AppBar(
          backgroundColor: const Color(0xFF173B32),
          foregroundColor: Colors.white,
          title: const Text(
            'Golden Louage',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          actions: [languageSwitch()],
        ),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const SizedBox(height: 15),
            const Icon(Icons.local_taxi, size: 75, color: Color(0xFFDAA520)),
            const SizedBox(height: 10),
            const Text(
              'رحلتك تبدأ من هنا',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
                color: Color(0xFF173B32),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'اعرف اللواج المتاحة واحجز مقعدك دون انتظار طويل',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Colors.black54),
            ),
            const SizedBox(height: 30),

            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'ابحث عن رحلتك',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),

                    if (stationsLoading)
                      const Center(child: CircularProgressIndicator())
                    else if (stations.isEmpty)
                      const Text('لا توجد محطات متاحة حالياً'),

                    if (!stationsLoading && stations.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        value: originId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'محطة الانطلاق',
                          prefixIcon: Icon(Icons.trip_origin),
                          border: OutlineInputBorder(),
                        ),
                        items: stations.map((station) {
                          return DropdownMenuItem<String>(
                            value: station.id,
                            child: Text(
                              station.label(appLocale.value.languageCode),
                            ),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() => originId = value);
                        },
                      ),

                      const SizedBox(height: 18),

                      DropdownButtonFormField<String>(
                        value: destinationId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'محطة الوصول',
                          prefixIcon: Icon(Icons.location_on),
                          border: OutlineInputBorder(),
                        ),
                        items: stations.map((station) {
                          return DropdownMenuItem<String>(
                            value: station.id,
                            child: Text(
                              station.label(appLocale.value.languageCode),
                            ),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() => destinationId = value);
                        },
                      ),
                    ],
                    const SizedBox(height: 22),

                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: searchTrips,
                        icon: const Icon(Icons.search),
                        label: const Text(
                          'البحث عن اللواج',
                          style: TextStyle(fontSize: 17),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF173B32),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 25),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'حساب المسافر',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                const AccountScreen(createAccount: true),
                          ),
                        );
                      },
                      child: const Text('الدخول أو إنشاء حساب'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Golden Louage',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black45,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SearchResultsScreen extends StatefulWidget {
  final String origin;
  final String destination;

  const SearchResultsScreen({
    super.key,
    required this.origin,
    required this.destination,
  });

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  static const String _apiUrl =
      'https://workerv541js.dkhilislimhedi.workers.dev';

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _trips = [];

  bool get _en => appLocale.value.languageCode == 'en';

  @override
  void initState() {
    super.initState();
    _loadTrips();
  }

  Future<void> _loadTrips() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        throw Exception(
          _en ? 'Please log in first.' : 'يرجى تسجيل الدخول أولاً.',
        );
      }

      final token = await user.getIdToken(true);
      if (token == null || token.isEmpty) {
        throw Exception(
          _en
              ? 'Could not obtain login token.'
              : 'تعذر الحصول على رمز تسجيل الدخول.',
        );
      }

      final uri = Uri.parse('$_apiUrl/trips').replace(
        queryParameters: {
          'origin': widget.origin,
          'destination': widget.destination,
        },
      );

      final response = await http
          .get(uri, headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body);

      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          data is! Map ||
          data['success'] != true ||
          data['trips'] is! List) {
        throw Exception(
          data is Map
              ? data['error']?.toString() ??
                    (_en ? 'Could not load trips.' : 'تعذر تحميل الرحلات.')
              : (_en
                    ? 'Invalid server response.'
                    : 'استجابة غير صالحة من الخادم.'),
        );
      }

      final trips = (data['trips'] as List)
          .whereType<Map>()
          .map((trip) => Map<String, dynamic>.from(trip))
          .toList();

      if (!mounted) return;

      setState(() {
        _trips = trips;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  String _field(Map<String, dynamic> trip, String key) {
    final value = trip[key]?.toString().trim();
    return value == null || value.isEmpty ? '-' : value;
  }

  List<int> _seatNumbers(dynamic value) {
    if (value is! List) return [];

    final numbers = value
        .map((item) => int.tryParse(item.toString()))
        .whereType<int>()
        .toList();

    numbers.sort();
    return numbers;
  }

  String _departureLabel(String value) {
    final date = DateTime.tryParse(value);
    if (date == null) return value;

    final local = date.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final year = local.year.toString();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');

    return '$day/$month/$year  $hour:$minute';
  }

  Widget _tripCard(Map<String, dynamic> trip) {
    final available = _seatNumbers(trip['availableSeatNumbers']);
    final registration = _field(trip, 'vehicleRegistration');
    final vehicleType = _field(trip, 'vehicleType');
    final driverName = _field(trip, 'driverName');
    final departure = _field(trip, 'departureAt');

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.route, color: Color(0xFFDAA520), size: 27),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${_field(trip, 'origin')} ← ${_field(trip, 'destination')}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF173B32),
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _detailRow(
              Icons.access_time,
              _en ? 'Departure' : 'موعد الانطلاق',
              _departureLabel(departure),
            ),
            _detailRow(Icons.person, _en ? 'Driver' : 'السائق', driverName),
            _detailRow(
              Icons.directions_car,
              _en ? 'Vehicle' : 'نوع السيارة',
              vehicleType,
            ),
            _detailRow(
              Icons.confirmation_number,
              _en ? 'Registration number' : 'رقم التسجيل',
              registration,
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.event_seat, color: Color(0xFF173B32)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _en
                        ? '${available.length} seats available'
                        : '${available.length} مقاعد متاحة',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (available.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: available.map((number) {
                  return Chip(
                    label: Text(number.toString()),
                    backgroundColor: const Color(0xFFE8F1EC),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 19, color: Colors.grey.shade700),
          const SizedBox(width: 9),
          Text('$label: '),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _en ? TextDirection.ltr : TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_en ? 'Trip results' : 'نتائج البحث'),
          backgroundColor: const Color(0xFF173B32),
          foregroundColor: Colors.white,
        ),
        body: RefreshIndicator(
          onRefresh: _loadTrips,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '${widget.origin} ← ${widget.destination}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF173B32),
                ),
              ),
              const SizedBox(height: 20),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(45),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null) ...[
                const Icon(Icons.error_outline, size: 55, color: Colors.red),
                const SizedBox(height: 12),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 15),
                Center(
                  child: ElevatedButton.icon(
                    onPressed: _loadTrips,
                    icon: const Icon(Icons.refresh),
                    label: Text(_en ? 'Retry' : 'إعادة المحاولة'),
                  ),
                ),
              ] else if (_trips.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(35),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.search_off,
                        size: 60,
                        color: Colors.grey,
                      ),
                      const SizedBox(height: 15),
                      Text(
                        _en
                            ? 'No available trips for this route.'
                            : 'لا توجد رحلات متاحة لهذا المسار حالياً.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 17),
                      ),
                    ],
                  ),
                )
              else ...[
                Text(
                  _en
                      ? '${_trips.length} available trips'
                      : 'عدد الرحلات المتاحة: ${_trips.length}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ..._trips.map(_tripCard),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AccountScreen extends StatefulWidget {
  final bool createAccount;

  const AccountScreen({super.key, required this.createAccount});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  static const String apiUrl =
      'https://workerv541js.dkhilislimhedi.workers.dev';

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  late bool _loginMode;
  bool _busy = false;
  String? _message;
  bool _success = false;

  @override
  void initState() {
    super.initState();
    _loginMode = !widget.createAccount;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _message = null;
    });

    final en = appLocale.value.languageCode == 'en';

    try {
      final auth = FirebaseAuth.instance;

      if (_loginMode) {
        final credential = await auth.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );

        final user = credential.user!;
        final token = await user.getIdToken(true);

        final response = await http
            .get(
              Uri.parse('$apiUrl/passengers/me'),
              headers: {'Authorization': 'Bearer $token'},
            )
            .timeout(const Duration(seconds: 25));

        final data = jsonDecode(response.body);

        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            data is! Map ||
            data['success'] != true ||
            data['passenger'] is! Map ||
            data['passenger']['role'] != 'passenger') {
          throw Exception(
            data is Map
                ? data['error'] ??
                      (en
                          ? 'Passenger profile verification failed.'
                          : 'تعذر التحقق من ملف الراكب.')
                : (en
                      ? 'Invalid server response.'
                      : 'استجابة غير صالحة من الخادم.'),
          );
        }
      } else {
        final email = _emailController.text.trim().toLowerCase();
        final currentUser = auth.currentUser;

        User user;
        if (currentUser != null) {
          if (currentUser.email?.toLowerCase() != email) {
            throw Exception(
              en
                  ? 'Another account is signed in. Please sign out first.'
                  : 'يوجد حساب آخر مفتوح. سجّل الخروج منه أولاً.',
            );
          }
          user = currentUser;
        } else {
          final credential = await auth.createUserWithEmailAndPassword(
            email: email,
            password: _passwordController.text,
          );
          user = credential.user!;
        }

        final token = await user.getIdToken(true);

        final response = await http
            .post(
              Uri.parse('$apiUrl/passengers/profile'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({
                'fullName': _nameController.text.trim(),
                'phone': _phoneController.text.trim(),
              }),
            )
            .timeout(const Duration(seconds: 25));

        final data = jsonDecode(response.body);

        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            data['success'] != true) {
          throw Exception(
            data['error'] ??
                (en
                    ? 'Could not create the passenger profile on the server.'
                    : 'تعذر إنشاء ملف الراكب في الخادم'),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _success = true;
        _message = _loginMode
            ? (en ? 'Login successful.' : 'تم تسجيل الدخول بنجاح.')
            : (en
                  ? 'Account and passenger profile created successfully.'
                  : 'تم إنشاء الحساب وملف الراكب بنجاح.');
      });

      if (_loginMode) {
        Navigator.pop(context, true);
      }
    } on FirebaseAuthException catch (e) {
      String message;

      switch (e.code) {
        case 'email-already-in-use':
          message = en
              ? 'This email address is already registered.'
              : 'هذا البريد الإلكتروني مسجل من قبل.';
          break;
        case 'invalid-email':
          message = en
              ? 'The email address is invalid.'
              : 'البريد الإلكتروني غير صحيح.';
          break;
        case 'weak-password':
          message = en
              ? 'Password is too weak. Use at least 6 characters.'
              : 'كلمة المرور ضعيفة. استعمل 6 أحرف على الأقل.';
          break;
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          message = en
              ? 'Incorrect email address or password.'
              : 'البريد الإلكتروني أو كلمة المرور غير صحيحة.';
          break;
        case 'network-request-failed':
          message = en
              ? 'Check your internet connection and try again.'
              : 'تحقق من اتصال الإنترنت وحاول مجدداً.';
          break;
        default:
          message = en
              ? 'Could not complete the operation: ${e.message ?? e.code}'
              : 'تعذر إتمام العملية: ${e.message ?? e.code}';
      }

      if (mounted) {
        setState(() {
          _success = false;
          _message = message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _success = false;
          _message = en ? 'Error: $e' : 'حدث خطأ: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = appLocale.value.languageCode == 'en';
    return Directionality(
      textDirection: appLocale.value.languageCode == 'ar'
          ? TextDirection.rtl
          : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(en ? 'Passenger Account' : 'حساب الراكب'),
          backgroundColor: const Color(0xFF173B32),
          foregroundColor: Colors.white,
          actions: [languageSwitch()],
        ),
        body: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            const Icon(
              Icons.account_circle,
              size: 75,
              color: Color(0xFFDAA520),
            ),
            const SizedBox(height: 15),
            Text(
              _loginMode
                  ? (en ? 'Log In' : 'تسجيل الدخول')
                  : (en ? 'Create Account' : 'إنشاء حساب جديد'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.bold,
                color: Color(0xFF173B32),
              ),
            ),
            const SizedBox(height: 22),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  if (!_loginMode) ...[
                    TextFormField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: en ? 'Full Name' : 'الاسم الكامل',
                        prefixIcon: Icon(Icons.person),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? en
                                ? 'Enter your full name'
                                : 'أدخل الاسم الكامل'
                          : null,
                    ),
                    const SizedBox(height: 15),
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: en ? 'Phone Number' : 'رقم الهاتف',
                        prefixIcon: Icon(Icons.phone),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? en
                                ? 'Enter your phone number'
                                : 'أدخل رقم الهاتف'
                          : null,
                    ),
                    const SizedBox(height: 15),
                  ],
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: en ? 'Email Address' : 'البريد الإلكتروني',
                      prefixIcon: Icon(Icons.email),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => v == null || !v.contains('@')
                        ? en
                              ? 'Enter a valid email address'
                              : 'أدخل بريداً إلكترونياً صحيحاً'
                        : null,
                  ),
                  const SizedBox(height: 15),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: en ? 'Password' : 'كلمة المرور',
                      prefixIcon: Icon(Icons.lock),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => v == null || v.length < 6
                        ? en
                              ? 'Password must be at least 6 characters'
                              : 'كلمة المرور يجب أن تكون 6 أحرف على الأقل'
                        : null,
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF173B32),
                        foregroundColor: Colors.white,
                      ),
                      child: _busy
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Text(
                              _loginMode
                                  ? (en ? 'Log In' : 'دخول')
                                  : (en ? 'Create Account' : 'إنشاء الحساب'),
                              style: const TextStyle(fontSize: 17),
                            ),
                    ),
                  ),
                ],
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 18),
              Text(
                _message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _success ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            const SizedBox(height: 15),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        _loginMode = !_loginMode;
                        _message = null;
                        _success = false;
                      });
                    },
              child: Text(
                _loginMode
                    ? en
                          ? 'Don’t have an account? Create one'
                          : 'ليس لديك حساب؟ أنشئ حساباً جديداً'
                    : en
                    ? 'Already have an account? Log in'
                    : 'لديك حساب بالفعل؟ سجل الدخول',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
