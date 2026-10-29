
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const GoldenLouageApp());
}

final auth = FirebaseAuth.instance;
final db = FirebaseFirestore.instance;

class GoldenLouageApp extends StatelessWidget {
  const GoldenLouageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Golden louage',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const AuthGate(),
    );
  }
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

        final user = snapshot.data!;
        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: db.collection('admins').doc(user.uid).get(),
          builder: (context, adminSnap) {
            if (!adminSnap.hasData) return const LoadingPage();
            if (adminSnap.data!.exists) return const AdminPage();

            return FutureBuilder<
                DocumentSnapshot<Map<String, dynamic>>>(
              future: db.collection('drivers').doc(user.uid).get(),
              builder: (context, driverSnap) {
                if (!driverSnap.hasData) {
                  return const LoadingPage();
                }

                if (driverSnap.data!.exists) {
                  final d = driverSnap.data!.data() ?? {};
                  if (d['status'] == 'approved' &&
                      d['active'] == true) {
                    return const DriverPage();
                  }
                  return DriverStatusPage(
                    status: '${d['status'] ?? 'pending'}',
                  );
                }
                return const PassengerPage();
              },
            );
          },
        );
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

void message(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text)),
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
  bool register = false;
  bool busy = false;

  Future<void> submit() async {
    if (email.text.trim().isEmpty || password.text.length < 6) {
      message(context, 'أدخل البريد وكلمة مرور من 6 أحرف على الأقل');
      return;
    }

    setState(() => busy = true);
    try {
      if (register) {
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
    } on FirebaseAuthException catch (e) {
      if (mounted) message(context, e.message ?? 'تعذّر تسجيل الدخول');
    } catch (e) {
      if (mounted) message(context, 'حدث خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(Icons.directions_bus,
                  size: 76, color: Colors.amber),
              const SizedBox(height: 12),
              const Text(
                'Golden louage',
                style: TextStyle(fontSize: 28,
                    fontWeight: FontWeight.bold),
              ),
              const Text('رحلتك تبدأ معنا'),
              const SizedBox(height: 28),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور',
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(busy
                      ? 'يرجى الانتظار...'
                      : register
                          ? 'إنشاء حساب'
                          : 'دخول'),
                ),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() => register = !register),
                child: Text(register
                    ? 'لديك حساب؟ سجّل الدخول'
                    : 'ليس لديك حساب؟ أنشئ حسابًا'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PassengerPage extends StatelessWidget {
  const PassengerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Golden louage'),
        actions: [
          IconButton(
            onPressed: () => auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'مرحبًا بك',
            style: TextStyle(fontSize: 25,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('احجز مقعدك وتابع حالة رحلتك.'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const BookingPage(),
              ),
            ),
            icon: const Icon(Icons.event_seat),
            label: const Text('حجز رحلة'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const MyBookingsPage(),
              ),
            ),
            icon: const Icon(Icons.list_alt),
            label: const Text('حجوزاتي'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const DriverApplicationPage(),
              ),
            ),
            icon: const Icon(Icons.directions_bus),
            label: const Text('طلب التسجيل كسائق'),
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
  final contact = TextEditingController();

  DateTime travelDate = DateTime.now().add(
    const Duration(days: 1),
  );
  TimeOfDay travelTime = const TimeOfDay(hour: 8, minute: 0);
  int seat = 1;
  bool busy = false;

  Future<void> saveBooking() async {
    if (departure.text.trim().isEmpty ||
        destination.text.trim().isEmpty ||
        contact.text.trim().isEmpty) {
      message(context, 'أكمل مكان الانطلاق والوصول ورقم الاتصال');
      return;
    }

    final user = auth.currentUser;
    if (user == null) return;

    setState(() => busy = true);
    try {
      await db.collection('booking_requests').add({
        'uid': user.uid,
        'contact': contact.text.trim(),
        'departure': departure.text.trim(),
        'destination': destination.text.trim(),
        'travelDate':
            '${travelDate.year}-${travelDate.month.toString().padLeft(2, '0')}-${travelDate.day.toString().padLeft(2, '0')}',
        'travelTime':
            '${travelTime.hour.toString().padLeft(2, '0')}:${travelTime.minute.toString().padLeft(2, '0')}',
        'seat': seat,
        'driverUid': '',
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        message(context, 'تم إرسال طلب الحجز');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) message(context, 'تعذّر حفظ الحجز: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    departure.dispose();
    destination.dispose();
    contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('حجز رحلة')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: departure,
            decoration: const InputDecoration(
              labelText: 'مكان الانطلاق',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: destination,
            decoration: const InputDecoration(
              labelText: 'مكان الوصول',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: contact,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'رقم الهاتف',
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            title: const Text('تاريخ الرحلة'),
            subtitle: Text(
              '${travelDate.year}-${travelDate.month}-${travelDate.day}',
            ),
            trailing: const Icon(Icons.calendar_month),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: travelDate,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(
                  const Duration(days: 365),
                ),
              );
              if (picked != null) {
                setState(() => travelDate = picked);
              }
            },
          ),
          ListTile(
            title: const Text('وقت الرحلة'),
            subtitle: Text(travelTime.format(context)),
            trailing: const Icon(Icons.access_time),
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: travelTime,
              );
              if (picked != null) {
                setState(() => travelTime = picked);
              }
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            value: seat,
            decoration: const InputDecoration(
              labelText: 'رقم المقعد',
            ),
            items: List.generate(
              8,
              (i) => DropdownMenuItem(
                value: i + 1,
                child: Text('المقعد ${i + 1}'),
              ),
            ),
            onChanged: (value) {
              if (value != null) setState(() => seat = value);
            },
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : saveBooking,
            child: Text(busy ? 'جارٍ الحفظ...' : 'إرسال الحجز'),
          ),
        ],
      ),
    );
  }
}

