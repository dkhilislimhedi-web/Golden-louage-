
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { initializeApp } = require("firebase-admin/app");
const {
  getFirestore,
  Timestamp,
  FieldValue,
} = require("firebase-admin/firestore");
const crypto = require("crypto");

initializeApp();

const db = getFirestore();

const HOLD_SECONDS = 60;
const MAX_SEATS = 8;
const MAX_ALTERNATIVE_TRIPS = 30;

// --------------------------------------------------
// أدوات مساعدة
// --------------------------------------------------

function requireAuth(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "يرجى تسجيل الدخول أولاً.");
  }
  return request.auth.uid;
}

function validateText(value, field, max = 100) {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `${field} غير صالح.`);
  }

  const result = value.trim();

  if (!result || result.length > max) {
    throw new HttpsError("invalid-argument", `${field} مطلوب أو غير صالح.`);
  }

  return result;
}

function validateDate(value) {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}$/.test(value)
  ) {
    throw new HttpsError(
      "invalid-argument",
      "التاريخ يجب أن يكون بصيغة YYYY-MM-DD."
    );
  }

  const date = new Date(`${value}T00:00:00.000Z`);

  if (
    Number.isNaN(date.getTime()) ||
    date.toISOString().slice(0, 10) !== value
  ) {
    throw new HttpsError("invalid-argument", "التاريخ غير صحيح.");
  }

  return value;
}

function validateTime(value) {
  if (
    typeof value !== "string" ||
    !/^([01]\d|2[0-3]):[0-5]\d$/.test(value)
  ) {
    throw new HttpsError(
      "invalid-argument",
      "الساعة يجب أن تكون بصيغة HH:mm."
    );
  }

  return value;
}

function validateSeatCount(value) {
  const seats = Number(value);

  if (!Number.isInteger(seats) || seats < 1 || seats > MAX_SEATS) {
    throw new HttpsError(
      "invalid-argument",
      `عدد المقاعد يجب أن يكون بين 1 و ${MAX_SEATS}.`
    );
  }

  return seats;
}

function routeKey(value) {
  return value.normalize("NFKC").trim().toLowerCase();
}

function makeLockId(tripId, seat) {
  return crypto
    .createHash("sha256")
    .update(`${tripId}|${seat}`)
    .digest("hex");
}

function lockIsOccupied(lockData, now) {
  if (!lockData) return false;

  if (["confirmed", "accepted"].includes(lockData.status)) {
    return true;
  }

  if (lockData.status === "held") {
    return (
      lockData.expiresAt &&
      lockData.expiresAt.toMillis() > now.toMillis()
    );
  }

  return false;
}

async function checkActiveDriver(uid, transaction = null) {
  const ref = db.collection("drivers").doc(uid);
  const snap = transaction
    ? await transaction.get(ref)
    : await ref.get();

  if (!snap.exists) {
    throw new HttpsError(
      "permission-denied",
      "حساب السائق غير موجود."
    );
  }

  const driver = snap.data();

  if (driver.status !== "approved" || driver.active !== true) {
    throw new HttpsError(
      "permission-denied",
      "حسابك غير معتمد أو تم إيقاف نشاطه."
    );
  }

  return driver;
}

// --------------------------------------------------
// 1. السائق ينشئ رحلة
// --------------------------------------------------

exports.createTrip = onCall(async (request) => {
  const uid = requireAuth(request);

  const departure = validateText(request.data.departure, "نقطة الانطلاق");
  const destination = validateText(request.data.destination, "الوجهة");
  const travelDate = validateDate(request.data.travelDate);
  const travelTime = validateTime(request.data.travelTime);

  const totalSeats = validateSeatCount(
    request.data.totalSeats ?? MAX_SEATS
  );

  if (routeKey(departure) === routeKey(destination)) {
    throw new HttpsError(
      "invalid-argument",
      "نقطة الانطلاق والوجهة يجب أن تكونا مختلفتين."
    );
  }

  await checkActiveDriver(uid);

  const tripRef = db.collection("trips").doc();

  await tripRef.set({
    tripId: tripRef.id,
    driverUid: uid,
    departure,
    destination,
    departureKey: routeKey(departure),
    destinationKey: routeKey(destination),
    travelDate,
    travelTime,
    totalSeats,
    availableSeats: totalSeats,
    status: "open",
    createdAt: FieldValue.serverTimestamp(),
  });

  return {
    success: true,
    tripId: tripRef.id,
    message: "تم إنشاء الرحلة بنجاح.",
  };
});

