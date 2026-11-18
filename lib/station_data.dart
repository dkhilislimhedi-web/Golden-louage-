import 'dart:convert';

import 'package:flutter/services.dart';

class StationOption {
  final String id;
  final String value;
  final String nameAr;
  final String nameEn;
  final String labelAr;
  final String labelEn;

  const StationOption({
    required this.id,
    required this.value,
    required this.nameAr,
    required this.nameEn,
    required this.labelAr,
    required this.labelEn,
  });

  String label(String languageCode) => languageCode == 'en' ? labelEn : labelAr;
}

class StationData {
  static Future<List<StationOption>> load() async {
    final governorates = List<Map<String, dynamic>>.from(
      jsonDecode(await rootBundle.loadString('assets/data/governorates.json')),
    );

    final delegations = List<Map<String, dynamic>>.from(
      jsonDecode(await rootBundle.loadString('assets/data/delegations.json')),
    );

    final govById = {for (final g in governorates) g['id'].toString(): g};

    final records = <Map<String, String>>[];

    // إضافة مراكز الولايات التي لا تطابق معتمدية بالاسم نفسه.
    for (final g in governorates) {
      final govId = g['id'].toString();
      final capitalAr = (g['capital_ar'] ?? g['name_ar']).toString();

      final matchingDelegation = delegations.any(
        (d) =>
            d['governorate'].toString() == govId &&
            d['name_ar'].toString() == capitalAr,
      );

      // إذا كان المركز هو المعتمدية نفسها، سنضيفه مرة واحدة
      // ضمن قائمة المعتمديات أدناه.
      if (matchingDelegation) continue;

      records.add({
        'id': 'center_$govId',
        'nameAr': capitalAr,
        'nameEn': (g['capital_en'] ?? g['name_en']).toString(),
        'govAr': g['name_ar'].toString(),
        'govEn': g['name_en'].toString(),
        'type': 'center',
      });
    }

    // إضافة المعتمديات، بما فيها المعتمديات المطابقة للمراكز.
    for (final d in delegations) {
      final gov = govById[d['governorate'].toString()];
      if (gov == null) continue;

      records.add({
        'id': d['id'].toString(),
        'nameAr': d['name_ar'].toString(),
        'nameEn': d['name_en'].toString(),
        'govAr': gov['name_ar'].toString(),
        'govEn': gov['name_en'].toString(),
        'type': 'delegation',
      });
    }

    // حساب الأسماء المتكررة بعد دمج المراكز والمعتمديات.
    final counts = <String, int>{};

    for (final record in records) {
      final name = record['nameAr']!;
      counts[name] = (counts[name] ?? 0) + 1;
    }

    final result = <StationOption>[];

    for (final record in records) {
      final nameAr = record['nameAr']!;
      final nameEn = record['nameEn']!;
      final govAr = record['govAr']!;
      final govEn = record['govEn']!;
      final isCenter = record['type'] == 'center';
      final isRepeated = counts[nameAr]! > 1;

      String labelAr;
      String labelEn;

      if (isCenter) {
        labelAr = '$nameAr — مركز ولاية $govAr';
        labelEn = '$nameEn — $govEn Governorate Center';
      } else if (isRepeated) {
        labelAr = '$nameAr — $govAr';
        labelEn = '$nameEn — $govEn';
      } else {
        labelAr = nameAr;
        labelEn = nameEn;
      }

      result.add(
        StationOption(
          id: record['id']!,
          // نحافظ على الاسم العربي الأساسي المتوافق مع الخادم.
          value: nameAr,
          nameAr: nameAr,
          nameEn: nameEn,
          labelAr: labelAr,
          labelEn: labelEn,
        ),
      );
    }

    return result;
  }
}
