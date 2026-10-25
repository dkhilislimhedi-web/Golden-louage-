
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
    runApp(const GoldenLouageApp());
  } catch (e) {
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'تعذر الاتصال بـ Firebase:\n$e',
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ));
  }
}

class GoldenLouageApp extends StatelessWidget {
  const GoldenLouageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Golden louage',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textDirection: TextDirection.rtl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Golden louage'),
          centerTitle: true,
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.directions_bus,
                  size: 80,
                  color: Colors.amber,
                ),
                const SizedBox(height: 16),
                const Text(
                  'مرحبا بك في Golden louage',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.event_seat),
                    label: const Text('احجز مقعد'),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const BookingPage(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.list_alt),
                    label: const Text('رحلاتي وحجوزاتي'),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const MyBookingsPage(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.verified_user),
                    label: const Text('موافقة صاحب اللواج'),
                    onPressed: () => showMessage(
                      context,
                      'يلزم إعداد حساب السائق وصلاحياته.',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.location_on),
                    label: const Text('تتبّع اللواج'),
                    onPressed: () => showMessage(
                      context,
                      'خاصية التتبّع GPS لم تُفعّل بعد.',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BookingPage extends StatefulWidget {
  const BookingPage({super.key});

  @override
  State<BookingPage> createState() => _BookingPageState();
}

class _BookingPageState extends State<BookingPage> {
  final _formKey = GlobalKey<FormState>();
  final _departure = TextEditingController();
  final _destination = TextEditingController();

  DateTime? _travelDate;
  TimeOfDay? _travelTime;
  int? _seat;
  bool _saving = false;

  Future<void> _chooseDate() async {
    final now = DateTime.now();

    final date = await showDatePicker(
      context: context,
      initialDate: _travelDate ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: 'اختر تاريخ السفر',
      cancelText: 'إلغاء',
      confirmText: 'تأكيد',
    );

    if (date != null) {
      setState(() => _travelDate = date);
    }
  }

  Future<void> _chooseTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _travelTime ?? TimeOfDay.now(),
      helpText: 'اختر وقت السفر',
      cancelText: 'إلغاء',
      confirmText: 'تأكيد',
    );

    if (time != null) {
      setState(() => _travelTime = time);
    }
  }

  String get _dateText {
    if (_travelDate == null) return 'اختر تاريخ السفر';
    final d = _travelDate!;
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String get _timeText {
    if (_travelTime == null) return 'اختر وقت السفر';
    final t = _travelTime!;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _submitBooking() async {
    if (!_formKey.currentState!.validate()) return;

    if (_travelDate == null ||
        _travelTime == null ||
        _seat == null) {
      _showMessage('يرجى اختيار التاريخ والوقت والمقعد.');
      return;
    }

    if (_departure.text.trim().toLowerCase() ==
        _destination.text.trim().toLowerCase()) {
      _showMessage('مدينة الانطلاق والوصول يجب أن تكونا مختلفتين.');
      return;
    }

    setState(() => _saving = true);

    try {
      await FirebaseFirestore.instance
          .collection('booking_requests')
          .add({
        'departure': _departure.text.trim(),
        'destination': _destination.text.trim(),
        'travelDate':
            '${_travelDate!.year}-'
            '${_travelDate!.month.toString().padLeft(2, '0')}-'
            '${_travelDate!.day.toString().padLeft(2, '0')}',
        'travelTime': _timeText,
        'seat': _seat,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      _showMessage(
        'تم إرسال طلب الحجز وهو في انتظار موافقة صاحب اللواج.',
      );
      Navigator.pop(context);
    } on FirebaseException catch (e) {
      if (!mounted) return;

      if (e.code == 'permission-denied') {
        _showMessage(
          'قاعدة البيانات تمنع الحفظ حاليًا. '
          'يلزم إعداد قواعد Firestore بأمان.',
        );
      } else {
        _showMessage('تعذر حفظ الحجز: ${e.message ?? e.code}');
      }
    } catch (e) {
      if (mounted) _showMessage('حدث خطأ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textDirection: TextDirection.rtl),
      ),
    );
  }

  @override
  void dispose() {
    _departure.dispose();
    _destination.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('احجز مقعدك')),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _departure,
                  decoration: const InputDecoration(
                    labelText: 'مدينة الانطلاق',
                    prefixIcon: Icon(Icons.trip_origin),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? 'أدخل مدينة الانطلاق'
                          : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _destination,
                  decoration: const InputDecoration(
                    labelText: 'مدينة الوصول',
                    prefixIcon: Icon(Icons.location_on),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? 'أدخل مدينة الوصول'
                          : null,
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _chooseDate,
                  icon: const Icon(Icons.calendar_month),
                  label: Text(_dateText),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _chooseTime,
                  icon: const Icon(Icons.access_time),
                  label: Text(_timeText),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  value: _seat,
                  decoration: const InputDecoration(
                    labelText: 'المقعد',
                    prefixIcon: Icon(Icons.event_seat),
                    border: OutlineInputBorder(),
                  ),
                  items: List.generate(
                    8,
                    (i) => DropdownMenuItem<int>(
                      value: i + 1,
                      child: Text('المقعد ${i + 1}'),
                    ),
                  ),
                  onChanged: (value) => setState(() => _seat = value),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _saving ? null : _submitBooking,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.check),
                  label: Text(_saving ? 'جارٍ الحفظ...' : 'إحجز'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyBookingsPage extends StatelessWidget {
  const MyBookingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('رحلاتي وحجوزاتي')),
      body: const Directionality(
        textDirection: TextDirection.rtl,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'عرض الحجوزات الشخصية يتطلب تسجيل الدخول '
              'وربط كل حجز بحساب صاحبه.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
