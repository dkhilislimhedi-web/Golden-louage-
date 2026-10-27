
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const GoldenLouageApp());
}

final db = FirebaseFirestore.instance;
final auth = FirebaseAuth.instance;

class GoldenLouageApp extends StatelessWidget {
  const GoldenLouageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Golden louage',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

void message(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text)),
  );
}

String errorText(Object e) {
  if (e is FirebaseAuthException) {
    switch (e.code) {
      case 'weak-password':
        return 'كلمة السر يجب أن تكون 6 أحرف على الأقل.';
      case 'email-already-in-use':
        return 'هذا الإيميل مسجّل من قبل.';
      case 'invalid-email':
        return 'الإيميل غير صحيح.';
      case 'invalid-credential':
        return 'الإيميل أو كلمة السر غير صحيحة.';
      case 'user-disabled':
        return 'هذا الحساب معطّل.';
    }
  }
  if (e is FirebaseException) {
    if (e.code == 'permission-denied') {
      return 'العملية مرفوضة بسبب قواعد الأمان. سنراجع قواعد Firestore.';
    }
    return 'خطأ في Firebase: ${e.message ?? e.code}';
  }
  return 'حدث خطأ. تحقق من اتصال الإنترنت وحاول مجددًا.';
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: auth.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LoadingPage();
        }
        if (snapshot.data == null) return const LoginPage();
        return const AccountGate();
      },
    );
  }
}

class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool registering = false;
  bool busy = false;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (email.text.trim().isEmpty || password.text.isEmpty) {
      message(context, 'أدخل الإيميل وكلمة السر.');
      return;
    }
    setState(() => busy = true);
    try {
      if (registering) {
        await auth.createUserWithEmailAndPassword(
          email: email.text.trim(),
          password: password.text,
        );
      } else {
        await auth.signInWithEmailAndPassword(
          email: email.text.trim(),
          password: password.text,
        );
      }
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Golden louage')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.directions_bus, size: 76),
              const SizedBox(height: 16),
              const Text(
                'مرحبًا بك في Golden louage',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'الإيميل'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'كلمة السر'),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(
                  busy
                      ? 'يرجى الانتظار...'
                      : registering
                          ? 'إنشاء حساب'
                          : 'تسجيل الدخول',
                ),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() => registering = !registering),
                child: Text(
                  registering
                      ? 'لدي حساب بالفعل'
                      : 'إنشاء حساب جديد',
                ),
              ),
              const Text(
                'تسجيل الدخول الحالي بالإيميل. يجب إعداد التحقق من الهاتف '
                'قبل السماح بالحجوزات المتعددة.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AccountGate extends StatelessWidget {
  const AccountGate({super.key});

  @override
  Widget build(BuildContext context) {
    final user = auth.currentUser!;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('drivers').doc(user.uid).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const HomePage();
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LoadingPage();
        }

        final driver = snapshot.data?.data();
        if (driver == null) return const HomePage();

        final status = driver['status'] ?? 'pending';
        final active = driver['active'] == true;

        if (status == 'approved' && active) {
          return const DriverPage();
        }
        if (status == 'suspended' || status == 'stopped') {
          return DriverStatusPage(
            title: 'حساب السائق موقوف',
            details: 'لا يمكنك استقبال حجوزات جديدة. تواصل مع إدارة التطبيق.',
          );
        }
        return DriverStatusPage(
          title: 'طلب اعتماد السائق قيد المراجعة',
          details: 'لن تتمكن من استقبال الحجوزات حتى توافق إدارة التطبيق.',
        );
      },
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = auth.currentUser!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Golden louage'),
        actions: [
          IconButton(
            tooltip: 'تسجيل الخروج',
            onPressed: () => auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(Icons.directions_bus, size: 70),
          const SizedBox(height: 12),
          const Text(
            'مرحبًا بك في Golden louage',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(user.email ?? user.phoneNumber ?? ''),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.event_seat),
            label: const Text('احجز مقعدًا'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BookingPage()),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: const Icon(Icons.confirmation_number),
            label: const Text('رحلاتي وحجوزاتي'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MyBookingsPage()),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: const Icon(Icons.drive_eta),
            label: const Text('طلب اعتماد كسائق'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DriverApplicationPage()),
            ),
          ),
        ],
      ),
    );
  }
}

