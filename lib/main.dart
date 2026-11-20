import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';
import 'dart:async';
import 'package:geolocator/geolocator.dart';

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
          home: const MainEntryScreen(),
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

  void _openMyBookings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PassengerBookingsScreen()),
    );
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
          actions: [
        IconButton(
          tooltip: appLocale == 'ar' ? 'حجوزاتي' : 'My bookings',
          icon: const Icon(Icons.confirmation_number_outlined),
          onPressed: _openMyBookings,
        ),
        languageSwitch(),
      ],
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
                        initialValue: originId,
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
                        initialValue: destinationId,
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


class PassengerBookingsScreen extends StatefulWidget {
  const PassengerBookingsScreen({super.key});

  @override
  State<PassengerBookingsScreen> createState() =>
      _PassengerBookingsScreenState();
}

class _PassengerBookingsScreenState extends State<PassengerBookingsScreen> {
  static const String _apiUrl =
      'https://workerv541js.dkhilislimhedi.workers.dev';

  List<dynamic> _bookings = [];
  bool _loading = true;
  String _message = '';
  Timer? _timer;
  String? _trackingTripId;
  String _locationText = '';


  Future<Map<String, dynamic>> _request(String method, String path) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) throw Exception('يلزم تسجيل الدخول');

    final uri = Uri.parse('$_apiUrl$path');
    final response = method == 'GET'
        ? await http.get(uri, headers: {'Authorization': 'Bearer $token'})
        : await http.post(uri, headers: {'Authorization': 'Bearer $token'});

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        data['success'] != true) {
      throw Exception(data['error'] ?? 'تعذر تنفيذ الطلب');
    }
    return data;
  }

  @override
  void initState() {
    super.initState();
    _loadBookings();
  }

  Future<void> _loadBookings() async {
    setState(() {
      _loading = true;
      _message = '';
    });
    try {
      final data = await _request('GET', '/bookings/mine');
      if (!mounted) return;
      setState(() {
        _bookings = (data['bookings'] as List?) ?? [];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadLocation(String tripId) async {
    try {
      final data = await _request('GET', '/trips/$tripId/location');
      if (!mounted || _trackingTripId != tripId) return;
      final location = data['location'];
      if (data['isLive'] == true && location is Map) {
        setState(() {
          _locationText =
              'خط العرض: ${location['latitude']}\\nخط الطول: ${location['longitude']}';
        });
      } else {
        setState(() => _locationText = 'موقع السائق غير متاح حالياً');
      }
    } catch (_) {
      if (mounted && _trackingTripId == tripId) {
        setState(() => _locationText = 'موقع السائق غير متاح حالياً');
      }
    }
  }

  void _track(String tripId) {
    _timer?.cancel();
    setState(() {
      _trackingTripId = tripId;
      _locationText = 'جارٍ جلب موقع السائق...';
    });
    _loadLocation(tripId);
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _loadLocation(tripId),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = appLocale == 'ar';
    return Scaffold(
      appBar: AppBar(
        title: Text(isArabic ? 'حجوزاتي' : 'My bookings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadBookings,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _message.isNotEmpty
              ? Center(child: Text(_message))
              : _bookings.isEmpty
                  ? Center(
                      child: Text(isArabic ? 'لا توجد حجوزات' : 'No bookings'),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _bookings.length,
                      itemBuilder: (context, index) {
                        final booking = _bookings[index]
                            as Map<String, dynamic>;
                        final status = booking['status']?.toString() ?? '';
                        final tripId = booking['tripId']?.toString() ?? '';
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${booking['origin'] ?? ''} ← ${booking['destination'] ?? ''}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  isArabic
                                      ? 'حالة الحجز: $status'
                                      : 'Booking status: $status',
                                ),
                                Text(
                                  isArabic
                                      ? 'رقم السيارة: ${booking['vehicleRegistration'] ?? 'غير متوفر'}'
                                      : 'Vehicle: ${booking['vehicleRegistration'] ?? 'Unavailable'}',
                                ),
                                if (status == 'confirmed' && tripId.isNotEmpty)
                                  TextButton.icon(
                                    onPressed: () => _track(tripId),
                                    icon: const Icon(Icons.location_on),
                                    label: Text(
                                      isArabic
                                          ? 'متابعة موقع السائق'
                                          : 'Track driver',
                                    ),
                                  ),
                                if (_trackingTripId == tripId &&
                                    _locationText.isNotEmpty)
                                  Text(_locationText),
                              ],
                            ),
                          ),
                        );
                      },
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

class MainEntryScreen extends StatelessWidget {
  const MainEntryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final en = appLocale.value.languageCode == 'en';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Golden Louage'),
        actions: [languageSwitch()],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.directions_bus,
                  size: 76,
                  color: Color(0xFFDAA520),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Golden Louage',
                  style: TextStyle(fontSize: 27, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 32),
                _entryButton(
                  context,
                  en ? 'Administration' : 'الإدارة',
                  Icons.admin_panel_settings,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RoleLoginScreen(isAdmin: true),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _entryButton(
                  context,
                  en ? 'Driver' : 'اللواج (السائق)',
                  Icons.directions_car,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RoleLoginScreen(isAdmin: false),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _entryButton(
                  context,
                  en ? 'Passenger' : 'المسافر',
                  Icons.person,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PassengerHome()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _entryButton(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback onPressed,
  ) {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label, style: const TextStyle(fontSize: 18)),
      ),
    );
  }
}

class RoleLoginScreen extends StatefulWidget {
  final bool isAdmin;

  const RoleLoginScreen({super.key, required this.isAdmin});

  @override
  State<RoleLoginScreen> createState() => _RoleLoginScreenState();
}

class _RoleLoginScreenState extends State<RoleLoginScreen> {
  static const String _apiUrl =
      'https://workerv541js.dkhilislimhedi.workers.dev';

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  String? _message;
  bool _success = false;

  bool get _en => appLocale.value.languageCode == 'en';

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _message = null;
      _success = false;
    });

    bool verified = false;

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );

      final token = await credential.user!.getIdToken(true);
      if (token == null || token.isEmpty) {
        throw Exception(
          _en
              ? 'Could not obtain login token.'
              : 'تعذر الحصول على رمز تسجيل الدخول.',
        );
      }

      final path = widget.isAdmin ? '/drivers' : '/drivers/me';
      final response = await http
          .get(
            Uri.parse('$_apiUrl$path'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 25));

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        throw Exception(
          _en ? 'Invalid server response.' : 'استجابة غير صالحة من الخادم.',
        );
      }

      if (decoded is! Map ||
          decoded['success'] != true ||
          response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          decoded is Map
              ? decoded['error']?.toString() ??
                    (_en
                        ? 'Account verification failed.'
                        : 'فشل التحقق من الحساب.')
              : (_en
                    ? 'Account verification failed.'
                    : 'فشل التحقق من الحساب.'),
        );
      }

      bool driverApproved = false;
      String result;

      if (widget.isAdmin) {
        if (decoded['drivers'] is! List) {
          throw Exception(
            _en
                ? 'This account is not an administrator.'
                : 'هذا الحساب لا يملك صلاحية الإدارة.',
          );
        }
        result = _en
            ? 'Administrator account verified successfully.'
            : 'تم التحقق من صلاحية الإدارة بنجاح.';
      } else {
        final driver = decoded['driver'];
        if (driver is! Map || driver['role'] != 'driver') {
          throw Exception(
            _en
                ? 'This account is not registered as a driver.'
                : 'هذا الحساب غير مسجل كسائق.',
          );
        }

        final status = driver['status']?.toString() ?? 'unknown';

        switch (status) {
          case 'approved':
            driverApproved = true;
            result = _en
                ? 'Your driver account is approved.'
                : 'حساب السائق معتمد.';
            break;
          case 'pending':
            result = _en
                ? 'Your application is waiting for approval.'
                : 'طلب انضمامك في انتظار موافقة الإدارة.';
            break;
          case 'rejected':
            result = _en
                ? 'Your driver application was rejected.'
                : 'تم رفض طلب انضمامك كسائق.';
            break;
          case 'suspended':
            result = _en
                ? 'Your driver account is suspended.'
                : 'اعتماد حسابك معلّق.';
            break;
          default:
            result = _en
                ? 'Driver status: $status'
                : 'حالة حساب السائق: $status';
        }
      }

      verified = true;
      if (!mounted) return;

      if (!widget.isAdmin && driverApproved) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DriverTripsScreen()),
        );
        return;
      }

      if (widget.isAdmin) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
        );
        return;
      }

      setState(() {
        _success = true;
        _message = result;
      });
    } catch (error) {
      if (!verified) {
        await FirebaseAuth.instance.signOut();
      }
      if (!mounted) return;
      setState(() {
        _success = false;
        _message = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isAdmin
        ? (_en ? 'Administrator login' : 'دخول الإدارة')
        : (_en ? 'Driver login' : 'دخول السائق');

    return Scaffold(
      appBar: AppBar(title: Text(title), actions: [languageSwitch()]),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  Icon(
                    widget.isAdmin
                        ? Icons.admin_panel_settings
                        : Icons.directions_car,
                    size: 65,
                    color: const Color(0xFFDAA520),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: _en ? 'Email' : 'البريد الإلكتروني',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || !value.contains('@')
                        ? (_en
                              ? 'Enter a valid email.'
                              : 'أدخل بريداً إلكترونياً صحيحاً.')
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: _en ? 'Password' : 'كلمة المرور',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || value.isEmpty
                        ? (_en ? 'Enter your password.' : 'أدخل كلمة المرور.')
                        : null,
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _busy ? null : _login,
                      child: _busy
                          ? const CircularProgressIndicator()
                          : Text(_en ? 'Log in' : 'تسجيل الدخول'),
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _success ? Colors.green : Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class DriverTripsScreen extends StatefulWidget {
  const DriverTripsScreen({super.key});

  @override
  State<DriverTripsScreen> createState() => _DriverTripsScreenState();
}

class _DriverTripsScreenState extends State<DriverTripsScreen> {
  static const String _apiUrl =
      'https://workerv541js.dkhilislimhedi.workers.dev';

  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;
  bool _busy = false;
  String? _message;
  Timer? _gpsTimer;
  String? _trackingTripId;

  bool get _en => appLocale.value.languageCode == 'en';

  @override
  void initState() {
    super.initState();
    _loadTrips();
  }

  @override
  void dispose() {
    _gpsTimer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception(_en ? 'Please sign in again.' : 'يرجى تسجيل الدخول مجدداً.');
    }

    final token = await user.getIdToken(true);
    if (token == null || token.isEmpty) {
      throw Exception(_en ? 'Login token unavailable.' : 'تعذر الحصول على رمز الدخول.');
    }

    final uri = Uri.parse('$_apiUrl$path');
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };

    final response = method == 'GET'
        ? await http.get(uri, headers: headers).timeout(const Duration(seconds: 25))
        : await http.post(
            uri,
            headers: headers,
            body: jsonEncode(body ?? <String, dynamic>{}),
          ).timeout(const Duration(seconds: 25));

    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw Exception(_en ? 'Invalid server response.' : 'استجابة الخادم غير صالحة.');
    }

    if (data is! Map ||
        data['success'] != true ||
        response.statusCode < 200 ||
        response.statusCode >= 300) {
      throw Exception(
        data is Map
            ? data['error']?.toString() ?? (_en ? 'Request failed.' : 'فشل الطلب.')
            : (_en ? 'Request failed.' : 'فشل الطلب.'),
      );
    }
    return Map<String, dynamic>.from(data);
  }

  String _tripId(Map<String, dynamic> trip) {
    return (trip['id'] ?? trip['tripId'] ?? trip['documentId'] ?? '').toString();
  }

  Future<void> _loadTrips() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _message = null;
      });
    }

    try {
      final data = await _request('GET', '/trips/mine');
      final raw = data['trips'];
      final trips = raw is List
          ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];

      if (!mounted) return;
      setState(() {
        _trips = trips;
        _loading = false;
      });

      final started = trips.where((t) => t['status'] == 'started').toList();
      if (started.isNotEmpty && _trackingTripId == null) {
        final id = _tripId(started.first);
        if (id.isNotEmpty) {
          await _startTracking(id);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception(_en ? 'Please enable GPS.' : 'يرجى تشغيل GPS.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception(_en
          ? 'Location permission is required.'
          : 'يلزم السماح للتطبيق بالوصول إلى الموقع.');
    }
    return true;
  }

  Future<void> _sendLocation(String tripId) async {
    try {
      await _ensureLocationPermission();
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      await _request(
        'POST',
        '/trips/${Uri.encodeComponent(tripId)}/location',
        body: {
          'latitude': position.latitude,
          'longitude': position.longitude,
        },
      );

      if (mounted) {
        setState(() {
          _message = _en
              ? 'Live location updated.'
              : 'تم تحديث الموقع بنجاح.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = (_en ? 'GPS unavailable: ' : 'الموقع غير متاح: ') +
              e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _startTracking(String tripId) async {
    _gpsTimer?.cancel();
    _trackingTripId = tripId;

    await _sendLocation(tripId);
    if (!mounted || _trackingTripId != tripId) return;

    if (_gpsTimer == null) {
      _gpsTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (_trackingTripId == tripId) {
          _sendLocation(tripId);
        }
      });
    }
  }

  Future<void> _startTrip(String tripId) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await _request('POST', '/trips/${Uri.encodeComponent(tripId)}/start');
      await _startTracking(tripId);
      await _loadTrips();
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeTrip(String tripId) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await _request('POST', '/trips/${Uri.encodeComponent(tripId)}/complete');
      _gpsTimer?.cancel();
      _gpsTimer = null;
      _trackingTripId = null;
      if (mounted) {
        setState(() {
          _message = _en ? 'Trip completed.' : 'تم إكمال الرحلة وإيقاف GPS.';
        });
      }
      await _loadTrips();
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusLabel(dynamic status) {
    switch (status?.toString()) {
      case 'open':
        return _en ? 'Open' : 'مفتوحة';
      case 'scheduled':
        return _en ? 'Scheduled' : 'مبرمجة';
      case 'started':
        return _en ? 'Started' : 'انطلقت';
      case 'completed':
        return _en ? 'Completed' : 'مكتملة';
      case 'cancelled':
        return _en ? 'Cancelled' : 'ملغاة';
      default:
        return status?.toString() ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = _en;

    return Scaffold(
      appBar: AppBar(
        title: Text(en ? 'My trips' : 'رحلاتي'),
        actions: [
          IconButton(
            onPressed: _loadTrips,
            icon: const Icon(Icons.refresh),
          ),
          languageSwitch(),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadTrips,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _message!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  if (_trips.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        en ? 'No trips found.' : 'لا توجد رحلات.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ..._trips.map((trip) {
                    final id = _tripId(trip);
                    final status = trip['status']?.toString();
                    final origin = trip['origin']?.toString() ?? '';
                    final destination = trip['destination']?.toString() ?? '';
                    final registration =
                        trip['vehicleRegistration']?.toString() ??
                        trip['registrationNumber']?.toString() ??
                        '';

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$origin  ←  $destination',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text('${en ? 'Status' : 'الحالة'}: ${_statusLabel(status)}'),
                            if (registration.isNotEmpty)
                              Text('${en ? 'Vehicle' : 'السيارة'}: $registration'),
                            if (trip['departureAt'] != null)
                              Text('${en ? 'Departure' : 'موعد الانطلاق'}: ${trip['departureAt']}'),
                            const SizedBox(height: 12),
                            if (status == 'open' || status == 'scheduled')
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _busy || id.isEmpty
                                      ? null
                                      : () => _startTrip(id),
                                  icon: const Icon(Icons.play_arrow),
                                  label: Text(en ? 'Start trip' : 'بدء الرحلة'),
                                ),
                              ),
                            if (status == 'started')
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _busy || id.isEmpty
                                      ? null
                                      : () => _completeTrip(id),
                                  icon: const Icon(Icons.flag),
                                  label: Text(en ? 'Complete trip' : 'إكمال الرحلة'),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
    );
  }
}

class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key});

  static const List<_AdminSectionItem> _sections = [
    _AdminSectionItem('السفريات', 'Trips', Icons.route),
    _AdminSectionItem(
      'السائقون المعتمدون',
      'Approved drivers',
      Icons.verified_user,
    ),
    _AdminSectionItem(
      'السائقون المنتظرون للموافقة',
      'Pending drivers',
      Icons.hourglass_top,
    ),
    _AdminSectionItem(
      'السائقون المرفوضون',
      'Rejected drivers',
      Icons.person_off,
    ),
    _AdminSectionItem(
      'السائقون المعلّقون',
      'Suspended drivers',
      Icons.pause_circle,
    ),
    _AdminSectionItem('إدارة السيارات', 'Vehicles', Icons.directions_car),
    _AdminSectionItem(
      'طلبات إيقاف السائقين',
      'Driver stop requests',
      Icons.pause_circle,
    ),
    _AdminSectionItem('الرحلات الجارية', 'Ongoing trips', Icons.directions_bus),
    _AdminSectionItem('الرحلات المنجزة', 'Completed trips', Icons.task_alt),
    _AdminSectionItem('الرحلات الموقوفة', 'Stopped trips', Icons.stop_circle),
    _AdminSectionItem('المسافرون', 'Passengers', Icons.people),
  ];

  @override
  Widget build(BuildContext context) {
    final en = appLocale.value.languageCode == 'en';

    return Scaffold(
      appBar: AppBar(
        title: Text(en ? 'Administration' : 'لوحة الإدارة'),
        actions: [
          languageSwitch(),
          IconButton(
            tooltip: en ? 'Log out' : 'تسجيل الخروج',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (!context.mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const MainEntryScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _sections.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.25,
        ),
        itemBuilder: (context, index) {
          final section = _sections[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        AdminSectionScreen(title: en ? section.en : section.ar),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      section.icon,
                      size: 34,
                      color: const Color(0xFFDAA520),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      en ? section.en : section.ar,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AdminSectionItem {
  final String ar;
  final String en;
  final IconData icon;

  const _AdminSectionItem(this.ar, this.en, this.icon);
}

class AdminSectionScreen extends StatefulWidget {
  final String title;
  const AdminSectionScreen({super.key, required this.title});

  @override
  State<AdminSectionScreen> createState() => _AdminSectionScreenState();
}

class _AdminSectionScreenState extends State<AdminSectionScreen> {
  static const String _apiUrl =
      'https://workerv541js.dkhilislimhedi.workers.dev';

  bool get _en => appLocale.value.languageCode == 'en';
  bool get _pending =>
      widget.title == 'السائقون المنتظرون للموافقة' ||
      widget.title == 'Pending drivers';

  String? get _driverStatus {
    final title = widget.title;
    if (title == 'السائقون المعتمدون' || title == 'Approved drivers') {
      return 'approved';
    }
    if (title == 'السائقون المرفوضون' || title == 'Rejected drivers') {
      return 'rejected';
    }
    if (title == 'السائقون المعلّقون' ||
        title == 'السائقون المعلقون' ||
        title == 'Suspended drivers') {
      return 'suspended';
    }
    return null;
  }

  bool get _driverList => _driverStatus != null;

  bool get _tripSection =>
      widget.title == 'السفريات' ||
      widget.title == 'Trips' ||
      widget.title == 'الرحلات الجارية' ||
      widget.title == 'Ongoing trips' ||
      widget.title == 'الرحلات المنجزة' ||
      widget.title == 'Completed trips' ||
      widget.title == 'الرحلات الموقوفة' ||
      widget.title == 'Stopped trips';

  String? get _tripStatus {
    if (widget.title == 'الرحلات الجارية' || widget.title == 'Ongoing trips') {
      return 'started';
    }
    if (widget.title == 'الرحلات المنجزة' ||
        widget.title == 'Completed trips') {
      return 'completed';
    }
    if (widget.title == 'الرحلات الموقوفة' || widget.title == 'Stopped trips') {
      return 'cancelled';
    }
    return null;
  }

  bool get _vehicleSection =>
      widget.title == 'إدارة السيارات' || widget.title == 'Vehicles';

  bool get _driverStopRequestsSection =>
      widget.title == 'طلبات إيقاف السائقين' ||
      widget.title == 'Driver stop requests';

  bool _loading = true;
  String? _error;
  List<dynamic> _applications = [];

  @override
  void initState() {
    super.initState();
    if (_pending ||
        _driverList ||
        _tripSection ||
        _vehicleSection ||
        _driverStopRequestsSection) {
      _load();
    } else {
      _loading = false;
    }
  }

  Future<Map<String, dynamic>> _request(String method, String path) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception(
        _en ? 'Please sign in again.' : 'يرجى تسجيل الدخول مجدداً.',
      );
    }
    final token = await user.getIdToken(true);
    if (token == null || token.isEmpty) {
      throw Exception(
        _en ? 'Login token unavailable.' : 'تعذر الحصول على رمز الدخول.',
      );
    }

    final uri = Uri.parse('$_apiUrl$path');
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };

    final response = method == 'GET'
        ? await http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 25))
        : await http
              .post(
                uri,
                headers: headers,
                body: jsonEncode(<String, dynamic>{}),
              )
              .timeout(const Duration(seconds: 25));

    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw Exception(
        _en ? 'Invalid server response.' : 'استجابة الخادم غير صالحة.',
      );
    }

    if (data is! Map ||
        data['success'] != true ||
        response.statusCode < 200 ||
        response.statusCode >= 300) {
      throw Exception(
        data is Map
            ? data['error']?.toString() ??
                  (_en ? 'Request failed.' : 'فشل الطلب.')
            : (_en ? 'Request failed.' : 'فشل الطلب.'),
      );
    }
    return Map<String, dynamic>.from(data);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final isDriverList = _driverList;
      final data = await _request(
        'GET',
        _tripSection
            ? '/admin/trips'
            : (_driverStopRequestsSection
                  ? '/admin/driver-stop-requests'
                  : (_vehicleSection
                        ? '/admin/vehicles'
                        : (isDriverList
                              ? '/drivers'
                              : '/drivers/applications'))),
      );
      final key = _tripSection
          ? 'trips'
          : (_driverStopRequestsSection
                ? 'requests'
                : (_vehicleSection
                      ? 'vehicles'
                      : (isDriverList ? 'drivers' : 'applications')));
      if (data[key] is! List) {
        throw Exception(
          _en ? 'Invalid server list.' : 'قائمة الخادم غير صالحة.',
        );
      }

      final items = (data[key] as List).where((raw) {
        if (raw is! Map) return false;
        if (_tripSection) {
          return _tripStatus == null ||
              raw['status']?.toString().toLowerCase() == _tripStatus;
        }
        if (_vehicleSection || _driverStopRequestsSection) return true;
        if (!isDriverList) return true;
        return raw['status']?.toString().toLowerCase() == _driverStatus;
      }).toList();

      if (!mounted) return;
      setState(() {
        _applications = items;
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

  String _id(Map item) {
    for (final key in ['id', 'requestId', 'uid', 'userId']) {
      final value = item[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _name(Map item) {
    for (final key in [
      'driverName',
      'fullName',
      'name',
      'displayName',
      'username',
      'email',
    ]) {
      final value = item[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return _en ? 'Driver application' : 'طلب سائق';
  }

  Future<void> _decide(Map item, bool approve) async {
    final id = _id(item);
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _en
                ? 'Driver ID is missing.'
                : 'معرّف السائق غير موجود في بيانات الخادم.',
          ),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          approve
              ? (_en ? 'Approve driver?' : 'قبول السائق؟')
              : (_en ? 'Reject application?' : 'رفض الطلب؟'),
        ),
        content: Text(_name(item)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_en ? 'Cancel' : 'إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              approve ? (_en ? 'Approve' : 'قبول') : (_en ? 'Reject' : 'رفض'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _request('POST', '/drivers/$id/${approve ? 'approve' : 'reject'}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve
                ? (_en ? 'Driver approved.' : 'تمت الموافقة على السائق.')
                : (_en ? 'Application rejected.' : 'تم رفض الطلب.'),
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _approveDriverStopRequest(Map item) async {
    final id = _id(item);
    if (id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          _en ? 'Approve driver stop request?' : 'الموافقة على إيقاف السائق؟',
        ),
        content: Text(_name(item)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_en ? 'Cancel' : 'إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_en ? 'Approve and execute' : 'الموافقة والتنفيذ'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _request('POST', '/admin/driver-stop-requests/$id/approve');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _en
                ? 'Driver stop request executed.'
                : 'تم تنفيذ طلب إيقاف السائق.',
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _suspendDriver(Map item) async {
    final id = _id(item);
    if (id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_en ? 'Suspend this driver?' : 'تعليق اعتماد هذا السائق؟'),
        content: Text(_name(item)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_en ? 'Cancel' : 'إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_en ? 'Suspend' : 'تعليق'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _request('POST', '/drivers/$id/suspend');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_en ? 'Driver suspended.' : 'تم تعليق اعتماد السائق.'),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _vehicleAction(Map item, String action) async {
    final id = _id(item);
    if (id.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          action == 'approve'
              ? (_en ? 'Approve vehicle?' : 'الموافقة على السيارة؟')
              : action == 'reject'
              ? (_en ? 'Reject vehicle?' : 'رفض السيارة؟')
              : (_en ? 'Suspend vehicle?' : 'تعليق السيارة؟'),
        ),
        content: Text(
          '${item['registrationNumber'] ?? item['plateNumber'] ?? ''}\n'
          '${item['vehicleType'] ?? item['type'] ?? ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_en ? 'Cancel' : 'إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_en ? 'Confirm' : 'تأكيد'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _request('POST', '/admin/vehicles/$id/$action');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_en ? 'Vehicle updated.' : 'تم تحديث حالة السيارة.'),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_pending &&
        !_driverList &&
        !_tripSection &&
        !_vehicleSection &&
        !_driverStopRequestsSection) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title), actions: [languageSwitch()]),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _en
                  ? 'This section has not been connected to the server yet.'
                  : 'هذا القسم لم يُربط بالخادم بعد.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          languageSwitch(),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                  FilledButton(
                    onPressed: _load,
                    child: Text(_en ? 'Retry' : 'إعادة المحاولة'),
                  ),
                ],
              ),
            )
          : _applications.isEmpty
          ? Center(
              child: Text(
                _tripSection
                    ? (_en
                          ? 'No trips in this list.'
                          : 'لا توجد رحلات في هذه القائمة.')
                    : _vehicleSection
                    ? (_en
                          ? 'No vehicles in this list.'
                          : 'لا توجد سيارات في هذه القائمة.')
                    : _driverStopRequestsSection
                    ? (_en
                          ? 'No pending stop requests.'
                          : 'لا توجد طلبات إيقاف معلقة.')
                    : _en
                    ? (_pending
                          ? 'No pending driver applications.'
                          : 'No drivers in this list.')
                    : (_pending
                          ? 'لا توجد طلبات سائقين في الانتظار.'
                          : 'لا يوجد سائقون في هذه القائمة.'),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _applications.length,
                itemBuilder: (context, index) {
                  final raw = _applications[index];
                  if (raw is! Map) return const SizedBox.shrink();
                  final item = Map<String, dynamic>.from(raw);
                  final id = _id(item);

                  if (_tripSection) {
                    final status = (item['status'] ?? '')
                        .toString()
                        .toLowerCase();
                    final driverName = (item['driverName'] ?? '')
                        .toString()
                        .trim();
                    final registration = (item['vehicleRegistration'] ?? '')
                        .toString()
                        .trim();
                    final vehicleType = (item['vehicleType'] ?? '')
                        .toString()
                        .trim();
                    final origin = (item['origin'] ?? '').toString().trim();
                    final destination = (item['destination'] ?? '')
                        .toString()
                        .trim();
                    final departureAt = (item['departureAt'] ?? '')
                        .toString()
                        .trim();
                    final occupied = item['occupiedSeatNumbers'] is List
                        ? (item['occupiedSeatNumbers'] as List).length
                        : 0;
                    final available = item['availableSeatNumbers'] is List
                        ? (item['availableSeatNumbers'] as List).length
                        : 0;
                    final statusLabel = status == 'open'
                        ? (_en ? 'Open' : 'مفتوحة')
                        : status == 'scheduled'
                        ? (_en ? 'Scheduled' : 'مجدولة')
                        : status == 'started'
                        ? (_en ? 'Ongoing' : 'جارية')
                        : status == 'completed'
                        ? (_en ? 'Completed' : 'منجزة')
                        : status == 'cancelled'
                        ? (_en ? 'Stopped / cancelled' : 'موقوفة / ملغاة')
                        : status;

                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_en ? 'Trip' : 'رحلة'}: $id',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            if (driverName.isNotEmpty)
                              Text('${_en ? 'Driver' : 'السائق'}: $driverName'),
                            Text(
                              '${_en ? 'Vehicle registration' : 'الرقم المنجمي'}: ${registration.isEmpty ? (_en ? 'Unavailable' : 'غير متوفر') : registration}',
                            ),
                            if (vehicleType.isNotEmpty)
                              Text(
                                '${_en ? 'Vehicle type' : 'نوع السيارة'}: $vehicleType',
                              ),
                            Text(
                              '${_en ? 'Route' : 'المسار'}: ${origin.isEmpty ? '—' : origin} → ${destination.isEmpty ? '—' : destination}',
                            ),
                            if (departureAt.isNotEmpty)
                              Text(
                                '${_en ? 'Departure' : 'موعد الانطلاق'}: $departureAt',
                              ),
                            Text('${_en ? 'Status' : 'الحالة'}: $statusLabel'),
                            Text(
                              '${_en ? 'Occupied seats' : 'المقاعد المشغولة'}: $occupied / 8',
                            ),
                            Text(
                              '${_en ? 'Available seats' : 'المقاعد المتاحة'}: $available / 8',
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (_driverStopRequestsSection) {
                    final reason = (item['reason'] ?? '').toString().trim();
                    final createdAt = (item['createdAt'] ?? '')
                        .toString()
                        .trim();

                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _name(item),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (reason.isNotEmpty)
                              Text('${_en ? 'Reason' : 'السبب'}: $reason'),
                            if (createdAt.isNotEmpty)
                              Text(
                                '${_en ? 'Request date' : 'تاريخ الطلب'}: $createdAt',
                              ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => _approveDriverStopRequest(item),
                                icon: const Icon(Icons.check_circle),
                                label: Text(
                                  _en
                                      ? 'Approve and execute'
                                      : 'الموافقة والتنفيذ',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (_vehicleSection) {
                    final status = item['status']?.toString() ?? '';
                    final registration =
                        (item['registrationNumber'] ??
                                item['plateNumber'] ??
                                item['registration'] ??
                                '')
                            .toString();
                    final vehicleType =
                        (item['vehicleType'] ?? item['type'] ?? '').toString();

                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              registration.isEmpty
                                  ? (_en
                                        ? 'Registration unavailable'
                                        : 'الرقم المنجمي غير متوفر')
                                  : registration,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (vehicleType.isNotEmpty) Text(vehicleType),
                            Text('${_en ? 'Status' : 'الحالة'}: $status'),
                            if (status == 'pending')
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton(
                                      onPressed: id.isEmpty
                                          ? null
                                          : () =>
                                                _vehicleAction(item, 'approve'),
                                      child: Text(_en ? 'Approve' : 'موافقة'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: id.isEmpty
                                          ? null
                                          : () =>
                                                _vehicleAction(item, 'reject'),
                                      child: Text(_en ? 'Reject' : 'رفض'),
                                    ),
                                  ),
                                ],
                              ),
                            if (status == 'approved')
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: id.isEmpty
                                      ? null
                                      : () => _vehicleAction(item, 'suspend'),
                                  icon: const Icon(Icons.block),
                                  label: Text(
                                    _en ? 'Suspend vehicle' : 'تعليق السيارة',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }

                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _name(item),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if ((item['email']?.toString() ?? '').isNotEmpty)
                            Text(item['email'].toString()),
                          if ((item['phone']?.toString() ?? '').isNotEmpty)
                            Text(item['phone'].toString()),
                          const SizedBox(height: 12),
                          if (_pending) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: id.isEmpty
                                        ? null
                                        : () => _decide(item, true),
                                    icon: const Icon(Icons.check),
                                    label: Text(_en ? 'Approve' : 'قبول'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: id.isEmpty
                                        ? null
                                        : () => _decide(item, false),
                                    icon: const Icon(Icons.close),
                                    label: Text(_en ? 'Reject' : 'رفض'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (_driverStatus == 'approved')
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: id.isEmpty
                                    ? null
                                    : () => _suspendDriver(item),
                                icon: const Icon(Icons.block),
                                label: Text(
                                  _en
                                      ? 'Suspend driver'
                                      : 'تعليق اعتماد السائق',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