// --------------------------------------------------
// 2. الراكب يحجز مقعداً في رحلة
// --------------------------------------------------

exports.createBooking = onCall(async (request) => {
  const uid = requireAuth(request);

  const tripId = validateText(request.data.tripId, "رقم الرحلة", 150);
  const contact = validateText(request.data.contact, "رقم الاتصال", 30);

  const seat = Number(request.data.seat);

  if (!Number.isInteger(seat) || seat < 1 || seat > MAX_SEATS) {
    throw new HttpsError("invalid-argument", "رقم المقعد غير صالح.");
  }

  const tripRef = db.collection("trips").doc(tripId);
  const bookingRef = db.collection("booking_requests").doc();

  const lockId = makeLockId(tripId, seat);
  const lockRef = db.collection("seat_locks").doc(lockId);

  const now = Timestamp.now();
  const expiresAt = Timestamp.fromMillis(
    now.toMillis() + HOLD_SECONDS * 1000
  );

  await db.runTransaction(async (transaction) => {
    const tripSnap = await transaction.get(tripRef);
    const lockSnap = await transaction.get(lockRef);

    if (!tripSnap.exists) {
      throw new HttpsError("not-found", "الرحلة غير موجودة.");
    }

    const trip = tripSnap.data();

    if (trip.status !== "open") {
      throw new HttpsError(
        "failed-precondition",
        "هذه الرحلة غير متاحة."
      );
    }

    if (trip.driverUid === uid) {
      throw new HttpsError(
        "failed-precondition",
        "لا يمكنك حجز رحلتك الخاصة."
      );
    }

    if (seat > trip.totalSeats || trip.availableSeats < 1) {
      throw new HttpsError(
        "failed-precondition",
        "لا توجد مقاعد متاحة في هذه الرحلة."
      );
    }

    if (
      lockSnap.exists &&
      lockIsOccupied(lockSnap.data(), now)
    ) {
      throw new HttpsError(
        "already-exists",
        "هذا المقعد محجوز بالفعل."
      );
    }

    transaction.set(bookingRef, {
      uid,
      driverUid: trip.driverUid,
      tripId,
      departure: trip.departure,
      destination: trip.destination,
      travelDate: trip.travelDate,
      travelTime: trip.travelTime,
      contact,
      seat,
      status: "held",
      seatLockId: lockId,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt,
    });

    transaction.set(lockRef, {
      tripId,
      bookingId: bookingRef.id,
      uid,
      seat,
      status: "held",
      expiresAt,
      updatedAt: FieldValue.serverTimestamp(),
    });

    transaction.update(tripRef, {
      availableSeats: FieldValue.increment(-1),
    });
  });

  return {
    success: true,
    bookingId: bookingRef.id,
    expiresInSeconds: HOLD_SECONDS,
    message: "تم حجز المقعد مؤقتاً. يرجى تأكيد الحجز.",
  };
});

// --------------------------------------------------
// 3. الراكب يؤكد الحجز
// --------------------------------------------------