class MyBookingsPage extends StatelessWidget {
  const MyBookingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = auth.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('حجوزاتي')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: db.collection('booking_requests')
            .where('uid', isEqualTo: uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('تعذّر تحميل الحجوزات'));
          }
          if (!snapshot.hasData) {
            return const LoadingPage();
          }

          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('لا توجد حجوزات بعد'));
          }

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final b = docs[index].data();
              return Card(
                margin: const EdgeInsets.all(8),
                child: ListTile(
                  leading: const Icon(Icons.event_seat),
                  title: Text(
                    '${b['departure'] ?? ''} ← ${b['destination'] ?? ''}',
                  ),
                  subtitle: Text(
                    'التاريخ: ${b['travelDate'] ?? ''}\n'
                    'الوقت: ${b['travelTime'] ?? ''}\n'
                    'المقعد: ${b['seat'] ?? b['seat1'] ?? ''}\n'
                    'الحالة: ${b['status'] ?? ''}',
                  ),
                  isThreeLine: true,
                ),
              );
            },
          );
        },
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

class _DriverApplicationPageState
    extends State<DriverApplicationPage> {
  final name = TextEditingController();
  final phone = TextEditingController();
  bool busy = false;

  Future<void> submit() async {
    final user = auth.currentUser;
    if (user == null) return;

    if (name.text.trim().isEmpty || phone.text.trim().isEmpty) {
      message(context, 'أدخل الاسم ورقم الهاتف');
      return;
    }

    setState(() => busy = true);
    try {
      final driverRef = db.collection('drivers').doc(user.uid);
      final existing = await driverRef.get();

      if (existing.exists) {
        if (mounted) {
          message(context, 'لديك طلب أو حساب سائق مسجّل بالفعل');
        }
        return;
      }

      final data = {
        'uid': user.uid,
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'status': 'pending',
        'active': false,
        'createdAt': FieldValue.serverTimestamp(),
      };

      await db.collection('driver_applications')
          .doc(user.uid).set(data);
      await driverRef.set(data);

      if (mounted) {
        message(context, 'أُرسل طلبك للإدارة للمراجعة');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) message(context, 'تعذّر إرسال الطلب: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('طلب اعتماد سائق')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'تسجيل الطلب لا يمنحك صلاحية القيادة تلقائيًا. '
            'يجب انتظار موافقة الإدارة.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'الاسم الكامل'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'رقم الهاتف'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : submit,
            child: Text(busy ? 'يرجى الانتظار...' : 'إرسال الطلب'),
          ),
        ],
      ),
    );
  }
}

