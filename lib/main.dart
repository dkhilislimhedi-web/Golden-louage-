
import 'package:flutter/material.dart';

void main() {
  runApp(const GoldenLouageApp());
}

class GoldenLouageApp extends StatelessWidget {
  const GoldenLouageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Golden louage',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Golden louage',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: Colors.amber,
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 15),
            const Icon(
              Icons.airport_shuttle,
              size: 85,
              color: Colors.amber,
            ),
            const SizedBox(height: 12),
            const Text(
              'مرحبا بيك في Golden louage',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'رحلتك تبدأ من هنا',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 30),
            _menuCard(
              context,
              Icons.event_seat,
              'احجز مقعدك',
              'اختار وجهتك وموعد سفرك',
              () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const BookingPage(),
                  ),
                );
              },
            ),
            _menuCard(
              context,
              Icons.confirmation_number,
              'رحلاتي وحجوزاتي',
              'تابع حالة طلبات الحجز',
              () {
                _showMessage(
                  context,
                  'ستظهر حجوزاتك هنا بعد تطوير نظام الحجز.',
                );
              },
            ),
            _menuCard(
              context,
              Icons.check_circle_outline,
              'موافقة سائق اللواج',
              'الحجز يتأكد بعد موافقة السائق',
              () {
                _showMessage(
                  context,
                  'سيتم ربط موافقة السائق بنظام الحجز لاحقًا.',
                );
              },
            ),
            _menuCard(
              context,
              Icons.location_on,
              'تتبّع اللواج',
              'تابع موقع اللواج على الخريطة',
              () {
                _showMessage(
                  context,
                  'سيتم تفعيل التتبّع بعد ربط GPS.',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static Widget _menuCard(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, size: 32, color: Colors.amber[800]),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_left),
        onTap: onTap,
      ),
    );
  }

  static void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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
  final _departureController = TextEditingController();
  final _destinationController = TextEditingController();

  String _seat = '1';
  DateTime? _travelDate;

  @override
  void dispose() {
    _departureController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('طلب حجز مقعد'),
        backgroundColor: Colors.amber,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'معلومات الرحلة',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _departureController,
              decoration: const InputDecoration(
                labelText: 'مدينة الانطلاق',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.trip_origin),
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty
                      ? 'اكتب مدينة الانطلاق'
                      : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _destinationController,
              decoration: const InputDecoration(
                labelText: 'مدينة الوصول',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.location_on),
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty
                      ? 'اكتب مدينة الوصول'
                      : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _seat,
              decoration: const InputDecoration(
                labelText: 'رقم المقعد',
                border: OutlineInputBorder(),
              ),
              items: List.generate(
                8,
                (index) => DropdownMenuItem(
                  value: '${index + 1}',
                  child: Text('المقعد ${index + 1}'),
                ),
              ),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _seat = value);
                }
              },
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_month),
              label: Text(
                _travelDate == null
                    ? 'اختار تاريخ السفر'
                    : '${_travelDate!.day}/${_travelDate!.month}/${_travelDate!.year}',
              ),
              onPressed: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now(),
                  firstDate: DateTime.now(),
                  lastDate: DateTime.now().add(
                    const Duration(days: 365),
                  ),
                );
                if (date != null) {
                  setState(() => _travelDate = date);
                }
              },
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.send),
              label: const Text('إرسال طلب الحجز'),
              onPressed: () {
                if (!_formKey.currentState!.validate()) return;

                if (_departureController.text.trim().toLowerCase() ==
                    _destinationController.text.trim().toLowerCase()) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'مدينة الانطلاق والوصول لازم يكونوا مختلفين',
                      ),
                    ),
                  );
                  return;
                }

                if (_travelDate == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('اختار تاريخ السفر أولًا'),
                    ),
                  );
                  return;
                }

                showDialog(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('طلب الحجز'),
                    content: Text(
                      'من ${_departureController.text.trim()} '
                      'إلى ${_destinationController.text.trim()}\n'
                      'المقعد: $_seat\n'
                      'التاريخ: ${_travelDate!.day}/'
                      '${_travelDate!.month}/${_travelDate!.year}\n\n'
                      'هذه معاينة للطلب فقط. يلزم ربط التطبيق بقاعدة بيانات '
                      'ونظام السائق لإرسال الطلب وتأكيده فعليًا.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            Navigator.pop(dialogContext),
                        child: const Text('حسنًا'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