exports.confirmBooking = onCall(async (request) => {
  const uid = requireAuth(request);

  const bookingId = validateText(
    request.data.bookingId,
    "رقم الحجز",
    150
  );

  const bookingRef = db.collection("booking_requests").doc(bookingId);

  let expired = false;

  await db.runTransaction(async (transaction) => {
    const bookingSnap = await transaction.get(bookingRef);

    if (!bookingSnap.exists) {
      throw new HttpsError("not-found", "الحجز غير موجود.");
    }

    const booking = bookingSnap.data();

    if (booking.uid !== uid) {
      throw new HttpsError(
        "permission-denied",
        "هذا الحجز لا يخص حسابك."
      );
    }

    if (booking.status !== "held") {
      throw new HttpsError(
        "failed-precondition",
        "الحجز ليس في انتظار التأكيد."
      );
    }

    const lockRef = db.collection("seat_locks").doc(booking.seatLockId);
    const tripRef = db.collection("trips").doc(booking.tripId);

    const lockSnap = await transaction.get(lockRef);

    if (!lockSnap.exists || lockSnap.data().bookingId !== bookingId) {
      throw new HttpsError(
        "failed-precondition",
        "تعذر التحقق من المقعد."
      );
    }

    const lock = lockSnap.data();

    if (
      !booking.expiresAt ||
      booking.expiresAt.toMillis() <= Timestamp.now().toMillis()
    ) {
      transaction.update(bookingRef, {
        status: "expired",
        expiredAt: FieldValue.serverTimestamp(),
      });

      transaction.update(lockRef, {
        status: "expired",
        updatedAt: FieldValue.serverTimestamp(),
      });

      transaction.update(tripRef, {
        availableSeats: FieldValue.increment(1),
      });

      expired = true;
      return;
    }

    transaction.update(bookingRef, {
      status: "confirmed",
      confirmedAt: FieldValue.serverTimestamp(),
    });

    transaction.update(lockRef, {
      status: "confirmed",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  if (expired) {
    throw new HttpsError(
      "deadline-exceeded",
      "انتهت مهلة تأكيد الحجز."
    );
  }

  return {
    success: true,
    message: "تم تأكيد الحجز بنجاح.",
  };
});

// --------------------------------------------------
// 4. البحث عن رحلة بديلة ونقل الحجز تلقائياً
// --------------------------------------------------

async function findAndTransferBooking(
  transaction,
  bookingRef,
  booking,
  oldLockRef,
  oldTripRef,
  now
) {
  const alternativesQuery = db
    .collection("trips")
    .where("departureKey", "==", routeKey(booking.departure))
    .where("destinationKey", "==", routeKey(booking.destination))
    .where("travelDate", "==", booking.travelDate)
    .where("travelTime", "==", booking.travelTime)
    .where("status", "==", "open")
    .limit(MAX_ALTERNATIVE_TRIPS);

  const alternativesSnap = await transaction.get(alternativesQuery);

  const candidates = [];

  for (const tripDoc of alternativesSnap.docs) {
    const trip = tripDoc.data();

    if (
      tripDoc.id === booking.tripId ||
      trip.driverUid === booking.driverUid ||
      trip.availableSeats < 1
    ) {
      continue;
    }

    const driverRef = db.collection("drivers").doc(trip.driverUid);
    const driverSnap = await transaction.get(driverRef);

    if (!driverSnap.exists) continue;

    const driver = driverSnap.data();

    if (driver.status !== "approved" || driver.active !== true) {
      continue;
    }

    for (let seat = 1; seat <= trip.totalSeats; seat++) {
      const newLockId = makeLockId(tripDoc.id, seat);
      const newLockRef = db.collection("seat_locks").doc(newLockId);
      const newLockSnap = await transaction.get(newLockRef);

      const lockData = newLockSnap.exists
        ? newLockSnap.data()
        : null;

      if (!lockIsOccupied(lockData, now)) {
        candidates.push({
          tripRef: tripDoc.ref,
          trip,
          driverUid: trip.driverUid,
          seat,
          lockRef: newLockRef,
          lockId: newLockId,
        });
        break;
      }
    }
  }

  if (candidates.length === 0) {
    transaction.update(bookingRef, {
      status: "awaiting_reassignment",
      previousDriverUid: booking.driverUid,
      reassignmentUpdatedAt: FieldValue.serverTimestamp(),
    });

    transaction.update(oldLockRef, {
      status: "released",
      updatedAt: FieldValue.serverTimestamp(),
    });

    transaction.update(oldTripRef, {
      availableSeats: FieldValue.increment(1),
    });

    return false;
  }

  const chosen = candidates[0];

  transaction.update(oldLockRef, {
    status: "released",
    updatedAt: FieldValue.serverTimestamp(),
  });

  transaction.update(oldTripRef, {
    availableSeats: FieldValue.increment(1),
  });

  transaction.set(chosen.lockRef, {
    tripId: chosen.tripRef.id,
    bookingId: bookingRef.id,
    uid: booking.uid,
    seat: chosen.seat,
    status: "confirmed",
    updatedAt: FieldValue.serverTimestamp(),
  });

  transaction.update(chosen.tripRef, {
    availableSeats: FieldValue.increment(-1),
  });

  transaction.update(bookingRef, {
    driverUid: chosen.driverUid,
    tripId: chosen.tripRef.id,
    departure: chosen.trip.departure,
    destination: chosen.trip.destination,
    travelDate: chosen.trip.travelDate,
    travelTime: chosen.trip.travelTime,
    seat: chosen.seat,
    seatLockId: chosen.lockId,
    status: "confirmed",
    reassignedAt: FieldValue.serverTimestamp(),
    previousDriverUid: booking.driverUid,
  });

  return true;
}

// --------------------------------------------------
// 5. السائق يقبل أو يرفض الحجز
// --------------------------------------------------

exports.respondToBooking = onCall(async (request) => {
  const uid = requireAuth(request);

  const bookingId = validateText(
    request.data.bookingId,
    "رقم الحجز",
    150
  );

  if (typeof request.data.accept !== "boolean") {
    throw new HttpsError(
      "invalid-argument",
      "اختيار القبول أو الرفض غير صحيح."
    );
  }

  const accept = request.data.accept;
  const bookingRef = db.collection("booking_requests").doc(bookingId);

  let transferred = false;

  await db.runTransaction(async (transaction) => {
    const bookingSnap = await transaction.get(bookingRef);

    if (!bookingSnap.exists) {
      throw new HttpsError("not-found", "الحجز غير موجود.");
    }

    const booking = bookingSnap.data();

    if (booking.driverUid !== uid) {
      throw new HttpsError(
        "permission-denied",
        "هذا الحجز غير موجه إليك."
      );
    }

    if (booking.status !== "confirmed") {
      throw new HttpsError(
        "failed-precondition",
        "الحجز لم يعد في انتظار ردك."
      );
    }

    const driverRef = db.collection("drivers").doc(uid);
    const driverSnap = await transaction.get(driverRef);

    if (
      !driverSnap.exists ||
      driverSnap.data().status !== "approved" ||
      driverSnap.data().active !== true
    ) {
      throw new HttpsError(
        "permission-denied",
        "حساب السائق غير معتمد أو غير نشط."
      );
    }

    const oldLockRef = db
      .collection("seat_locks")
      .doc(booking.seatLockId);

    const oldTripRef = db
      .collection("trips")
      .doc(booking.tripId);

    const lockSnap = await transaction.get(oldLockRef);
    const tripSnap = await transaction.get(oldTripRef);

    if (
      !lockSnap.exists ||
      lockSnap.data().bookingId !== bookingId ||
      lockSnap.data().status !== "confirmed"
    ) {
      throw new HttpsError(
        "failed-precondition",
        "تعذر التحقق من المقعد المحجوز."
      );
    }

    if (!tripSnap.exists) {
      throw new HttpsError(
        "not-found",
        "الرحلة المرتبطة بالحجز غير موجودة."
      );
    }

    if (accept) {
      transaction.update(bookingRef, {
        status: "accepted",
        respondedAt: FieldValue.serverTimestamp(),
      });

      transaction.update(oldLockRef, {
        status: "accepted",
        updatedAt: FieldValue.serverTimestamp(),
      });
    } else {
      transferred = await findAndTransferBooking(
        transaction,
        bookingRef,
        booking,
        oldLockRef,
        oldTripRef,
        Timestamp.now()
      );
    }
  });

  return {
    success: true,
    status: accept
      ? "accepted"
      : transferred
        ? "reassigned"
        : "awaiting_reassignment",
    message: accept
      ? "تم قبول الحجز."
      : transferred
        ? "تم نقل الحجز تلقائياً إلى سائق آخر."
        : "لم تتوفر رحلة مطابقة حالياً. الحجز محفوظ بانتظار إعادة التوجيه.",
  };
});

// --------------------------------------------------
// 6. تحرير الحجوزات المؤقتة التي لم يتم تأكيدها
// --------------------------------------------------

exports.releaseExpiredSeats = onSchedule(
  "* * * * *",
  async () => {
    const now = Timestamp.now();

    const expiredLocks = await db
      .collection("seat_locks")
      .where("status", "==", "held")
      .where("expiresAt", "<=", now)
      .limit(200)
      .get();

    for (const lockDoc of expiredLocks.docs) {
      await db.runTransaction(async (transaction) => {
        const lockSnap = await transaction.get(lockDoc.ref);

        if (!lockSnap.exists) return;

        const lock = lockSnap.data();

        if (
          lock.status !== "held" ||
          !lock.expiresAt ||
          lock.expiresAt.toMillis() > Timestamp.now().toMillis()
        ) {
          return;
        }

        const bookingRef = db
          .collection("booking_requests")
          .doc(lock.bookingId);

        const bookingSnap = await transaction.get(bookingRef);

        const tripRef = db.collection("trips").doc(lock.tripId);
        const tripSnap = await transaction.get(tripRef);

        if (bookingSnap.exists && bookingSnap.data().status === "held") {
          transaction.update(bookingRef, {
            status: "expired",
            expiredAt: FieldValue.serverTimestamp(),
          });
        }

        transaction.update(lockDoc.ref, {
          status: "expired",
          updatedAt: FieldValue.serverTimestamp(),
        });

        if (tripSnap.exists) {
          transaction.update(tripRef, {
            availableSeats: FieldValue.increment(1),
          });
        }
      });
    }
  }
);