class DriverStatusPage extends StatelessWidget {
  final String status;
  const DriverStatusPage({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final approved = status == 'approved';
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
          child: Text(
            approved
                ? 'حسابك معتمد، لكنه غير نشط حاليًا. اتصل بالإدارة.'
                : 'طلبك قيد المراجعة. لا يمكنك العمل كسائق قبل اعتماد الإدارة.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18),
          ),
        ),
      ),
    );
  }
}

class DriverPage extends StatelessWidget {
  const DriverPage({super.key});

  Future<void> stopOperating(BuildContext context) async {
    final user = auth.currentUser!;
    try {
      await db.collection('driver_stop_requests')
          .doc(user.uid).set({
        'uid': user.uid,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (context.mounted) {
        message(context, 'أُرسل طلب إيقاف العمل إلى الإدارة');
      }
    } catch (e) {
      if (context.mounted) message(context, 'تعذّر إرسال الطلب: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = auth.currentUser!.uid;

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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton(
              onPressed: () => stopOperating(context),
              child: const Text('إبلاغ الإدارة بالتوقف عن العمل'),
            ),
          ),
          const Divider(),
          const Text('الحجوزات المسندة إليك'),
          Expanded(
            child: StreamBuilder<
                QuerySnapshot<Map<String, dynamic>>>(
              stream: db.collection('booking_requests')
                  .where('driverUid', isEqualTo: uid)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text('تعذّر تحميل الحجوزات'),
                  );
                }
                if (!snapshot.hasData) return const LoadingPage();

                final docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return const Center(
                    child: Text('لا توجد حجوزات مسندة إليك'),
                  );
                }

                return ListView(
                  children: docs.map((doc) {
                    final b = doc.data();
                    return Card(
                      child: ListTile(
                        title: Text(
                          '${b['departure'] ?? ''} ← ${b['destination'] ?? ''}',
                        ),
                        subtitle: Text(
                          '${b['travelDate'] ?? ''} '
                          '${b['travelTime'] ?? ''}\n'
                          'الحالة: ${b['status'] ?? ''}',
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  Future<void> approveDriver(
    BuildContext context,
    String uid,
  ) async {
    try {
      final batch = db.batch();
      batch.update(db.collection('drivers').doc(uid), {
        'status': 'approved',
        'active': true,
      });
      batch.update(
        db.collection('driver_applications').doc(uid),
        {'status': 'approved'},
      );
      await batch.commit();

      if (context.mounted) message(context, 'تم اعتماد السائق');
    } catch (e) {
      if (context.mounted) {
        message(context, 'تعذّر اعتماد السائق: $e');
      }
    }
  }

  Future<void> suspendDriver(
    BuildContext context,
    String uid,
  ) async {
    try {
      await db.collection('drivers').doc(uid).update({
        'status': 'suspended',
        'active': false,
      });
      if (context.mounted) message(context, 'تم إيقاف حساب السائق');
    } catch (e) {
      if (context.mounted) message(context, 'حدث خطأ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إدارة Golden louage'),
        actions: [
          IconButton(
            onPressed: () => auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'طلبات اعتماد السائقين',
            style: TextStyle(fontSize: 20,
                fontWeight: FontWeight.bold),
          ),
          StreamBuilder<
              QuerySnapshot<Map<String, dynamic>>>(
            stream: db.collection('driver_applications')
                .where('status', isEqualTo: 'pending')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text('تعذّر تحميل طلبات السائقين');
              }
              if (!snapshot.hasData) {
                return const LinearProgressIndicator();
              }

              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('لا توجد طلبات معلّقة'),
                );
              }

              return Column(
                children: docs.map((doc) {
                  final d = doc.data();
                  return Card(
                    child: ListTile(
                      title: Text('${d['name'] ?? ''}'),
                      subtitle: Text('${d['phone'] ?? ''}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.check_circle,
                            color: Colors.green),
                        onPressed: () =>
                            approveDriver(context, doc.id),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          const Divider(height: 32),
          const Text(
            'السائقون المعتمدون',
            style: TextStyle(fontSize: 20,
                fontWeight: FontWeight.bold),
          ),
          StreamBuilder<
              QuerySnapshot<Map<String, dynamic>>>(
            stream: db.collection('drivers')
                .where('status', isEqualTo: 'approved')
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const LinearProgressIndicator();
              }

              return Column(
                children: snapshot.data!.docs.map((doc) {
                  final d = doc.data();
                  return Card(
                    child: ListTile(
                      title: Text('${d['name'] ?? doc.id}'),
                      subtitle: Text(
                        d['active'] == true ? 'نشط' : 'متوقف',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.pause_circle),
                        onPressed: () =>
                            suspendDriver(context, doc.id),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

}

class DriverStopRequestsPage extends StatelessWidget {
  const DriverStopRequestsPage({super.key});

  Future<void> handleRequest(
    BuildContext context,
    String uid,
    bool approve,
  ) async {
    try {
      final requestRef =
          db.collection('driver_stop_requests').doc(uid);
      final driverRef = db.collection('drivers').doc(uid);

      await db.runTransaction((transaction) async {
        final requestSnapshot =
            await transaction.get(requestRef);

        if (!requestSnapshot.exists) {
          throw Exception('طلب التوقف غير موجود');
        }

        final requestData = requestSnapshot.data()
            as Map<String, dynamic>;

        if (requestData['status'] != 'pending') {
          throw Exception('تمت معالجة هذا الطلب سابقًا');
        }

        if (approve) {
          transaction.update(driverRef, {
            'active': false,
            'status': 'approved',
          });
        }

        transaction.update(requestRef, {
          'status': approve ? 'approved' : 'rejected',
          'processedAt': FieldValue.serverTimestamp(),
        });
      });

      if (context.mounted) {
        message(
          context,
          approve
              ? 'تم إيقاف نشاط السائق'
              : 'تم رفض طلب التوقف',
        );
      }
    } catch (e) {
      if (context.mounted) {
        message(context, 'تعذّرت معالجة الطلب: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('طلبات توقف السائقين'),
      ),
      body: StreamBuilder<
          QuerySnapshot<Map<String, dynamic>>>(
        stream: db
            .collection('driver_stop_requests')
            .where('status', isEqualTo: 'pending')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Text('تعذّر تحميل الطلبات'),
            );
          }

          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final requests = snapshot.data!.docs;

          if (requests.isEmpty) {
            return const Center(
              child: Text('لا توجد طلبات توقّف معلّقة'),
            );
          }

          return ListView.builder(
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final request = requests[index];
              final data = request.data();

              return Card(
                margin: const EdgeInsets.all(10),
                child: ListTile(
                  title: Text(
                    'السائق: ${data['uid'] ?? request.id}',
                  ),
                  subtitle: const Text(
                    'طلب إيقاف النشاط في انتظار المراجعة',
                  ),
                  isThreeLine: true,
                  trailing: PopupMenuButton<bool>(
                    tooltip: 'معالجة الطلب',
                    onSelected: (approve) {
                      handleRequest(
                        context,
                        request.id,
                        approve,
                      );
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem<bool>(
                        value: true,
                        child: Text('الموافقة على التوقف'),
                      ),
                      PopupMenuItem<bool>(
                        value: false,
                        child: Text('رفض الطلب'),
                      ),
                    ],
                  ),
                )
              );
            },
          );
        },
      ),
    );
  }
}

}

class BookingManagementPage extends StatelessWidget {
  const BookingManagementPage({super.key});

  Future<void> assignDriver(
    BuildContext context,
    String bookingId,
    String driverUid,
  ) async {
    try {
      final bookingRef =
          db.collection('booking_requests').doc(bookingId);
      final driverRef = db.collection('drivers').doc(driverUid);

      await db.runTransaction((transaction) async {
        final bookingSnapshot =
            await transaction.get(bookingRef);
        final driverSnapshot =
            await transaction.get(driverRef);

        if (!bookingSnapshot.exists) {
          throw Exception('الحجز غير موجود');
        }

        if (!driverSnapshot.exists) {
          throw Exception('السائق غير موجود');
        }

        final driver = driverSnapshot.data()
            as Map<String, dynamic>;
        final booking = bookingSnapshot.data()
            as Map<String, dynamic>;

        if (driver['status'] != 'approved' ||
            driver['active'] != true) {
          throw Exception('السائق غير معتمد أو غير نشط');
        }

        if (booking['driverUid'] != null &&
            booking['driverUid'] != '') {
          throw Exception('الحجز مسند إلى سائق بالفعل');
        }

        transaction.update(bookingRef, {
          'driverUid': driverUid,
          'assignedAt': FieldValue.serverTimestamp(),
        });
      });

      if (context.mounted) {
        message(context, 'تم إسناد الحجز إلى السائق');
      }
    } catch (e) {
      if (context.mounted) {
        message(context, 'تعذّر إسناد الحجز: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إدارة الحجوزات'),
      ),
      body: StreamBuilder<
          QuerySnapshot<Map<String, dynamic>>>(
        stream: db
            .collection('booking_requests')
            .snapshots(),
        builder: (context, bookingSnapshot) {
          if (bookingSnapshot.hasError) {
            return const Center(
              child: Text('تعذّر تحميل الحجوزات'),
            );
          }

          if (!bookingSnapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final bookings = bookingSnapshot.data!.docs;

          if (bookings.isEmpty) {
            return const Center(
              child: Text('لا توجد حجوزات'),
            );
          }

          return StreamBuilder<
              QuerySnapshot<Map<String, dynamic>>>(
            stream: db
                .collection('drivers')
                .where('status', isEqualTo: 'approved')
                .where('active', isEqualTo: true)
                .snapshots(),
            builder: (context, driverSnapshot) {
              if (!driverSnapshot.hasData) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }

              final drivers = driverSnapshot.data!.docs;

              return ListView.builder(
                itemCount: bookings.length,
                itemBuilder: (context, index) {
                  final bookingDoc = bookings[index];
                  final booking = bookingDoc.data();
                  final assigned =
                      (booking['driverUid'] ?? '')
                          .toString()
                          .isNotEmpty;

                  return Card(
                    margin: const EdgeInsets.all(10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${booking['departure'] ?? ''} ← '
                            '${booking['destination'] ?? ''}',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'التاريخ: ${booking['travelDate'] ?? ''}',
                          ),
                          Text(
                            'الوقت: ${booking['travelTime'] ?? ''}',
                          ),
                          Text(
                            'المقعد: ${booking['seat'] ?? ''}',
                          ),
                          Text(
                            'الحالة: ${booking['status'] ?? ''}',
                          ),
                          const SizedBox(height: 10),
                          if (assigned)
                            Text(
                              'السائق المعيّن: '
                              '${booking['driverUid']}',
                            )
                          else if (drivers.isEmpty)
                            const Text(
                              'لا يوجد سائق نشط ومعتمد حاليًا',
                            )
                          else
                            DropdownButtonFormField<String>(
                              decoration: const InputDecoration(
                                labelText: 'إسناد إلى سائق',
                              ),
                              items: drivers.map((driverDoc) {
                                final driver =
                                    driverDoc.data();
                                return DropdownMenuItem<String>(
                                  value: driverDoc.id,
                                  child: Text(
                                    '${driver['name'] ?? driverDoc.id}',
                                  ),
                                );
                              }).toList(),
                              onChanged: (driverUid) {
                                if (driverUid != null) {
                                  assignDriver(
                                    context,
                                    bookingDoc.id,
                                    driverUid,
                                  );
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