class DriverStatusPage extends StatelessWidget {
  final String title;
  final String details;

  const DriverStatusPage({
    super.key,
    required this.title,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('حالة حساب السائق'),
        actions: [
          IconButton(
            onPressed: () => auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hourglass_top, size: 64),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(details, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

class DriverApplicationPage extends StatefulWidget {
  const DriverApplicationPage({super.key});

  @override
  State<DriverApplicationPage> createState() =>
      _DriverApplicationPageState();
}

class _DriverApplicationPageState extends State<DriverApplicationPage> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final vehicle = TextEditingController();
  final plate = TextEditingController();
  final departure = TextEditingController();
  final destination = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    vehicle.dispose();
    plate.dispose();
    departure.dispose();
    destination.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final user = auth.currentUser;
    if (user == null) return;

    if ([name, phone, vehicle, plate, departure, destination]
        .any((c) => c.text.trim().isEmpty)) {
      message(context, 'يرجى إكمال جميع المعلومات.');
      return;
    }

    setState(() => busy = true);
    try {
      final existing =
          await db.collection('drivers').doc(user.uid).get();
      if (existing.exists) {
        message(context, 'لديك بالفعل ملف سائق أو طلب اعتماد.');
        return;
      }

      await db.collection('driver_applications').add({
        'uid': user.uid,
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'vehicle': vehicle.text.trim(),
        'plate': plate.text.trim(),
        'departure': departure.text.trim(),
        'destination': destination.text.trim(),
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // This record remains inactive until the owner approves the driver.
      await db.collection('drivers').doc(user.uid).set({
        'uid': user.uid,
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'vehicle': vehicle.text.trim(),
        'plate': plate.text.trim(),
        'departure': departure.text.trim(),
        'destination': destination.text.trim(),
        'status': 'pending',
        'active': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      message(context, 'تم إرسال الطلب. انتظر موافقة إدارة التطبيق.');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('طلب اعتماد سائق')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          field(name, 'الاسم الكامل'),
          field(phone, 'رقم الهاتف'),
          field(vehicle, 'نوع السيارة'),
          field(plate, 'رقم اللوحة'),
          field(departure, 'مدينة الانطلاق'),
          field(destination, 'الوجهة'),
          FilledButton(
            onPressed: busy ? null : submit,
            child: Text(busy ? 'يرجى الانتظار...' : 'إرسال الطلب'),
          ),
          const SizedBox(height: 12),
          const Text(
            'إرسال الطلب لا يمنحك صلاحية السائق. يجب انتظار موافقة الإدارة.',
          ),
        ],
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
  final departure = TextEditingController();
  final destination = TextEditingController();
  final date = TextEditingController();
  final time = TextEditingController();
  int seat = 1;
  bool busy = false;

  @override
  void dispose() {
    departure.dispose();
    destination.dispose();
    date.dispose();
    time.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final user = auth.currentUser;
    if (user == null) return;

    if ([departure, destination, date, time]
        .any((c) => c.text.trim().isEmpty)) {
      message(context, 'يرجى إكمال جميع بيانات الرحلة.');
      return;
    }

    setState(() => busy = true);
    try {
      await db.collection('booking_requests').add({
        'uid': user.uid,
        'contact': user.email ?? user.phoneNumber ?? '',
        'departure': departure.text.trim(),
        'destination': destination.text.trim(),
        'travelDate': date.text.trim(),
        'travelTime': time.text.trim(),
        'seat': seat,
        'status': 'pending',
        'driverUid': '',
        'confirmationDeadline': null,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      message(context, 'تم إرسال طلب الحجز. ينتظر تعيين سائق.');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(TextEditingController c, String label, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('حجز مقعد')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          field(departure, 'مكان الانطلاق'),
          field(destination, 'الوجهة'),
          field(date, 'تاريخ الرحلة', hint: '2026-11-05'),
          field(time, 'وقت الانطلاق', hint: '08:30'),
          const Text('اختر المقعد'),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            value: seat,
            items: List.generate(
              8,
              (i) => DropdownMenuItem(
                value: i + 1,
                child: Text('المقعد ${i + 1}'),
              ),
            ),
            onChanged: (v) {
              if (v != null) setState(() => seat = v);
            },
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: busy ? null : submit,
            child: Text(busy ? 'يرجى الانتظار...' : 'إرسال طلب الحجز'),
          ),
        ],
      ),
    );
  }
}

class MyBookingsPage extends StatelessWidget {
  const MyBookingsPage({super.key});

  String statusLabel(String status) {
    switch (status) {
      case 'pending':
        return 'في انتظار السائق';
      case 'offered':
        return 'في انتظار تأكيدك';
      case 'confirmed':
        return 'مؤكد';
      case 'rejected':
        return 'مرفوض';
      case 'expired':
        return 'انتهت المهلة';
      case 'cancelled':
        return 'ملغى';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = auth.currentUser;
    if (user == null) return const LoadingPage();

    return Scaffold(
      appBar: AppBar(title: const Text('رحلاتي وحجوزاتي')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: db
            .collection('booking_requests')
            .where('uid', isEqualTo: user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Text('تعذّر عرض الحجوزات. راجع قواعد Firestore.'),
            );
          }
          if (!snapshot.hasData) return const LoadingPage();

          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('لا توجد حجوزات حتى الآن.'));
          }

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final b = doc.data();
              final status = b['status']?.toString() ?? 'pending';

              return Card(
                margin: const EdgeInsets.all(10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${b['departure'] ?? ''} ← ${b['destination'] ?? ''}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('التاريخ: ${b['travelDate'] ?? ''}'),
                      Text('الوقت: ${b['travelTime'] ?? ''}'),
                      Text('المقعد: ${b['seat'] ?? ''}'),
                      Text('الحالة: ${statusLabel(status)}'),
                      if (status == 'offered') ...[
                        const SizedBox(height: 12),
                        const Text(
                          'السائق عرض عليك هذا الحجز. مهلة التأكيد '
                          'تحتاج إلى تفعيل المنطق الخلفي وقواعد الأمان.',
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'لا تعتبر الرحلة مؤكدة حتى يظهر status = confirmed.',
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class DriverPage extends StatelessWidget {
  const DriverPage({super.key});

  Future<void> requestStop(BuildContext context) async {
    final user = auth.currentUser;
    if (user == null) return;

    try {
      await db.collection('driver_stop_requests').add({
        'uid': user.uid,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (context.mounted) {
        message(
          context,
          'تم إرسال طلب إيقاف النشاط. يبقى الحساب فعالًا حتى تتخذ الإدارة إجراءً.',
        );
      }
    } catch (e) {
      if (context.mounted) message(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = auth.currentUser!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('مساحة السائق'),
        actions: [
          IconButton(
            onPressed: () => auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ListTile(
            leading: Icon(Icons.verified_user, size: 36),
            title: Text('حساب سائق معتمد'),
            subtitle: Text('يمكنك متابعة الطلبات المعيّنة لحسابك.'),
          ),
          const Divider(),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: db
                .collection('booking_requests')
                .where('driverUid', isEqualTo: user.uid)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text(
                  'تعذّر تحميل الطلبات. راجع قواعد Firestore.',
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('لا توجد طلبات معيّنة لك حاليًا.'),
                );
              }

              return Column(
                children: docs.map((doc) {
                  final b = doc.data();
                  return Card(
                    child: ListTile(
                      title: Text(
                        '${b['departure'] ?? ''} ← ${b['destination'] ?? ''}',
                      ),
                      subtitle: Text(
                        'التاريخ: ${b['travelDate'] ?? ''}\n'
                        'الوقت: ${b['travelTime'] ?? ''}\n'
                        'المقعد: ${b['seat'] ?? ''}\n'
                        'الحالة: ${b['status'] ?? ''}',
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            icon: const Icon(Icons.pause_circle_outline),
            label: const Text('طلب إيقاف النشاط'),
            onPressed: () => requestStop(context),
          ),
          const SizedBox(height: 12),
          const Text(
            'قبول الطلبات وتأكيد المقاعد وإدارة المهلة ستُفعّل بعد '
            'استكمال قواعد Firestore والمنطق الآمن في الخلفية.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
