
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber),
        useMaterial3: true,
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
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) return const HomePage();
        return const LoginPage();
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool usePhone = false;
  bool createAccount = false;
  bool busy = false;
  bool codeSent = false;

  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final phoneController = TextEditingController();
  final codeController = TextEditingController();

  String? verificationId;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    phoneController.dispose();
    codeController.dispose();
    super.dispose();
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> emailLogin() async {
    setState(() => busy = true);
    try {
      final email = emailController.text.trim();
      final password = passwordController.text;

      if (email.isEmpty || password.isEmpty) {
        showMessage('أدخل الإيميل وكلمة السر');
        return;
      }

      if (createAccount) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'weak-password') {
        showMessage('كلمة السر ضعيفة. استعمل 6 أحرف على الأقل.');
      } else if (e.code == 'email-already-in-use') {
        showMessage('هذا الإيميل مسجّل من قبل.');
      } else if (e.code == 'invalid-email') {
        showMessage('الإيميل غير صحيح.');
      } else if (e.code == 'invalid-credential' ||
          e.code == 'wrong-password' ||
          e.code == 'user-not-found') {
        showMessage('الإيميل أو كلمة السر غير صحيحة.');
      } else {
        showMessage(e.message ?? 'تعذّر الدخول. حاول مرة أخرى.');
      }
    } catch (e) {
      showMessage('حدث خطأ. تأكد من اتصال الإنترنت.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> sendPhoneCode() async {
    final phone = phoneController.text.trim();

    if (!phone.startsWith('+216') || phone.length < 11) {
      showMessage('أدخل الرقم التونسي مع رمز الدولة، مثال: +216XXXXXXXX');
      return;
    }

    setState(() => busy = true);
    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          await FirebaseAuth.instance.signInWithCredential(credential);
        },
        verificationFailed: (FirebaseAuthException e) {
          showMessage(e.message ?? 'تعذّر إرسال رمز التحقق.');
        },
        codeSent: (String id, int? resendToken) {
          if (!mounted) return;
          setState(() {
            verificationId = id;
            codeSent = true;
          });
          showMessage('تم إرسال رمز التحقق إذا كان الرقم مدعومًا.');
        },
        codeAutoRetrievalTimeout: (String id) {
          verificationId = id;
        },
      );
    } on FirebaseAuthException catch (e) {
      showMessage(e.message ?? 'تعذّر إرسال SMS.');
    } catch (e) {
      showMessage('تعذّر إرسال الرمز. تحقق من الإنترنت وإعدادات Firebase.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> verifyPhoneCode() async {
    if (verificationId == null || codeController.text.trim().isEmpty) {
      showMessage('أدخل رمز التحقق الذي وصلك.');
      return;
    }

    setState(() => busy = true);
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: codeController.text.trim(),
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      showMessage(e.message ?? 'رمز التحقق غير صحيح.');
    } catch (e) {
      showMessage('تعذّر التحقق من الرمز.');
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
              const Icon(Icons.directions_bus, size: 72),
              const SizedBox(height: 12),
              const Text(
                'مرحبًا بك في Golden louage',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('الإيميل'),
                    icon: Icon(Icons.email),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('رقم الهاتف'),
                    icon: Icon(Icons.phone_android),
                  ),
                ],
                selected: {usePhone},
                onSelectionChanged: (selection) {
                  setState(() {
                    usePhone = selection.first;
                    codeSent = false;
                    verificationId = null;
                  });
                },
              ),
              const SizedBox(height: 20),
              if (!usePhone) ...[
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'الإيميل',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة السر',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: busy ? null : emailLogin,
                  child: Text(
                    busy
                        ? 'يرجى الانتظار...'
                        : createAccount
                            ? 'إنشاء حساب بالإيميل'
                            : 'الدخول بالإيميل',
                  ),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(
                            () => createAccount = !createAccount,
                          ),
                  child: Text(
                    createAccount
                        ? 'لدي حساب بالفعل'
                        : 'ليس لدي حساب — إنشاء حساب جديد',
                  ),
                ),
              ] else ...[
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف',
                    hintText: '+216XXXXXXXX',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                if (codeSent) ...[
                  TextField(
                    controller: codeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'رمز SMS',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: busy ? null : verifyPhoneCode,
                    child: const Text('تأكيد الرمز والدخول'),
                  ),
                ] else
                  ElevatedButton(
                    onPressed: busy ? null : sendPhoneCode,
                    child: Text(
                      busy ? 'يرجى الانتظار...' : 'إرسال رمز SMS',
                    ),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'الدخول بالهاتف لا يحتاج إلى إيميل.',
                  textAlign: TextAlign.center,
                ),
              ],
              if (busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Golden louage'),
        actions: [
          IconButton(
            tooltip: 'تسجيل الخروج',
            onPressed: () => FirebaseAuth.instance.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.directions_bus, size: 64),
              const SizedBox(height: 12),
              const Text(
                'مرحبًا بك في Golden louage',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                user?.email ?? user?.phoneNumber ?? '',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
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
              ElevatedButton.icon(
                icon: const Icon(Icons.confirmation_number),
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
              ElevatedButton.icon(
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('موافقة صاحب اللواج'),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('خاصية موافقة السائق سنضيفها لاحقًا.'),
                    ),
                  );
                },
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.location_on),
                label: const Text('تتبّع اللواج'),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('خاصية التتبع سنضيفها لاحقًا.'),
                    ),
                  );
                },
              ),
            ],
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
  final departureController = TextEditingController();
  final destinationController = TextEditingController();
  final dateController = TextEditingController();
  final timeController = TextEditingController();

  int seat = 1;
  bool busy = false;

  @override
  void dispose() {
    departureController.dispose();
    destinationController.dispose();
    dateController.dispose();
    timeController.dispose();
    super.dispose();
  }

  Future<void> submitBooking() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('سجّل الدخول أولًا.')),
      );
      return;
    }

    if (departureController.text.trim().isEmpty ||
        destinationController.text.trim().isEmpty ||
        dateController.text.trim().isEmpty ||
        timeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى إكمال جميع بيانات الرحلة.')),
      );
      return;
    }

    setState(() => busy = true);

    try {
      await FirebaseFirestore.instance.collection('booking_requests').add({
        'uid': user.uid,
        'contact': user.email ?? user.phoneNumber ?? '',
        'departure': departureController.text.trim(),
        'destination': destinationController.text.trim(),
        'travelDate': dateController.text.trim(),
        'travelTime': timeController.text.trim(),
        'seat': seat,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم إرسال طلب الحجز. ينتظر موافقة صاحب اللواج.'),
        ),
      );
      Navigator.pop(context);
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'permission-denied'
                ? 'الحجز لم يُحفظ بعد. يلزم ضبط قواعد Firestore.'
                : 'تعذّر حفظ الحجز: ${e.message ?? e.code}',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حدث خطأ أثناء إرسال الحجز.')),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('حجز مقعد')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: departureController,
            decoration: const InputDecoration(
              labelText: 'مكان الانطلاق',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: destinationController,
            decoration: const InputDecoration(
              labelText: 'الوجهة',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: dateController,
            decoration: const InputDecoration(
              labelText: 'تاريخ الرحلة (مثال: 2026-11-05)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: timeController,
            decoration: const InputDecoration(
              labelText: 'وقت الانطلاق (مثال: 08:30)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          const Text('اختر المقعد'),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            value: seat,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
            ),
            items: List.generate(
              8,
              (index) => DropdownMenuItem(
                value: index + 1,
                child: Text('المقعد ${index + 1}'),
              ),
            ),
            onChanged: (value) {
              if (value != null) setState(() => seat = value);
            },
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: busy ? null : submitBooking,
            child: Text(busy ? 'يرجى الانتظار...' : 'إرسال طلب الحجز'),
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
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('يرجى تسجيل الدخول أولًا.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('رحلاتي وحجوزاتي')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('booking_requests')
            .where('uid', isEqualTo: user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Text(
                'تعذّر عرض الحجوزات. قد تحتاج قواعد Firestore إلى التعديل.',
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return const Center(child: Text('لا توجد حجوزات حتى الآن.'));
          }

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final booking = docs[index].data();

              return Card(
                margin: const EdgeInsets.all(10),
                child: ListTile(
                  leading: const Icon(Icons.directions_bus),
                  title: Text(
                    '${booking['departure'] ?? ''} → '
                    '${booking['destination'] ?? ''}',
                  ),
                  subtitle: Text(
                    'التاريخ: ${booking['travelDate'] ?? ''}\n'
                    'الوقت: ${booking['travelTime'] ?? ''}\n'
                    'المقعد: ${booking['seat'] ?? ''}\n'
                    'الحالة: ${booking['status'] ?? 'pending'}',
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
