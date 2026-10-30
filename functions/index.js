
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { initializeApp } = require("firebase-admin/app");
const {
  getFirestore,
  Timestamp,
  FieldValue,
} = require("firebase-admin/firestore");

initializeApp();

const db = getFirestore();
const HOLD_SECONDS = 60;
const SEAT_COUNT = 8;

function requireAuth(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً.");
  }
  return request.auth.uid;
}

function validateText(value, message) {
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", message);
  }
  return value.trim();
}

function validateTime(value, message) {
  if (
    typeof value !== "string" ||
    !/^([01]\d|2[0-3]):[0-5]\d$/.test(value)
  ) {
    throw new HttpsError("invalid-argument", message);
  }
  return value;
}

function validateDate(value) {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}$/.test(value)
  ) {
    throw new HttpsError("invalid-argument", "تاريخ الرحلة غير صالح.");
  }

  const date = new Date(`${value}T00:00:00Z`);

  if (
    Number.isNaN(date.getTime()) ||
    date.toISOString().slice(0, 10) !== value
  ) {
    throw new HttpsError("invalid-argument", "تاريخ الرحلة غير صالح.");
  }

  return value;
}

async function requireActiveDriver(uid, tx) {
  const driverRef = db.collection("drivers").doc(uid);
  const driverSnap = await tx.get(driverRef);

  if (!driverSnap.exists) {
    throw new HttpsError("permission-denied", "حساب السائق غير موجود.");
  }

  const driver = driverSnap.data();

  if (driver.status !== "approved" || driver.active !== true) {
    throw new HttpsError(
      "permission-denied",
      "حسابك غير معتمد أو غير نشط."
    );
  }

  const vehicle = validateText(
    driver.vehicle,
    "نوع السيارة غير مسجل في حسابك."
  );

  const plate = validateText(
    driver.plate,
    "رقم تسجيل السيارة غير مسجل في حسابك."
  );

  return { driverRef, driver, vehicle, plate };
}

// إعداد رحلة جديدة أو رحلة قادمة
exports.prepareNextTrip = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};

  const departure = validateText(data.departure, "مكان الانطلاق مطلوب.");
  const destination = validateText(data.destination, "مكان الوصول مطلوب.");
  const travelDate = validateDate(data.travelDate);

  const departureWindowStart = validateTime(
    data.departureWindowStart,
    "وقت بداية الانطلاق غير صالح."
  );

  const departureWindowEnd = validateTime(
    data.departureWindowEnd,
    "وقت نهاية الانطلاق غير صالح."
  );

  if (departure.toLowerCase() === destination.toLowerCase()) {
    throw new HttpsError(
      "invalid-argument",
      "مكان الانطلاق والوصول يجب أن يختلفا."
    );
  }

  if (departureWindowStart >= departureWindowEnd) {
    throw new HttpsError(
      "invalid-argument",
      "وقت نهاية الانطلاق يجب أن يكون بعد وقت البداية."
    );
  }

  const tripRef = db.collection("trips").doc();

  const result = await db.runTransaction(async (tx) => {
    const driverInfo = await requireActiveDriver(uid, tx);

    const openQuery = db.collection("trips")
      .where("driverUid", "==", uid)
      .where("status", "==", "open");

    const preparedQuery = db.collection("trips")
      .where("driverUid", "==", uid)
      .where("status", "==", "prepared");

    const openSnap = await tx.get(openQuery);
    const preparedSnap = await tx.get(preparedQuery);

    if (!preparedSnap.empty) {
      throw new HttpsError(
        "failed-precondition",
        "لديك رحلة قادمة مجهزة بالفعل."
      );
    }

    if (openSnap.size > 1) {
      throw new HttpsError(
        "failed-precondition",
        "لديك أكثر من رحلة مفتوحة."
      );
    }

    const initialTrip = openSnap.empty;

    tx.create(tripRef, {
      driverUid: uid,
      vehicle: driverInfo.vehicle,
      plate: driverInfo.plate,
      departure,
      destination,
      travelDate,
      departureWindowStart,
      departureWindowEnd,
      status: initialTrip ? "open" : "prepared",
      availableSeats: SEAT_COUNT,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    return {
      tripId: tripRef.id,
      status: initialTrip ? "open" : "prepared",
    };
  });

  return {
    success: true,
    ...result,
    message: result.status === "open"
      ? "تم فتح الرحلة الأولى للحجز."
      : "تم تجهيز الرحلة القادمة.",
  };
});

