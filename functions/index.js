
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, Timestamp, FieldValue } = require("firebase-admin/firestore");
const crypto = require("crypto");

initializeApp();

const db = getFirestore();
const HOLD_SECONDS = 60;

function requireAuth(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً.");
  }
  return request.auth.uid;
}

function makeSeatLockId(data) {
  const key = [
    data.departure.trim().toLowerCase(),
    data.destination.trim().toLowerCase(),
    data.travelDate,
    data.travelTime,
    String(data.seat),
  ].join("|");

  return crypto.createHash("sha256").update(key).digest("hex");
}

exports.createBooking = onCall(async (request) => {
  const uid = requireAuth(request);
  const {
    departure,
    destination,
    travelDate,
    travelTime,
    seat,
    contact,
  } = request.data || {};

  if (
    typeof departure !== "string" ||
    !departure.trim() ||
    typeof destination !== "string" ||
    !destination.trim() ||
    typeof travelDate !== "string" ||
    !/^\d{4}-\d{2}-\d{2}$/.test(travelDate) ||
    typeof travelTime !== "string" ||
    !/^([01]\d|2[0-3]):[0-5]\d$/.test(travelTime) ||
    !Number.isInteger(seat) ||
    seat < 1 ||
    seat > 8 ||
    typeof contact !== "string" ||
    !contact.trim()
  ) {
    throw new HttpsError("invalid-argument", "تحقق من بيانات الحجز.");
  }

  if (departure.trim().toLowerCase() === destination.trim().toLowerCase()) {
    throw new HttpsError("invalid-argument", "مكان الانطلاق والوصول يجب أن يختلفا.");
  }

  const now = Timestamp.now();
  const expiresAt = Timestamp.fromMillis(
    now.toMillis() + HOLD_SECONDS * 1000
  );

  const bookingRef = db.collection("booking_requests").doc();
  const lockId = makeSeatLockId({
    departure,
    destination,
    travelDate,
    travelTime,
    seat,
  });
  const lockRef = db.collection("seat_locks").doc(lockId);

  await db.runTransaction(async (tx) => {
    const lockSnap = await tx.get(lockRef);

    if (lockSnap.exists) {
      const lock = lockSnap.data();
      const lockExpiry = lock.expiresAt;
      const lockIsExpired =
        lock.status === "held" &&
        lockExpiry &&
        lockExpiry.toMillis() <= now.toMillis();

      if (
        lock.status === "confirmed" ||
        (lock.status === "held" && !lockIsExpired)
      ) {
        throw new HttpsError(
          "already-exists",
          "هذا المقعد محجوز أو مؤقت لشخص آخر."
        );
      }
    }

    tx.set(bookingRef, {
      uid,
      contact: contact.trim(),
      departure: departure.trim(),
      destination: destination.trim(),
      travelDate,
      travelTime,
      seat,
      driverUid: "",
      status: "held",
      seatLockId: lockId,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt,
    });

    tx.set(lockRef, {
      bookingId: bookingRef.id,
      uid,
      status: "held",
      expiresAt,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return {
    bookingId: bookingRef.id,
    expiresAt: expiresAt.toDate().toISOString(),
    holdSeconds: HOLD_SECONDS,
  };
});

exports.confirmBooking = onCall(async (request) => {
  const uid = requireAuth(request);
  const bookingId = request.data?.bookingId;

  if (typeof bookingId !== "string" || !bookingId.trim()) {
    throw new HttpsError("invalid-argument", "رقم الحجز غير صالح.");
  }

  const bookingRef = db.collection("booking_requests").doc(bookingId);

  await db.runTransaction(async (tx) => {
    const bookingSnap = await tx.get(bookingRef);

    if (!bookingSnap.exists) {
      throw new HttpsError("not-found", "الحجز غير موجود.");
    }

    const booking = bookingSnap.data();

    if (booking.uid !== uid) {
      throw new HttpsError("permission-denied", "هذا الحجز لا يخص حسابك.");
    }

    if (booking.status !== "held") {
      throw new HttpsError("failed-precondition", "الحجز ليس في حالة انتظار التأكيد.");
    }

    if (!booking.expiresAt || booking.expiresAt.toMillis() <= Date.now()) {
      tx.update(bookingRef, { status: "expired" });

      if (booking.seatLockId) {
        const lockRef = db.collection("seat_locks").doc(booking.seatLockId);
        const lockSnap = await tx.get(lockRef);

        if (lockSnap.exists && lockSnap.data().bookingId === bookingId) {
          tx.update(lockRef, { status: "expired" });
        }
      }

      throw new HttpsError("deadline-exceeded", "انتهت مهلة تأكيد المقعد.");
    }

    const lockRef = db.collection("seat_locks").doc(booking.seatLockId);
    const lockSnap = await tx.get(lockRef);

    if (
      !lockSnap.exists ||
      lockSnap.data().bookingId !== bookingId ||
      lockSnap.data().status !== "held"
    ) {
      throw new HttpsError("failed-precondition", "لم يعد المقعد محجوزًا لك.");
    }

    tx.update(bookingRef, {
      status: "confirmed",
      confirmedAt: FieldValue.serverTimestamp(),
    });

    tx.update(lockRef, {
      status: "confirmed",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return { success: true, message: "تم تأكيد الحجز." };
});

exports.respondToBooking = onCall(async (request) => {
  const uid = requireAuth(request);
  const { bookingId, accept } = request.data || {};

  if (
    typeof bookingId !== "string" ||
    !bookingId.trim() ||
    typeof accept !== "boolean"
  ) {
    throw new HttpsError("invalid-argument", "بيانات الرد غير صالحة.");
  }

  const driverRef = db.collection("drivers").doc(uid);
  const bookingRef = db.collection("booking_requests").doc(bookingId);

  await db.runTransaction(async (tx) => {
    const driverSnap = await tx.get(driverRef);
    const bookingSnap = await tx.get(bookingRef);

    if (!driverSnap.exists) {
      throw new HttpsError("permission-denied", "حساب السائق غير موجود.");
    }

    const driver = driverSnap.data();

    if (driver.status !== "approved" || driver.active !== true) {
      throw new HttpsError("permission-denied", "حسابك غير معتمد أو غير نشط.");
    }

    if (!bookingSnap.exists) {
      throw new HttpsError("not-found", "الحجز غير موجود.");
    }

    const booking = bookingSnap.data();

    if (booking.driverUid !== uid) {
      throw new HttpsError("permission-denied", "الحجز غير مسند إليك.");
    }

    if (booking.status !== "confirmed") {
      throw new HttpsError("failed-precondition", "الحجز ليس مؤكّدًا.");
    }

    tx.update(bookingRef, {
      status: accept ? "accepted" : "rejected",
      driverRespondedAt: FieldValue.serverTimestamp(),
    });
  });

  return { success: true };
});

exports.releaseExpiredSeats = onSchedule("every 1 minutes", async () => {
  const now = Timestamp.now();

  const expiredLocks = await db
    .collection("seat_locks")
    .where("status", "==", "held")
    .where("expiresAt", "<=", now)
    .limit(200)
    .get();

  for (const lockDoc of expiredLocks.docs) {
    await db.runTransaction(async (tx) => {
      const currentLock = await tx.get(lockDoc.ref);

      if (!currentLock.exists) return;

      const lock = currentLock.data();

      if (
        lock.status !== "held" ||
        !lock.expiresAt ||
        lock.expiresAt.toMillis() > Date.now()
      ) {
        return;
      }

      const bookingRef = db.collection("booking_requests").doc(lock.bookingId);
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
});