// انطلاق الرحلة الحالية وفتح الرحلة القادمة
exports.startTrip = onCall(async (request) => {
  const uid = requireAuth(request);

  const currentTripId = validateText(
    request.data?.currentTripId,
    "رقم الرحلة الحالية مطلوب."
  );

  const nextTripId = request.data?.nextTripId;

  if (
    nextTripId !== undefined &&
    (typeof nextTripId !== "string" || !nextTripId.trim())
  ) {
    throw new HttpsError("invalid-argument", "رقم الرحلة القادمة غير صالح.");
  }

  if (nextTripId && nextTripId === currentTripId) {
    throw new HttpsError("invalid-argument", "الرحلتان يجب أن تختلفا.");
  }

  const currentRef = db.collection("trips").doc(currentTripId);
  const nextRef = nextTripId
    ? db.collection("trips").doc(nextTripId)
    : null;

  await db.runTransaction(async (tx) => {
    await requireActiveDriver(uid, tx);

    const currentSnap = await tx.get(currentRef);

    if (!currentSnap.exists) {
      throw new HttpsError("not-found", "الرحلة الحالية غير موجودة.");
    }

    const current = currentSnap.data();

    if (current.driverUid !== uid || current.status !== "open") {
      throw new HttpsError(
        "failed-precondition",
        "الرحلة الحالية غير مفتوحة أو لا تخصك."
      );
    }

    if (nextRef) {
      const nextSnap = await tx.get(nextRef);

      if (!nextSnap.exists) {
        throw new HttpsError("not-found", "الرحلة القادمة غير موجودة.");
      }

      const next = nextSnap.data();

      if (
        next.driverUid !== uid ||
        next.status !== "prepared" ||
        next.vehicle !== current.vehicle ||
        next.plate !== current.plate
      ) {
        throw new HttpsError(
          "failed-precondition",
          "الرحلة القادمة غير صالحة."
        );
      }
    } else {
      const preparedQuery = db.collection("trips")
        .where("driverUid", "==", uid)
        .where("status", "==", "prepared");

      const preparedSnap = await tx.get(preparedQuery);

      if (!preparedSnap.empty) {
        throw new HttpsError(
          "failed-precondition",
          "يجب تحديد الرحلة القادمة المجهزة."
        );
      }
    }

    tx.update(currentRef, {
      status: "departed",
      departedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    if (nextRef) {
      tx.update(nextRef, {
        status: "open",
        openedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
  });

  return {
    success: true,
    message: nextRef
      ? "تم الانطلاق وفتح الرحلة القادمة."
      : "تم إغلاق الرحلة الحالية.",
  };
});

// إنشاء حجز مرتبط برحلة ومقعد محدد
exports.createBooking = onCall(async (request) => {
  const uid = requireAuth(request);

  const tripId = validateText(request.data?.tripId, "رقم الرحلة مطلوب.");
  const contact = validateText(request.data?.contact, "رقم الاتصال مطلوب.");
  const seat = request.data?.seat;

  if (!Number.isInteger(seat) || seat < 1 || seat > SEAT_COUNT) {
    throw new HttpsError("invalid-argument", "رقم المقعد غير صالح.");
  }

  const tripRef = db.collection("trips").doc(tripId);
  const bookingRef = db.collection("booking_requests").doc();
  const lockRef = db.collection("seat_locks").doc(`${tripId}_${seat}`);

  const now = Timestamp.now();
  const expiresAt = Timestamp.fromMillis(
    now.toMillis() + HOLD_SECONDS * 1000
  );

  await db.runTransaction(async (tx) => {
    const tripSnap = await tx.get(tripRef);
    const lockSnap = await tx.get(lockRef);

    if (!tripSnap.exists) {
      throw new HttpsError("not-found", "الرحلة غير موجودة.");
    }

    const trip = tripSnap.data();

    if (trip.status !== "open") {
      throw new HttpsError(
        "failed-precondition",
        "هذه الرحلة غير متاحة للحجز."
      );
    }

    if (trip.driverUid === uid) {
      throw new HttpsError(
        "permission-denied",
        "لا يمكنك حجز مقعد في رحلتك الخاصة."
      );
    }

    if (lockSnap.exists) {
      const lock = lockSnap.data();

      const expired =
        lock.status === "held" &&
        lock.expiresAt &&
        lock.expiresAt.toMillis() <= now.toMillis();

      const reusable = ["expired", "released", "rejected"].includes(
        lock.status
      );

      if (!expired && !reusable) {
        throw new HttpsError(
          "already-exists",
          "هذا المقعد محجوز أو مؤقت لشخص آخر."
        );
      }
    }

    tx.set(bookingRef, {
      uid,
      tripId,
      driverUid: trip.driverUid,
      vehicle: trip.vehicle,
      plate: trip.plate,
      departure: trip.departure,
      destination: trip.destination,
      travelDate: trip.travelDate,
      departureWindowStart: trip.departureWindowStart,
      departureWindowEnd: trip.departureWindowEnd,
      seat,
      contact,
      status: "held",
      seatLockId: lockRef.id,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt,
    });

    tx.set(lockRef, {
      bookingId: bookingRef.id,
      tripId,
      seat,
      uid,
      status: "held",
      expiresAt,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return {
    bookingId: bookingRef.id,
    tripId,
    expiresAt: expiresAt.toDate().toISOString(),
    holdSeconds: HOLD_SECONDS,
  };
});

// تأكيد الحجز وإصلاح انتهاء المهلة
exports.confirmBooking = onCall(async (request) => {
  const uid = requireAuth(request);

  const bookingId = validateText(
    request.data?.bookingId,
    "رقم الحجز غير صالح."
  );

  const bookingRef = db.collection("booking_requests").doc(bookingId);

  const result = await db.runTransaction(async (tx) => {
    const bookingSnap = await tx.get(bookingRef);

    if (!bookingSnap.exists) {
      throw new HttpsError("not-found", "الحجز غير موجود.");
    }

    const booking = bookingSnap.data();

    if (booking.uid !== uid) {
      throw new HttpsError("permission-denied", "هذا الحجز لا يخص حسابك.");
    }

    if (booking.status !== "held") {
      throw new HttpsError(
        "failed-precondition",
        "الحجز ليس في حالة انتظار التأكيد."
      );
    }

    const lockRef = db.collection("seat_locks").doc(booking.seatLockId);
    const tripRef = db.collection("trips").doc(booking.tripId);

    const lockSnap = await tx.get(lockRef);
    const tripSnap = await tx.get(tripRef);

    if (
      !booking.expiresAt ||
      booking.expiresAt.toMillis() <= Date.now()
    ) {
      if (
        lockSnap.exists &&
        lockSnap.data().bookingId === bookingId
      ) {
        tx.update(lockRef, {
          status: "expired",
          updatedAt: FieldValue.serverTimestamp(),
        });
      }

      tx.update(bookingRef, { status: "expired" });
      return { expired: true };
    }

    if (
      !lockSnap.exists ||
      lockSnap.data().bookingId !== bookingId ||
      lockSnap.data().status !== "held"
    ) {
      throw new HttpsError(
        "failed-precondition",
        "لم يعد المقعد محجوزاً لك."
      );
    }

    if (!tripSnap.exists || tripSnap.data().status !== "open") {
      tx.update(lockRef, {
        status: "released",
        updatedAt: FieldValue.serverTimestamp(),
      });

      tx.update(bookingRef, { status: "cancelled" });
      return { unavailable: true };
    }

    tx.update(bookingRef, {
      status: "confirmed",
      confirmedAt: FieldValue.serverTimestamp(),
    });

    tx.update(lockRef, {
      status: "confirmed",
      updatedAt: FieldValue.serverTimestamp(),
    });

    return { success: true };
  });

  if (result.expired) {
    throw new HttpsError(
      "deadline-exceeded",
      "انتهت مهلة تأكيد المقعد."
    );
  }

  if (result.unavailable) {
    throw new HttpsError(
      "failed-precondition",
      "انطلقت الرحلة ولم يعد الحجز متاحاً."
    );
  }

  return { success: true, message: "تم تأكيد الحجز." };
});

// رد السائق على الحجز
exports.respondToBooking = onCall(async (request) => {
  const uid = requireAuth(request);

  const bookingId = validateText(
    request.data?.bookingId,
    "رقم الحجز غير صالح."
  );

  const accept = request.data?.accept;

  if (typeof accept !== "boolean") {
    throw new HttpsError("invalid-argument", "بيانات الرد غير صالحة.");
  }

  const bookingRef = db.collection("booking_requests").doc(bookingId);

  await db.runTransaction(async (tx) => {
    await requireActiveDriver(uid, tx);

    const bookingSnap = await tx.get(bookingRef);

    if (!bookingSnap.exists) {
      throw new HttpsError("not-found", "الحجز غير موجود.");
    }

    const booking = bookingSnap.data();

    if (booking.driverUid !== uid) {
      throw new HttpsError("permission-denied", "الحجز غير مسند إليك.");
    }

    if (booking.status !== "confirmed") {
      throw new HttpsError(
        "failed-precondition",
        "الحجز ليس مؤكداً أو سبق الرد عليه."
      );
    }

    const tripRef = db.collection("trips").doc(booking.tripId);
    const tripSnap = await tx.get(tripRef);

    if (!tripSnap.exists || tripSnap.data().status !== "open") {
      throw new HttpsError(
        "failed-precondition",
        "الرحلة لم تعد مفتوحة."
      );
    }

    const lockRef = db.collection("seat_locks").doc(booking.seatLockId);
    const lockSnap = await tx.get(lockRef);

    if (
      !lockSnap.exists ||
      lockSnap.data().bookingId !== bookingId ||
      lockSnap.data().status !== "confirmed"
    ) {
      throw new HttpsError("failed-precondition", "قفل المقعد غير صالح.");
    }

    tx.update(bookingRef, {
      status: accept ? "accepted" : "rejected",
      driverRespondedAt: FieldValue.serverTimestamp(),
    });

    if (!accept) {
      tx.update(lockRef, {
        status: "rejected",
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
  });

  return {
    success: true,
    message: accept ? "تم قبول الحجز." : "تم رفض الحجز وتحرير المقعد.",
  };
});

// تحرير الحجوزات المؤقتة المنتهية
exports.releaseExpiredSeats = onSchedule(
  "every 1 minutes",
  async () => {
    const now = Timestamp.now();

    const expiredLocks = await db
      .collection("seat_locks")
      .where("status", "==", "held")
      .where("expiresAt", "<=", now)
      .limit(200)
      .get();

    for (const lockDoc of expiredLocks.docs) {
      await db.runTransaction(async (tx) => {
        const lockSnap = await tx.get(lockDoc.ref);

        if (!lockSnap.exists) return;

        const lock = lockSnap.data();

        if (
          lock.status !== "held" ||
          !lock.expiresAt ||
          lock.expiresAt.toMillis() > Date.now()
        ) {
          return;
        }

        const bookingRef = db.collection("booking_requests")
          .doc(lock.bookingId);

        const bookingSnap = await tx.get(bookingRef);

        tx.update(lockDoc.ref, {
          status: "expired",
          updatedAt: FieldValue.serverTimestamp(),
        });

        if (
          bookingSnap.exists &&
          bookingSnap.data().status === "held"
        ) {
          tx.update(bookingRef, { status: "expired" });
        }
      });
    }
  }
);
