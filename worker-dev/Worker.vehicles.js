
// ======================================================
// GOLDEN LOUAGE WORKER 5.4.0
// PART 1/7 — CORE, FIRESTORE & FIREBASE AUTH
// ======================================================

const VERSION = "5.4.0";
const PROJECT_ID = "golden-louage-9efcb";

const DB =
  `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents`;

const TOKEN_URL = "https://oauth2.googleapis.com/token";

const JWKS_URL =
  "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

const FIREBASE_ISSUER =
  `https://securetoken.google.com/${PROJECT_ID}`;

const GOOGLE_SCOPE =
  "https://www.googleapis.com/auth/datastore";

const SEATS = 8;
const HOLD_MS = 60 * 1000;
const TUNISIA_OFFSET_MS = 60 * 60 * 1000;
const MAX_QUERY_RESULTS = 200;

let googleTokenCache = null;
let firebaseKeysCache = null;

// ------------------------------------------------------
// HTTP RESPONSES & ERRORS
// ------------------------------------------------------

function response(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8"
    }
  });
}

function fail(message, status = 400) {
  return response({
    success: false,
    error: message
  }, status);
}

function httpError(message, status = 400) {
  return Object.assign(new Error(message), {
    status: Number(status) || 400
  });
}

function clean(value, max = 500) {
  return typeof value === "string"
    ? value.trim().slice(0, max)
    : "";
}

function makeId() {
  return crypto.randomUUID().replace(/-/g, "");
}

function nowISO() {
  return new Date().toISOString();
}

// ------------------------------------------------------
// BASE64 / JWT HELPERS
// ------------------------------------------------------

function b64url(bytes) {
  let value = "";

  for (const byte of new Uint8Array(bytes)) {
    value += String.fromCharCode(byte);
  }

  return btoa(value)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function unb64(value) {
  value = String(value)
    .replace(/-/g, "+")
    .replace(/_/g, "/");

  while (value.length % 4) {
    value += "=";
  }

  return Uint8Array.from(
    atob(value),
    character => character.charCodeAt(0)
  );
}

function decodePart(value) {
  return JSON.parse(
    new TextDecoder().decode(unb64(value))
  );
}

function pemBytes(pem) {
  const value = String(pem)
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");

  return unb64(value);
}

// ------------------------------------------------------
// FIRESTORE VALUE CONVERSION
// ------------------------------------------------------

function fv(value) {
  if (value === null || value === undefined) {
    return { nullValue: null };
  }

  if (typeof value === "string") {
    return { stringValue: value };
  }

  if (typeof value === "boolean") {
    return { booleanValue: value };
  }

  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error("قيمة رقمية غير صالحة.");
    }

    return Number.isInteger(value)
      ? { integerValue: String(value) }
      : { doubleValue: value };
  }

  if (value instanceof Date) {
    return { timestampValue: value.toISOString() };
  }

  if (Array.isArray(value)) {
    return {
      arrayValue: {
        values: value.map(fv)
      }
    };
  }

  if (typeof value === "object") {
    return {
      mapValue: {
        fields: fields(value)
      }
    };
  }

  return { nullValue: null };
}

function fields(data) {
  const result = {};

  for (const [key, value] of Object.entries(data || {})) {
    if (key.startsWith("_")) continue;
    result[key] = fv(value);
  }

  return result;
}

function pv(value) {
  if (!value) return null;

  if ("stringValue" in value) {
    return value.stringValue;
  }

  if ("integerValue" in value) {
    return Number(value.integerValue);
  }

  if ("doubleValue" in value) {
    return value.doubleValue;
  }

  if ("booleanValue" in value) {
    return value.booleanValue;
  }

  if ("nullValue" in value) {
    return null;
  }

  if ("timestampValue" in value) {
    return value.timestampValue;
  }

  if ("arrayValue" in value) {
    return (value.arrayValue.values || []).map(pv);
  }

  if ("mapValue" in value) {
    return docFields(value.mapValue.fields || {});
  }

  return null;
}

function docFields(source = {}) {
  const result = {};

  for (const [key, value] of Object.entries(source)) {
    result[key] = pv(value);
  }

  return result;
}

function decode(document) {
  if (!document) return null;

  const data = docFields(document.fields || {});

  return {
    ...data,
    id: document.name.split("/").pop(),
    _updateTime: document.updateTime || null
  };
}

// ------------------------------------------------------
// FIRESTORE PATHS & REQUESTS
// ------------------------------------------------------

function docName(path) {
  return `${DB}/${String(path).replace(/^\/+/, "")}`;
}

function firestoreUrl(path) {
  const value = String(path || "");

  // Firestore special endpoints must be appended
  // directly to /documents, without an extra slash.
  if (value.startsWith(":")) {
    return `${DB}${value}`;
  }

  return docName(value);
}

async function fs(env, path, options = {}) {
  const token = await googleAccess(env);

  const result = await fetch(firestoreUrl(path), {
    ...options,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      ...(options.headers || {})
    }
  });

  const text = await result.text();

  let data = null;

  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = null;
  }

  if (!result.ok) {
    const error = new Error(
      data?.error?.message ||
      `Firestore HTTP ${result.status}`
    );

    error.status = result.status;
    error.firestore = data?.error || null;
    throw error;
  }

  return data;
}

async function getDoc(env, path) {
  try {
    return decode(await fs(env, path));
  } catch (error) {
    if (error.status === 404) return null;
    throw error;
  }
}

// ------------------------------------------------------
// FIRESTORE QUERY
// Accepts both:
// ["field", value]
// { field, op, value }
// ------------------------------------------------------

function normalizeFilter(filter) {
  if (Array.isArray(filter) && filter.length >= 2) {
    return {
      field: clean(filter[0], 150),
      op: "EQUAL",
      value: filter[1]
    };
  }

  if (
    filter &&
    typeof filter === "object" &&
    typeof filter.field === "string"
  ) {
    return {
      field: clean(filter.field, 150),
      op: clean(filter.op || "EQUAL", 30).toUpperCase(),
      value: filter.value
    };
  }

  throw new Error("صيغة شرط البحث غير صالحة.");
}

async function query(
  env,
  collection,
  filters = [],
  limit = 100
) {
  if (!Array.isArray(filters)) {
    throw new Error("شروط البحث يجب أن تكون قائمة.");
  }

  const structuredQuery = {
    from: [{
      collectionId: clean(collection, 150)
    }],
    limit: Math.min(
      Math.max(Number(limit) || 100, 1),
      MAX_QUERY_RESULTS
    )
  };

  const normalized = filters.map(normalizeFilter);

  for (const filter of normalized) {
    if (!filter.field) {
      throw new Error("اسم حقل البحث فارغ.");
    }

    if (!["EQUAL"].includes(filter.op)) {
      throw new Error(
        `عامل البحث غير مدعوم: ${filter.op}`
      );
    }
  }

  if (normalized.length === 1) {
    const filter = normalized[0];

    structuredQuery.where = {
      fieldFilter: {
        field: {
          fieldPath: filter.field
        },
        op: filter.op,
        value: fv(filter.value)
      }
    };
  }

  if (normalized.length > 1) {
    structuredQuery.where = {
      compositeFilter: {
        op: "AND",
        filters: normalized.map(filter => ({
          fieldFilter: {
            field: {
              fieldPath: filter.field
            },
            op: filter.op,
            value: fv(filter.value)
          }
        }))
      }
    };
  }

  const result = await fs(env, ":runQuery", {
    method: "POST",
    body: JSON.stringify({
      structuredQuery
    })
  });

  return (result || [])
    .filter(item => item.document)
    .map(item => decode(item.document));
}

// ------------------------------------------------------
// FIRESTORE WRITE BUILDERS
// currentDocument belongs beside update/delete,
// never inside the update object.
// ------------------------------------------------------

function writeCreate(path, data) {
  return {
    update: {
      name: docName(path),
      fields: fields(data)
    },
    currentDocument: {
      exists: false
    }
  };
}

function writeUpdate(path, data, updateTime = null) {
  const write = {
    update: {
      name: docName(path),
      fields: fields(data)
    },
    updateMask: {
      fieldPaths: Object.keys(data)
        .filter(key => !key.startsWith("_"))
    }
  };

  if (updateTime) {
    write.currentDocument = {
      updateTime
    };
  }

  return write;
}

function writeDelete(path, updateTime = null) {
  const write = {
    delete: docName(path)
  };

  if (updateTime) {
    write.currentDocument = {
      updateTime
    };
  }

  return write;
}

async function commit(env, writes) {
  if (!Array.isArray(writes) || writes.length === 0) {
    throw new Error("لا توجد عمليات لحفظها.");
  }

  return fs(env, ":commit", {
    method: "POST",
    body: JSON.stringify({ writes })
  });
}

async function createDoc(env, path, data) {
  return commit(env, [
    writeCreate(path, data)
  ]);
}

async function patchDoc(
  env,
  path,
  data,
  updateTime = null
) {
  return commit(env, [
    writeUpdate(path, data, updateTime)
  ]);
}

async function patchOrCreate(env, path, data) {
  const existing = await getDoc(env, path);

  if (existing) {
    return patchDoc(
      env,
      path,
      data,
      existing._updateTime
    );
  }

  return createDoc(env, path, data);
}

// ------------------------------------------------------
// GOOGLE SERVICE ACCOUNT ACCESS TOKEN
// ------------------------------------------------------

async function googleAccess(env) {
  if (
    googleTokenCache &&
    googleTokenCache.expires > Date.now() + 60000
  ) {
    return googleTokenCache.token;
  }

  const raw = env.GOOGLE_SERVICE_ACCOUNT_JSON;

  if (!raw) {
    throw new Error("مفتاح خدمة Google غير مضبوط.");
  }

  const account =
    typeof raw === "string"
      ? JSON.parse(raw)
      : raw;

  if (!account.client_email || !account.private_key) {
    throw new Error(
      "بيانات حساب خدمة Google غير مكتملة."
    );
  }

  const now = Math.floor(Date.now() / 1000);

  const header = b64url(
    new TextEncoder().encode(JSON.stringify({
      alg: "RS256",
      typ: "JWT"
    }))
  );

  const claim = b64url(
    new TextEncoder().encode(JSON.stringify({
      iss: account.client_email,
      scope: GOOGLE_SCOPE,
      aud: TOKEN_URL,
      iat: now,
      exp: now + 3600
    }))
  );

  const unsigned = `${header}.${claim}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(account.private_key),
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256"
    },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned)
  );

  const assertion =
    `${unsigned}.${b64url(signature)}`;

  const form = new URLSearchParams({
    grant_type:
      "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion
  });

  const result = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      "content-type":
        "application/x-www-form-urlencoded"
    },
    body: form
  });

  const data = await result.json();

  if (!result.ok || !data.access_token) {
    console.error(
      "Google token error:",
      data?.error || result.status
    );

    throw new Error(
      "فشل الاتصال بخدمة Google."
    );
  }

  googleTokenCache = {
    token: data.access_token,
    expires:
      Date.now() +
      Number(data.expires_in || 3600) * 1000
  };

  return googleTokenCache.token;
}

// ------------------------------------------------------
// FIREBASE PUBLIC SIGNING KEYS
// ------------------------------------------------------

async function firebaseKeys(forceRefresh = false) {
  if (
    !forceRefresh &&
    firebaseKeysCache &&
    firebaseKeysCache.expires > Date.now()
  ) {
    return firebaseKeysCache.keys;
  }

  const result = await fetch(JWKS_URL);

  if (!result.ok) {
    throw new Error(
      "تعذر جلب مفاتيح Firebase."
    );
  }

  const data = await result.json();

  firebaseKeysCache = {
    keys: Array.isArray(data.keys) ? data.keys : [],
    expires: Date.now() + 50 * 60 * 1000
  };

  return firebaseKeysCache.keys;
}

// ------------------------------------------------------
// FIREBASE ID TOKEN VERIFICATION
// ------------------------------------------------------

async function authUser(request) {
  const header =
    request.headers.get("authorization") || "";

  const match = header.match(/^Bearer\s+(.+)$/i);

  if (!match) {
    throw httpError("يلزم تسجيل الدخول.", 401);
  }

  const parts = match[1].trim().split(".");

  if (parts.length !== 3) {
    throw httpError("رمز الدخول غير صالح.", 401);
  }

  let jwtHeader;
  let payload;

  try {
    jwtHeader = decodePart(parts[0]);
    payload = decodePart(parts[1]);
  } catch {
    throw httpError(
      "تعذر قراءة رمز الدخول.",
      401
    );
  }

  if (
    jwtHeader.alg !== "RS256" ||
    typeof jwtHeader.kid !== "string" ||
    !jwtHeader.kid
  ) {
    throw httpError(
      "توقيع الرمز غير صالح.",
      401
    );
  }

  let keys = await firebaseKeys();

  let keyData = keys.find(
    key => key.kid === jwtHeader.kid
  );

  // Refresh the public keys once if Firebase has
  // rotated its signing key.
  if (!keyData) {
    keys = await firebaseKeys(true);

    keyData = keys.find(
      key => key.kid === jwtHeader.kid
    );
  }

  if (!keyData) {
    throw httpError(
      "مفتاح التحقق غير موجود.",
      401
    );
  }

  let valid = false;

  try {
    const key = await crypto.subtle.importKey(
      "jwk",
      keyData,
      {
        name: "RSASSA-PKCS1-v1_5",
        hash: "SHA-256"
      },
      false,
      ["verify"]
    );

    valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      unb64(parts[2]),
      new TextEncoder().encode(
        `${parts[0]}.${parts[1]}`
      )
    );
  } catch {
    valid = false;
  }

  const now = Math.floor(Date.now() / 1000);

  const validClaims =
    payload.aud === PROJECT_ID &&
    payload.iss === FIREBASE_ISSUER &&
    typeof payload.sub === "string" &&
    payload.sub.length > 0 &&
    payload.sub.length <= 128 &&
    typeof payload.exp === "number" &&
    Number.isFinite(payload.exp) &&
    typeof payload.iat === "number" &&
    Number.isFinite(payload.iat) &&
    payload.exp > now &&
    payload.iat <= now + 60 &&
    payload.iat < payload.exp &&
    (
      payload.auth_time === undefined ||
      (
        typeof payload.auth_time === "number" &&
        Number.isFinite(payload.auth_time) &&
        payload.auth_time <= now + 60
      )
    );

  if (!valid || !validClaims) {
    throw httpError(
      "رمز الدخول منتهي أو غير صالح.",
      401
    );
  }

  return {
    uid: payload.sub,
    email:
      typeof payload.email === "string"
        ? payload.email
        : "",
    isAnonymous:
      payload.firebase?.sign_in_provider === "anonymous"
  };
}

// ======================================================
// GOLDEN LOUAGE WORKER 5.4.0
// PART 2/7 — Utilities, Authorization, Notifications
// ======================================================

function requireUser(user) {
  if (!user || !user.uid) {
    throw httpError("Authentication required", 401);
  }

  return user;
}

function requireRole(user, roles) {
  requireUser(user);

  const allowed = Array.isArray(roles) ? roles : [roles];

  if (!allowed.includes(user.role)) {
    throw httpError("Permission denied", 403);
  }

  return user;
}

async function getUserProfile(env, uid) {
  const profile = await getDoc(env, `users/${uid}`);

  if (!profile) {
    throw httpError("User profile not found", 404);
  }

  return profile;
}

async function requirePassenger(env, user) {
  requireUser(user);

  const profile = await getUserProfile(env, user.uid);

  if (
    profile.status === "suspended" ||
    profile.disabled === true
  ) {
    throw httpError("Account suspended", 403);
  }

  return profile;
}

async function requireApprovedDriver(env, user) {
  requireUser(user);

  const profile = await getUserProfile(env, user.uid);

  if (profile.role !== "driver") {
    throw httpError("Driver account required", 403);
  }

  if (profile.status !== "approved") {
    throw httpError("Driver account is not approved", 403);
  }

  if (
    profile.active === false ||
    profile.stopped === true ||
    profile.stopStatus === "approved"
  ) {
    throw httpError("Driver account is inactive", 403);
  }

  return profile;
}

async function requireAdmin(env, user) {
  requireUser(user);

  const profile = await getUserProfile(env, user.uid);

  if (
    profile.role !== "admin" ||
    profile.status === "suspended"
  ) {
    throw httpError("Administrator access required", 403);
  }

  return profile;
}

function assertString(value, name, min = 1, max = 500) {
  if (
    typeof value !== "string" ||
    value.trim().length < min ||
    value.trim().length > max
  ) {
    throw httpError(`Invalid ${name}`, 400);
  }

  return value.trim();
}

function assertNumber(value, name, min, max) {
  const number = Number(value);

  if (
    !Number.isFinite(number) ||
    number < min ||
    number > max
  ) {
    throw httpError(`Invalid ${name}`, 400);
  }

  return number;
}

function assertInteger(value, name, min, max) {
  const number = Number(value);

  if (
    !Number.isInteger(number) ||
    number < min ||
    number > max
  ) {
    throw httpError(`Invalid ${name}`, 400);
  }

  return number;
}

function assertDate(value, name = "date") {
  if (typeof value !== "string") {
    throw httpError(`Invalid ${name}`, 400);
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    throw httpError(`Invalid ${name}`, 400);
  }

  return date;
}

function isExpired(value) {
  const date = new Date(value);

  return (
    Number.isNaN(date.getTime()) ||
    date.getTime() <= Date.now()
  );
}

function addMilliseconds(date, milliseconds) {
  return new Date(
    new Date(date).getTime() + milliseconds
  ).toISOString();
}

function bookingHoldExpiry() {
  return new Date(Date.now() + HOLD_MS).toISOString();
}

function makeNotificationId() {
  return makeId("n");
}

async function createNotification(
  env,
  {
    userId,
    type,
    title,
    message,
    data = {},
    relatedId = null
  }
) {
  if (!userId) {
    throw httpError("Notification recipient is required", 400);
  }

  const id = makeNotificationId();

  const notification = {
    id,
    userId,
    type: clean(type || "general"),
    title: clean(title || ""),
    message: clean(message || ""),
    data,
    relatedId,
    read: false,
    createdAt: nowISO()
  };

  await createDoc(
    env,
    `notifications/${id}`,
    notification
  );

  return notification;
}

async function notifyUser(
  env,
  userId,
  type,
  title,
  message,
  data = {},
  relatedId = null
) {
  return createNotification(env, {
    userId,
    type,
    title,
    message,
    data,
    relatedId
  });
}

async function notifyMany(
  env,
  userIds,
  type,
  title,
  message,
  data = {},
  relatedId = null
) {
  const uniqueIds = [
    ...new Set(
      (Array.isArray(userIds) ? userIds : [])
        .filter(id => typeof id === "string" && id.length > 0)
    )
  ];

  const results = [];

  for (const userId of uniqueIds) {
    results.push(
      await notifyUser(
        env,
        userId,
        type,
        title,
        message,
        data,
        relatedId
      )
    );
  }

  return results;
}

function normalizeTripStatus(status) {
  const allowed = [
    "scheduled",
    "open",
    "started",
    "completed",
    "cancelled"
  ];

  return allowed.includes(status) ? status : "open";
}

function normalizeBookingStatus(status) {
  const allowed = [
    "pending",
    "held",
    "confirmed",
    "rejected",
    "cancelled",
    "expired"
  ];

  return allowed.includes(status) ? status : "pending";
}

function assertTripCanReceiveBookings(trip) {
  if (!trip) {
    throw httpError("Trip not found", 404);
  }

  if (
    trip.status !== "open" &&
    trip.status !== "scheduled"
  ) {
    throw httpError("Trip is not accepting bookings", 409);
  }

  if (trip.active === false) {
    throw httpError("Trip is inactive", 409);
  }

  if (isExpired(trip.departureAt)) {
    throw httpError("Trip departure time has passed", 409);
  }

  const seats = Number(trip.seats ?? SEATS);
  const available = Number(trip.availableSeats ?? seats);

  if (
    !Number.isFinite(seats) ||
    seats !== SEATS ||
    !Number.isFinite(available) ||
    available < 0 ||
    available > SEATS
  ) {
    throw httpError("Invalid trip seat configuration", 409);
  }

  return true;
}

function assertSeatNumber(seatNumber) {
  return assertInteger(
    seatNumber,
    "seat number",
    1,
    SEATS
  );
}

function assertBookingOwner(booking, user) {
  if (!booking) {
    throw httpError("Booking not found", 404);
  }

  if (booking.passengerId !== user.uid) {
    throw httpError("Booking does not belong to this passenger", 403);
  }
}

function assertBookingDriver(booking, user) {
  if (!booking) {
    throw httpError("Booking not found", 404);
  }

  if (booking.driverId !== user.uid) {
    throw httpError("Booking does not belong to this driver", 403);
  }
}

function assertBookingStatus(booking, expected) {
  if (!booking) {
    throw httpError("Booking not found", 404);
  }

  const allowed = Array.isArray(expected) ? expected : [expected];

  if (!allowed.includes(booking.status)) {
    throw httpError(
      `Invalid booking status: ${booking.status}`,
      409
    );
  }
}

function lockDocumentId(tripId, seatNumber) {
  return `${tripId}_${seatNumber}`;
}

function passengerTripLockId(passengerId, tripId) {
  return `${passengerId}_${tripId}`;
}

async function getBooking(env, bookingId) {
  const id = assertString(bookingId, "booking ID", 1, 150);
  const booking = await getDoc(env, `bookings/${id}`);

  if (!booking) {
    throw httpError("Booking not found", 404);
  }

  return booking;
}

async function getTrip(env, tripId) {
  const id = assertString(tripId, "trip ID", 1, 150);
  const trip = await getDoc(env, `trips/${id}`);

  if (!trip) {
    throw httpError("Trip not found", 404);
  }

  return trip;
}

async function getDriver(env, driverId) {
  const id = assertString(driverId, "driver ID", 1, 150);
  const driver = await getDoc(env, `users/${id}`);

  if (!driver || driver.role !== "driver") {
    throw httpError("Driver not found", 404);
  }

  return driver;
}

function assertSameUpdateTime(current, expected) {
  if (
    !current ||
    !expected ||
    current._updateTime !== expected
  ) {
    throw httpError(
      "The record changed. Please refresh and try again.",
      409
    );
  }
}

function ensureFutureDeparture(departureAt) {
  const departure = assertDate(
    departureAt,
    "departure time"
  );

  if (departure.getTime() <= Date.now()) {
    throw httpError(
      "Departure time must be in the future",
      400
    );
  }

  return departure.toISOString();
}

function normalizeLocation(value, name) {
  return assertString(value, name, 2, 200);
}

function normalizeCoordinates(latitude, longitude) {
  const lat = assertNumber(latitude, "latitude", -90, 90);
  const lng = assertNumber(longitude, "longitude", -180, 180);

  return {
    latitude: lat,
    longitude: lng
  };
}

// ======================================================
// END PART 2/7
// ======================================================

// ======================================================
// GOLDEN LOUAGE WORKER 5.4.0
// PART 3/7 — Driver Applications, Trips, Booking Creation
// ======================================================

async function createPassengerProfile(env, user, body = {}) {
  requireUser(user);

  const fullName = assertString(body.fullName, "full name", 3, 120);
  const phone = assertString(body.phone, "phone", 6, 30);
  const path = `users/${user.uid}`;
  const existing = await getDoc(env, path);

  if (existing) {
    if (existing.role !== "passenger") {
      throw httpError("This account is not a passenger", 403);
    }

    const updates = { fullName, phone, updatedAt: nowISO() };
    await patchDoc(env, path, updates, existing._updateTime);

    return {
      success: true,
      passenger: { ...existing, ...updates }
    };
  }

  const createdAt = nowISO();
  const passenger = {
    uid: user.uid,
    role: "passenger",
    fullName,
    phone,
    status: "active",
    createdAt,
    updatedAt: createdAt
  };

  await createDoc(env, path, passenger);

  return { success: true, passenger };
}

async function applyDriver(env, user, body) {
  requireUser(user);

  const existing = await getDoc(
    env,
    `users/${user.uid}`
  );

  if (existing) {
    if (existing.role === "admin") {
      throw httpError("Administrator cannot apply as driver", 403);
    }

    if (
      existing.role === "driver" &&
      existing.status === "approved"
    ) {
      throw httpError("Driver account is already approved", 409);
    }

    if (
      existing.role === "driver" &&
      existing.status === "pending"
    ) {
      throw httpError("Driver application is already pending", 409);
    }
  }

  const fullName = assertString(
    body.fullName,
    "full name",
    3,
    120
  );

  const phone = assertString(
    body.phone,
    "phone",
    6,
    30
  );

  const application = {
    uid: user.uid,
    role: "driver",
    fullName,
    phone,
    status: "pending",
    active: false,
    stopped: false,
    stopStatus: "none",
    applicationCreatedAt: nowISO(),
    updatedAt: nowISO()
  };

  if (existing) {
    await patchDoc(
      env,
      `users/${user.uid}`,
      application,
      existing._updateTime
    );
  } else {
    await createDoc(
      env,
      `users/${user.uid}`,
      application
    );
  }

  await notifyMany(
    env,
    await getAdminIds(env),
    "driver_application",
    "New driver application",
    `${fullName} submitted a driver application`,
    { driverId: user.uid },
    user.uid
  );

  return {
    success: true,
    message: "Driver application submitted",
    status: "pending"
  };
}

async function getAdminIds(env) {
  const admins = await query(
    env,
    "users",
    [{ field: "role", op: "EQUAL", value: "admin" }],
    100
  );

  return admins.map(item => item.uid || item.id);
}


async function makeVehicleId(registrationNumber) {
  const bytes = new TextEncoder().encode(registrationNumber);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map(value => value.toString(16).padStart(2, "0"))
    .join("");
}

function normalizeVehicleRegistration(value) {
  return assertString(value, "vehicle registration number", 3, 30)
    .replace(/\s+/g, "")
    .toUpperCase();
}

function normalizeVehicleType(value) {
  return assertString(value, "vehicle type", 2, 80);
}

async function addVehicle(env, user, body = {}) {
  const driver = await requireApprovedDriver(env, user);
  const registrationNumber =
    normalizeVehicleRegistration(body.registrationNumber);
  const vehicleType = normalizeVehicleType(body.vehicleType);

  const matches = await query(
    env,
    "vehicles",
    [{
      field: "registrationNumber",
      op: "EQUAL",
      value: registrationNumber
    }],
    10
  );

  if (matches.length > 1) {
    throw httpError("Duplicate vehicle registration records", 409);
  }

  const vehicleId = await makeVehicleId(registrationNumber);
  let vehicle = matches[0] || await getDoc(
    env,
    "vehicles/" + vehicleId
  );

  const linkPath =
    "vehicleDrivers/" + vehicleId + "_" + user.uid;

  if (vehicle) {
    if (vehicle.status === "pending") {
      if (vehicle.submittedBy !== user.uid) {
        throw httpError("This vehicle is awaiting administrator approval", 409);
      }
    } else if (
      vehicle.status !== "approved" ||
      vehicle.active === false
    ) {
      throw httpError("This vehicle is not available for use", 409);
    }

    const existingLink = await getDoc(env, linkPath);

    if (existingLink) {
      if (existingLink.status !== "approved") {
        await patchDoc(
          env,
          linkPath,
          {
            status: "approved",
            approvedAt: nowISO(),
            updatedAt: nowISO()
          },
          existingLink._updateTime
        );
      }

      return {
        success: true,
        vehicle,
        linked: true,
        message: "Vehicle is already linked to this driver"
      };
    }

    await createDoc(env, linkPath, {
      id: vehicleId + "_" + user.uid,
      vehicleId,
      driverId: user.uid,
      status: "approved",
      requestedAt: nowISO(),
      approvedAt: nowISO(),
      updatedAt: nowISO()
    });

    return {
      success: true,
      vehicle,
      linked: true,
      message: "Approved vehicle linked successfully"
    };
  }

  const createdAt = nowISO();

  vehicle = {
    id: vehicleId,
    registrationNumber,
    vehicleType,
    status: "pending",
    active: false,
    submittedBy: user.uid,
    submittedByName: driver.fullName || "",
    createdAt,
    updatedAt: createdAt
  };

  const link = {
    id: vehicleId + "_" + user.uid,
    vehicleId,
    driverId: user.uid,
    status: "approved",
    requestedAt: createdAt,
    approvedAt: createdAt,
    updatedAt: createdAt
  };

  await commit(env, [
    writeCreate("vehicles/" + vehicleId, vehicle),
    writeCreate(linkPath, link)
  ]);

  return {
    success: true,
    vehicle,
    linked: true,
    message: "Vehicle submitted for administrator approval"
  };
}

async function listMyVehicles(env, user) {
  await requireApprovedDriver(env, user);

  const links = await query(
    env,
    "vehicleDrivers",
    [{
      field: "driverId",
      op: "EQUAL",
      value: user.uid
    }],
    MAX_QUERY_RESULTS
  );

  const vehicles = await Promise.all(
    links.map(async link => {
      const vehicle = await getDoc(
        env,
        "vehicles/" + link.vehicleId
      );

      return vehicle
        ? { ...vehicle, linkStatus: link.status }
        : null;
    })
  );

  return {
    success: true,
    vehicles: vehicles.filter(Boolean)
  };
}

async function listAllVehicles(env, user) {
  await requireAdmin(env, user);

  const vehicles = await query(
    env,
    "vehicles",
    [],
    MAX_QUERY_RESULTS
  );

  vehicles.sort(
    (a, b) =>
      new Date(b.createdAt || 0).getTime() -
      new Date(a.createdAt || 0).getTime()
  );

  return { success: true, vehicles };
}

async function updateVehicleStatus(
  env,
  user,
  vehicleId,
  action,
  body = {}
) {
  await requireAdmin(env, user);

  const id = assertString(vehicleId, "vehicle ID", 1, 150);
  const vehicle = await getDoc(env, "vehicles/" + id);

  if (!vehicle) {
    throw httpError("Vehicle not found", 404);
  }

  const reason = body.reason === undefined
    ? ""
    : assertString(body.reason, "reason", 0, 500);

  if (action === "approve") {
    if (vehicle.status === "approved" && vehicle.active === true) {
      return { success: true, status: "approved" };
    }

    if (vehicle.status !== "pending") {
      throw httpError("Only pending vehicles can be approved", 409);
    }

    const updatedAt = nowISO();

    await patchDoc(
      env,
      "vehicles/" + id,
      {
        status: "approved",
        active: true,
        approvedAt: updatedAt,
        approvedBy: user.uid,
        updatedAt
      },
      vehicle._updateTime
    );

    return { success: true, status: "approved" };
  }

  if (action === "reject") {
    if (vehicle.status === "rejected") {
      return { success: true, status: "rejected" };
    }

    if (vehicle.status !== "pending") {
      throw httpError("Only pending vehicles can be rejected", 409);
    }

    const updatedAt = nowISO();

    await patchDoc(
      env,
      "vehicles/" + id,
      {
        status: "rejected",
        active: false,
        rejectedAt: updatedAt,
        rejectedBy: user.uid,
        rejectionReason: reason,
        updatedAt
      },
      vehicle._updateTime
    );

    return { success: true, status: "rejected" };
  }

  if (action === "suspend") {
    if (vehicle.status === "suspended" && vehicle.active === false) {
      return { success: true, status: "suspended" };
    }

    if (vehicle.status !== "approved") {
      throw httpError("Only approved vehicles can be suspended", 409);
    }

    const updatedAt = nowISO();

    await patchDoc(
      env,
      "vehicles/" + id,
      {
        status: "suspended",
        active: false,
        suspendedAt: updatedAt,
        suspendedBy: user.uid,
        suspensionReason: reason,
        updatedAt
      },
      vehicle._updateTime
    );

    return { success: true, status: "suspended" };
  }

  throw httpError("Invalid vehicle action", 400);
}


async function getApprovedDriverVehicle(env, user, vehicleId) {
  const id = assertString(vehicleId, "vehicle ID", 1, 150);

  const vehicle = await getDoc(env, "vehicles/" + id);

  if (
    !vehicle ||
    vehicle.status !== "approved" ||
    vehicle.active !== true
  ) {
    throw httpError("Vehicle is not approved or active", 403);
  }

  const link = await getDoc(
    env,
    "vehicleDrivers/" + id + "_" + user.uid
  );

  if (!link || link.status !== "approved") {
    throw httpError("This vehicle is not linked to your account", 403);
  }

  return vehicle;
}

async function createTrip(env, user, body) {
  const driver = await requireApprovedDriver(env, user);

  const vehicle = await getApprovedDriverVehicle(
    env,
    user,
    body.vehicleId
  );

  for (const status of ["open", "scheduled", "started"]) {
    const vehicleTrips = await query(
      env,
      "trips",
      [
        { field: "vehicleId", op: "EQUAL", value: vehicle.id },
        { field: "status", op: "EQUAL", value: status }
      ],
      MAX_QUERY_RESULTS
    );

    if (vehicleTrips.length > 0) {
      throw httpError(
        "This vehicle already has an unfinished trip",
        409
      );
    }
  }

  const departureAt = ensureFutureDeparture(body.departureAt);

  const origin = normalizeLocation(body.origin, "origin");
  const destination = normalizeLocation(
    body.destination,
    "destination"
  );

  const originCoordinates =
    body.originCoordinates &&
    typeof body.originCoordinates === "object"
      ? normalizeCoordinates(
          body.originCoordinates.latitude,
          body.originCoordinates.longitude
        )
      : null;

  const destinationCoordinates =
    body.destinationCoordinates &&
    typeof body.destinationCoordinates === "object"
      ? normalizeCoordinates(
          body.destinationCoordinates.latitude,
          body.destinationCoordinates.longitude
        )
      : null;

  const tripId = makeId("t");
  const createdAt = nowISO();

  const trip = {
    id: tripId,
    driverId: user.uid,
    driverName: driver.fullName || "",
    driverPhone: driver.phone || "",
    vehicleId: vehicle.id,
    vehicleRegistration: vehicle.registrationNumber,
    vehicleType: vehicle.vehicleType,
    origin,
    destination,
    originCoordinates,
    destinationCoordinates,
    departureAt,
    seats: SEATS,
    availableSeats: SEATS,
    status: "open",
    active: true,
    createdAt,
    updatedAt: createdAt
  };


  const driverLockPath = `driverTripLocks/${user.uid}`;
  const existingDriverLock = await getDoc(env, driverLockPath);

  if (existingDriverLock) {
    throw httpError(
      "Driver already has an existing trip lock. Contact support.",
      409
    );
  }

  for (const status of ["open", "scheduled"]) {
    const legacyTrips = await query(
      env,
      "trips",
      [
        { field: "driverId", op: "EQUAL", value: user.uid },
        { field: "status", op: "EQUAL", value: status }
      ],
      MAX_QUERY_RESULTS
    );

    if (legacyTrips.length > 0) {
      throw httpError(
        "You must start or finish your previous trip before creating another",
        409
      );
    }
  }

  const driverLock = {
    driverId: user.uid,
    tripId,
    createdAt,
    updatedAt: createdAt
  };

  await commit(env, [
    writeCreate("trips/" + tripId, trip),
    writeCreate(driverLockPath, driverLock)
  ]);

  return { success: true, trip };
}

async function updateTrip(env, user, tripId, body) {
  const driver = await requireApprovedDriver(env, user);
  const trip = await getTrip(env, tripId);

  if (trip.driverId !== user.uid) {
    throw httpError("You cannot update this trip", 403);
  }

  if (
    trip.status !== "open" &&
    trip.status !== "scheduled"
  ) {
    throw httpError("This trip can no longer be updated", 409);
  }

  const updates = { updatedAt: nowISO() };

  let requestedDepartureAt;
  let requestedVehicleId;

  if (body.departureAt !== undefined) {
    requestedDepartureAt = ensureFutureDeparture(body.departureAt);
  }

  if (body.vehicleId !== undefined) {
    requestedVehicleId = assertString(
      body.vehicleId,
      "vehicle ID",
      1,
      150
    );
  }

  const departureChanged =
    requestedDepartureAt !== undefined &&
    requestedDepartureAt !== trip.departureAt;

  const vehicleChanged =
    requestedVehicleId !== undefined &&
    requestedVehicleId !== trip.vehicleId;

  if (departureChanged || vehicleChanged) {
    const confirmedBookings = await query(
      env,
      "bookings",
      [
        { field: "tripId", op: "EQUAL", value: tripId },
        { field: "status", op: "EQUAL", value: "confirmed" }
      ],
      MAX_QUERY_RESULTS
    );

    if (confirmedBookings.length > 0) {
      throw httpError(
        "Vehicle and departure time cannot be changed after confirmed bookings",
        409
      );
    }
  }

  if (vehicleChanged) {
    const vehicle = await getApprovedDriverVehicle(
      env,
      user,
      requestedVehicleId
    );

    updates.vehicleId = vehicle.id;
    updates.vehicleRegistration = vehicle.registrationNumber;
    updates.vehicleType = vehicle.vehicleType;
  }

  if (body.origin !== undefined) {
    updates.origin = normalizeLocation(body.origin, "origin");
  }

  if (body.destination !== undefined) {
    updates.destination = normalizeLocation(
      body.destination,
      "destination"
    );
  }

  if (requestedDepartureAt !== undefined) {
    updates.departureAt = requestedDepartureAt;
  }

  if (body.originCoordinates !== undefined) {
    updates.originCoordinates =
      body.originCoordinates === null
        ? null
        : normalizeCoordinates(
            body.originCoordinates.latitude,
            body.originCoordinates.longitude
          );
  }

  if (body.destinationCoordinates !== undefined) {
    updates.destinationCoordinates =
      body.destinationCoordinates === null
        ? null
        : normalizeCoordinates(
            body.destinationCoordinates.latitude,
            body.destinationCoordinates.longitude
          );
  }

  if (driver.active === false) {
    throw httpError("Driver account is inactive", 403);
  }

  await patchDoc(
    env,
    "trips/" + tripId,
    updates,
    trip._updateTime
  );

  return { success: true, message: "Trip updated" };
}

async function cancelTrip(env, user, tripId) {
  await requireApprovedDriver(env, user);

  const trip = await getTrip(env, tripId);

  if (trip.driverId !== user.uid) {
    throw httpError("You cannot cancel this trip", 403);
  }

  if (
    trip.status === "started" ||
    trip.status === "completed"
  ) {
    throw httpError("This trip cannot be cancelled", 409);
  }

  if (trip.status === "cancelled") {
    return {
      success: true,
      message: "Trip already cancelled"
    };
  }

  const bookings = await query(
    env,
    "bookings",
    [{ field: "tripId", op: "EQUAL", value: tripId }],
    MAX_QUERY_RESULTS
  );

  const driverLockPath = "driverTripLocks/" + user.uid;
  const driverLock = await getDoc(env, driverLockPath);

  const vehicleLockPath = trip.vehicleId
    ? `vehicleActiveLocks/${trip.vehicleId}`
    : null;
  const vehicleLock = vehicleLockPath
    ? await getDoc(env, vehicleLockPath)
    : null;

  if (driverLock && driverLock.tripId !== tripId) {
    throw httpError("Driver lock belongs to another trip", 409);
  }

  const updatedAt = nowISO();

  const writes = [
    writeUpdate(
      `trips/${tripId}`,
      {
        status: "cancelled",
        active: false,
        cancellationReason: "driver_cancelled",
        cancelledAt: updatedAt,
        updatedAt
      },
      trip._updateTime
    )
  ];

  const affectedPassengers = [];

  for (const booking of bookings) {
    if (
      booking.status !== "pending" &&
      booking.status !== "held" &&
      booking.status !== "confirmed"
    ) {
      continue;
    }

    const locks = await getBookingLocks(env, booking);

    writes.push(
      writeUpdate(
        `bookings/${booking.id}`,
        {
          status: "cancelled",
          cancellationReason: "trip_cancelled",
          cancelledAt: updatedAt,
          cancelledBy: user.uid,
          updatedAt
        },
        booking._updateTime
      )
    );

    addLockDeletionWrites(writes, booking, locks);
    affectedPassengers.push(booking.passengerId);
  }

  if (driverLock) {
    writes.push(
      writeDelete(driverLockPath, driverLock._updateTime)
    );
  }

  if (vehicleLock && vehicleLock.tripId === tripId) {
    writes.push(
      writeDelete(vehicleLockPath, vehicleLock._updateTime)
    );
  }

  await commit(env, writes);

  await notifyMany(
    env,
    [...new Set(affectedPassengers)],
    "trip_cancelled",
    "Trip cancelled",
    "The driver cancelled this trip. You can book another trip.",
    { tripId },
    tripId
  );

  return {
    success: true,
    message: "Trip cancelled and all active bookings released"
  };
}

async function createBooking(env, user, body) {
  const passenger = await requirePassenger(env, user);

  const tripId = assertString(
    body.tripId,
    "trip ID",
    1,
    150
  );

  const seatNumber = assertSeatNumber(
    body.seatNumber
  );

  const trip = await getTrip(env, tripId);

  assertTripCanReceiveBookings(trip);

  if (trip.driverId === user.uid) {
    throw httpError("Driver cannot book their own trip", 403);
  }

  const driver = await getDriver(env, trip.driverId);

  if (
    driver.status !== "approved" ||
    driver.active === false ||
    driver.stopped === true ||
    driver.stopStatus === "approved"
  ) {
    throw httpError("Driver is not available", 409);
  }

  const bookingId = makeId("b");

  const seatLockId = lockDocumentId(
    tripId,
    seatNumber
  );

  const passengerLockId = passengerTripLockId(
    user.uid,
    tripId
  );

  const seatLockPath = `seatLocks/${seatLockId}`;
  const passengerLockPath =
    `passengerTripLocks/${passengerLockId}`;

  let existingSeatLock = await getDoc(
    env,
    seatLockPath
  );
  let existingPassengerLock = await getDoc(
    env,
    passengerLockPath
  );

  const staleBookingIds = [
    ...new Set([
      existingSeatLock?.bookingId,
      existingPassengerLock?.bookingId
    ].filter(id => typeof id === "string" && id.length > 0))
  ];

  for (const staleBookingId of staleBookingIds) {
    const staleBooking = await getBooking(env, staleBookingId);

    if (
      staleBooking &&
      staleBooking.status === "held" &&
      staleBooking.holdExpiresAt &&
      isExpired(staleBooking.holdExpiresAt)
    ) {
      await expireBooking(env, staleBookingId);
    }
  }

  existingSeatLock = await getDoc(env, seatLockPath);
  existingPassengerLock = await getDoc(env, passengerLockPath);

  if (existingSeatLock) {
    throw httpError("This seat is not available", 409);
  }

  if (existingPassengerLock) {
    throw httpError(
      "You already have a booking for this trip",
      409
    );
  }

  const createdAt = nowISO();

  const booking = {
    id: bookingId,
    tripId,
    driverId: trip.driverId,
    passengerId: user.uid,
    passengerName: passenger.fullName || "",
    passengerPhone: passenger.phone || "",
    driverName: driver.fullName || "",
    vehicleId: trip.vehicleId,
    vehicleRegistration: trip.vehicleRegistration,
    vehicleType: trip.vehicleType,
    origin: trip.origin,
    destination: trip.destination,
    departureAt: trip.departureAt,
    seatNumber,
    status: "pending",
    createdAt,
    updatedAt: createdAt,
    holdExpiresAt: null
  };

  const seatLock = {
    id: seatLockId,
    tripId,
    seatNumber,
    bookingId,
    passengerId: user.uid,
    driverId: trip.driverId,
    status: "pending",
    createdAt
  };

  const passengerLock = {
    id: passengerLockId,
    tripId,
    passengerId: user.uid,
    bookingId,
    seatNumber,
    status: "pending",
    createdAt
  };

  const writes = [
    writeCreate(`bookings/${bookingId}`, booking),
    writeCreate(seatLockPath, seatLock),
    writeCreate(passengerLockPath, passengerLock)
  ];

  if (
    Array.isArray(trip.cancelledSeatNumbers) &&
    trip.cancelledSeatNumbers.some(
      number => Number(number) === seatNumber
    ) &&
    !trip._updateTime
  ) {
    throw httpError(
      "تعذر تأكيد الحجز بسبب غياب وقت تحديث الرحلة. حاول مجدداً.",
      409
    );
  }

  const previousCancelledSeats = Array.isArray(
    trip.cancelledSeatNumbers
  )
    ? trip.cancelledSeatNumbers
    : [];

  const nextCancelledSeats = previousCancelledSeats.filter(
    number => Number(number) !== seatNumber
  );

  if (nextCancelledSeats.length !== previousCancelledSeats.length) {
    writes.push(
      writeUpdate(
        `trips/${trip.id}`,
        {
          cancelledSeatNumbers: nextCancelledSeats,
          updatedAt: createdAt
        },
        trip._updateTime
      )
    );
  }

  await commit(env, writes);

  await notifyUser(
    env,
    trip.driverId,
    "booking_request",
    "New booking request",
    `${passenger.fullName || "A passenger"} requested seat ${seatNumber}`,
    {
      bookingId,
      tripId,
      seatNumber
    },
    bookingId
  );

  return {
    success: true,
    booking
  };
}

// ======================================================
// END PART 3/7
// ======================================================

// ======================================================
// GOLDEN LOUAGE WORKER 5.4.0
// PART 4/7 — Booking Response, Confirmation, Cancellation
// ======================================================

async function getBookingLocks(env, booking) {
  const seatLockId = lockDocumentId(
    booking.tripId,
    booking.seatNumber
  );

  const passengerLockId = passengerTripLockId(
    booking.passengerId,
    booking.tripId
  );

  const seatPath = `seatLocks/${seatLockId}`;
  const passengerPath =
    `passengerTripLocks/${passengerLockId}`;

  const [seatLock, passengerLock] = await Promise.all([
    getDoc(env, seatPath),
    getDoc(env, passengerPath)
  ]);

  return {
    seatPath,
    passengerPath,
    seatLock,
    passengerLock
  };
}

function addLockDeletionWrites(writes, booking, locks) {
  if (
    locks.seatLock &&
    locks.seatLock.bookingId === booking.id
  ) {
    writes.push(
      writeDelete(
        locks.seatPath,
        locks.seatLock._updateTime
      )
    );
  }

  if (
    locks.passengerLock &&
    locks.passengerLock.bookingId === booking.id
  ) {
    writes.push(
      writeDelete(
        locks.passengerPath,
        locks.passengerLock._updateTime
      )
    );
  }

  return writes;
}

function addLockUpdateWrites(
  writes,
  booking,
  locks,
  status,
  updatedAt
) {
  if (
    !locks.seatLock ||
    locks.seatLock.bookingId !== booking.id
  ) {
    throw httpError("Seat lock is missing or changed", 409);
  }

  if (
    !locks.passengerLock ||
    locks.passengerLock.bookingId !== booking.id
  ) {
    throw httpError(
      "Passenger booking lock is missing or changed",
      409
    );
  }

  writes.push(
    writeUpdate(
      locks.seatPath,
      {
        status,
        updatedAt
      },
      locks.seatLock._updateTime
    )
  );

  writes.push(
    writeUpdate(
      locks.passengerPath,
      {
        status,
        updatedAt
      },
      locks.passengerLock._updateTime
    )
  );

  return writes;
}

async function expireBooking(env, bookingId) {
  const booking = await getBooking(env, bookingId);

  if (
    booking.status !== "held" ||
    !booking.holdExpiresAt ||
    !isExpired(booking.holdExpiresAt)
  ) {
    return {
      expired: false,
      status: booking.status
    };
  }

  const locks = await getBookingLocks(env, booking);

  const updatedAt = nowISO();

  const writes = [
    writeUpdate(
      `bookings/${booking.id}`,
      {
        status: "expired",
        expiredAt: updatedAt,
        updatedAt
      },
      booking._updateTime
    )
  ];

  addLockDeletionWrites(writes, booking, locks);

  await commit(env, writes);

  await notifyUser(
    env,
    booking.passengerId,
    "booking_expired",
    "انتهت مهلة تأكيد الحجز",
    "انتهت مهلة تأكيد حجزك وتم تحرير المقعد. يمكنك الآن تقديم طلب حجز جديد.",
    {
      bookingId: booking.id,
      tripId: booking.tripId
    },
    booking.id
  );

  return {
    expired: true,
    status: "expired"
  };
}

async function respondToBooking(env, user, bookingId, body) {
  const driver = await requireApprovedDriver(env, user);

  const booking = await getBooking(env, bookingId);

  assertBookingDriver(booking, user);

  if (booking.status === "held") {
    if (
      booking.holdExpiresAt &&
      isExpired(booking.holdExpiresAt)
    ) {
      await expireBooking(env, booking.id);

      throw httpError(
        "Booking confirmation time has expired",
        409
      );
    }

    throw httpError(
      "Booking is already waiting for passenger confirmation",
      409
    );
  }

  assertBookingStatus(booking, "pending");

  const trip = await getTrip(env, booking.tripId);

  if (
    trip.driverId !== user.uid ||
    trip.status !== "open" ||
    trip.active === false
  ) {
    throw httpError("Trip is no longer available", 409);
  }

  if (
    driver.status !== "approved" ||
    driver.active === false ||
    driver.stopped === true
  ) {
    throw httpError("Driver account is inactive", 403);
  }

  const action = String(
    body.action || (body.accept === true ? "accept" : "")
  ).toLowerCase();

  if (action !== "accept" && action !== "reject") {
    throw httpError(
      "Action must be accept or reject",
      400
    );
  }

  const locks = await getBookingLocks(env, booking);

  if (
    !locks.seatLock ||
    locks.seatLock.bookingId !== booking.id ||
    !locks.passengerLock ||
    locks.passengerLock.bookingId !== booking.id
  ) {
    throw httpError(
      "Booking locks are missing or no longer valid",
      409
    );
  }

  const updatedAt = nowISO();

  if (action === "reject") {
    const writes = [
      writeUpdate(
        `bookings/${booking.id}`,
        {
          status: "rejected",
          rejectedAt: updatedAt,
          updatedAt
        },
        booking._updateTime
      )
    ];

    addLockDeletionWrites(writes, booking, locks);

    await commit(env, writes);

    await notifyUser(
      env,
      booking.passengerId,
      "booking_rejected",
      "Booking rejected",
      "The driver rejected your booking request",
      {
        bookingId: booking.id,
        tripId: booking.tripId
      },
      booking.id
    );

    return {
      success: true,
      status: "rejected"
    };
  }

  const holdExpiresAt = bookingHoldExpiry();

  const writes = [
    writeUpdate(
      `bookings/${booking.id}`,
      {
        status: "held",
        acceptedAt: updatedAt,
        holdExpiresAt,
        updatedAt
      },
      booking._updateTime
    )
  ];

  addLockUpdateWrites(
    writes,
    booking,
    locks,
    "held",
    updatedAt
  );

  await commit(env, writes);

  await notifyUser(
    env,
    booking.passengerId,
    "booking_held",
    "Booking accepted",
    "You have 60 seconds to confirm your booking",
    {
      bookingId: booking.id,
      tripId: booking.tripId,
      holdExpiresAt
    },
    booking.id
  );

  return {
    success: true,
    status: "held",
    holdExpiresAt
  };
}

async function confirmBooking(env, user, bookingId) {
  await requirePassenger(env, user);

  const booking = await getBooking(env, bookingId);

  assertBookingOwner(booking, user);
  assertBookingStatus(booking, "held");

  if (
    !booking.holdExpiresAt ||
    isExpired(booking.holdExpiresAt)
  ) {
    await expireBooking(env, booking.id);

    throw httpError(
      "Booking confirmation time has expired",
      409
    );
  }

  const trip = await getTrip(env, booking.tripId);

  if (
    trip.status !== "open" ||
    trip.active === false
  ) {
    throw httpError("Trip is no longer available", 409);
  }

  const locks = await getBookingLocks(env, booking);

  const updatedAt = nowISO();

  const writes = [
    writeUpdate(
      `bookings/${booking.id}`,
      {
        status: "confirmed",
        confirmedAt: updatedAt,
        updatedAt
      },
      booking._updateTime
    )
  ];

  addLockUpdateWrites(
    writes,
    booking,
    locks,
    "confirmed",
    updatedAt
  );

  await commit(env, writes);

  await notifyUser(
    env,
    booking.driverId,
    "booking_confirmed",
    "Booking confirmed",
    "The passenger confirmed the booking",
    {
      bookingId: booking.id,
      tripId: booking.tripId,
      seatNumber: booking.seatNumber
    },
    booking.id
  );

  return {
    success: true,
    status: "confirmed"
  };
}

async function cancelBooking(env, user, bookingId) {
  await requirePassenger(env, user);

  const booking = await getBooking(env, bookingId);

  assertBookingOwner(booking, user);

  if (
    booking.status !== "pending" &&
    booking.status !== "held" &&
    booking.status !== "confirmed"
  ) {
    throw httpError(
      "This booking can no longer be cancelled",
      409
    );
  }

  const trip = await getTrip(env, booking.tripId);

  if (
    trip.status === "started" ||
    trip.status === "completed"
  ) {
    throw httpError(
      "Booking cannot be cancelled after trip departure",
      409
    );
  }

  const locks = await getBookingLocks(env, booking);

  const updatedAt = nowISO();

  if (!trip._updateTime) {
    throw httpError(
      "تعذر إلغاء الحجز بأمان بسبب غياب وقت تحديث الرحلة. حاول مجدداً.",
      409
    );
  }

  const writes = [
    writeUpdate(
      `bookings/${booking.id}`,
      {
        status: "cancelled",
        cancelledAt: updatedAt,
        cancelledBy: user.uid,
        updatedAt
      },
      booking._updateTime
    )
  ];

  const cancelledSeatNumbers = [
    ...new Set([
      ...(Array.isArray(trip.cancelledSeatNumbers)
        ? trip.cancelledSeatNumbers
        : []),
      booking.seatNumber
    ])
  ];

  writes.push(
    writeUpdate(
      `trips/${trip.id}`,
      {
        cancelledSeatNumbers,
        updatedAt
      },
      trip._updateTime
    )
  );

  addLockDeletionWrites(writes, booking, locks);

  await commit(env, writes);

  await notifyUser(
    env,
    booking.driverId,
    "booking_cancelled",
    "Booking cancelled",
    "The passenger cancelled the booking",
    {
      bookingId: booking.id,
      tripId: booking.tripId,
      seatNumber: booking.seatNumber
    },
    booking.id
  );

  return {
    success: true,
    status: "cancelled"
  };
}

// ======================================================
// END PART 4/7
// ======================================================

// ======================================================
// GOLDEN LOUAGE WORKER 5.4.0
// PART 5/7 — Lists, Trip Start, Driver Stop Requests
// ======================================================

async function listAdminTrips(env, user) {
  await requireAdmin(env, user);

  const trips = await query(
    env,
    "trips",
    [],
    MAX_QUERY_RESULTS
  );

  trips.sort(
    (a, b) =>
      new Date(a.departureAt || a.createdAt || 0).getTime() -
      new Date(b.departureAt || b.createdAt || 0).getTime()
  );

  const tripsWithSeats = [];

  for (let i = 0; i < trips.length; i += 10) {
    const batch = trips.slice(i, i + 10);

    const batchResults = await Promise.all(
      batch.map(async trip => {
        const seatLocks = await query(
          env,
          "seatLocks",
          [{
            field: "tripId",
            op: "EQUAL",
            value: trip.id
          }],
          SEATS
        );

        const occupiedSeatNumbers = [
          ...new Set(
            seatLocks
              .map(lock => Number(lock.seatNumber))
              .filter(number =>
                Number.isInteger(number) &&
                number >= 1 &&
                number <= SEATS
              )
          )
        ].sort((a, b) => a - b);

        const occupiedSeats = new Set(occupiedSeatNumbers);

        const availableSeatNumbers = Array.from(
          { length: SEATS },
          (_, index) => index + 1
        ).filter(number => !occupiedSeats.has(number));

        return {
          ...trip,
          occupiedSeatNumbers,
          availableSeatNumbers
        };
      })
    );

    tripsWithSeats.push(...batchResults);
  }

  return {
    success: true,
    trips: tripsWithSeats
  };
}

async function listOpenTrips(env, user, params = {}) {
  await requireUser(user);
  const profile = await getUserProfile(env, user.uid);

  if (profile.role === "admin") {
    await requireAdmin(env, user);
  }

  const trips = await query(
    env,
    "trips",
    [
      { field: "status", op: "EQUAL", value: "open" }
    ],
    MAX_QUERY_RESULTS
  );

  const result = trips.filter(trip => {
    if (trip.active === false) return false;
    if (isExpired(trip.departureAt)) return false;

    if (
      params.origin &&
      !String(trip.origin || "")
        .toLowerCase()
        .includes(String(params.origin).toLowerCase())
    ) {
      return false;
    }

    if (
      params.destination &&
      !String(trip.destination || "")
        .toLowerCase()
        .includes(String(params.destination).toLowerCase())
    ) {
      return false;
    }

    return true;
  });

  result.sort(
    (a, b) =>
      new Date(a.departureAt).getTime() -
      new Date(b.departureAt).getTime()
  );

  const visibleTrips = profile.role === "admin"
    ? result
    : result.map(({ driverPhone, ...trip }) => trip);

  const tripsWithSeats = [];

  for (let i = 0; i < visibleTrips.length; i += 10) {
    const batch = visibleTrips.slice(i, i + 10);

    const batchResults = await Promise.all(
      batch.map(async trip => {
        const seatLocks = await query(
          env,
          "seatLocks",
          [{
            field: "tripId",
            op: "EQUAL",
            value: trip.id
          }],
          SEATS
        );

        const occupiedSeatNumbers = [
          ...new Set(
            seatLocks
              .map(lock => Number(lock.seatNumber))
              .filter(number =>
                Number.isInteger(number) &&
                number >= 1 &&
                number <= SEATS
              )
          )
        ].sort((a, b) => a - b);

        const occupiedSeats = new Set(occupiedSeatNumbers);

        const availableSeatNumbers = Array.from(
          { length: SEATS },
          (_, index) => index + 1
        ).filter(number => !occupiedSeats.has(number));

        return {
          ...trip,
          occupiedSeatNumbers,
          availableSeatNumbers
        };
      })
    );

    tripsWithSeats.push(...batchResults);
  }

  return {
    success: true,
    trips: tripsWithSeats
  };
}

async function listDriverTrips(env, user) {
  await requireApprovedDriver(env, user);

  const trips = await query(
    env,
    "trips",
    [
      { field: "driverId", op: "EQUAL", value: user.uid }
    ],
    MAX_QUERY_RESULTS
  );

  trips.sort(
    (a, b) =>
      new Date(b.createdAt || 0).getTime() -
      new Date(a.createdAt || 0).getTime()
  );

  return {
    success: true,
    trips
  };
}

async function listPassengerBookings(env, user) {
  await requirePassenger(env, user);

  const bookings = await query(
    env,
    "bookings",
    [
      {
        field: "passengerId",
        op: "EQUAL",
        value: user.uid
      }
    ],
    MAX_QUERY_RESULTS
  );

  bookings.sort(
    (a, b) =>
      new Date(b.createdAt || 0).getTime() -
      new Date(a.createdAt || 0).getTime()
  );

  return {
    success: true,
    bookings
  };
}

async function listDriverBookings(env, user, params = {}) {
  await requireApprovedDriver(env, user);

  const filters = [
    {
      field: "driverId",
      op: "EQUAL",
      value: user.uid
    }
  ];

  if (params.tripId) {
    filters.push({
      field: "tripId",
      op: "EQUAL",
      value: assertString(params.tripId, "trip ID", 1, 150)
    });
  }

  if (params.status) {
    filters.push({
      field: "status",
      op: "EQUAL",
      value: normalizeBookingStatus(params.status)
    });
  }

  const bookings = await query(
    env,
    "bookings",
    filters,
    MAX_QUERY_RESULTS
  );

  bookings.sort(
    (a, b) =>
      new Date(b.createdAt || 0).getTime() -
      new Date(a.createdAt || 0).getTime()
  );

  const visibleBookings = bookings.map(
    ({ passengerPhone, ...booking }) => booking
  );

  return {
    success: true,
    bookings: visibleBookings
  };
}

async function getTripDetails(env, user, tripId) {
  await requireUser(user);

  const profile = await getUserProfile(env, user.uid);
  const trip = await getTrip(env, tripId);

  const bookings = await query(
    env,
    "bookings",
    [
      {
        field: "tripId",
        op: "EQUAL",
        value: tripId
      }
    ],
    MAX_QUERY_RESULTS
  );

  if (profile.role === "admin") {
    await requireAdmin(env, user);

    return {
      success: true,
      trip,
      bookings
    };
  }

  if (profile.role === "driver") {
    await requireApprovedDriver(env, user);

    if (trip.driverId !== user.uid) {
      throw httpError("You cannot view this trip", 403);
    }

    const visibleBookings = bookings.map(
      ({ passengerPhone, ...booking }) => booking
    );

    return {
      success: true,
      trip,
      bookings: visibleBookings
    };
  }

  await requirePassenger(env, user);

  const visibleBookings = bookings.filter(booking => {
    return (
      booking.passengerId === user.uid &&
      ["pending", "held", "confirmed"].includes(booking.status)
    );
  });

  if (visibleBookings.length === 0) {
    throw httpError("You cannot view this trip", 403);
  }

  return {
    success: true,
    trip,
    bookings: visibleBookings
  };
}

async function startTrip(env, user, tripId) {
  await requireApprovedDriver(env, user);

  const trip = await getTrip(env, tripId);

  if (trip.driverId !== user.uid) {
    throw httpError("You cannot start this trip", 403);
  }

  if (
    trip.status !== "open" &&
    trip.status !== "scheduled"
  ) {
    throw httpError("Trip cannot be started", 409);
  }

  if (!trip.vehicleId) {
    throw httpError("Trip has no assigned vehicle", 409);
  }

  const vehicle = await getApprovedDriverVehicle(
    env,
    user,
    trip.vehicleId
  );

  const driverLockPath = "driverTripLocks/" + user.uid;
  const driverLock = await getDoc(env, driverLockPath);

  if (driverLock && driverLock.tripId !== tripId) {
    throw httpError(
      "Driver lock belongs to another trip",
      409
    );
  }

  const lockPath = "vehicleActiveLocks/" + vehicle.id;
  const existingLock = await getDoc(env, lockPath);

  if (existingLock) {
    throw httpError(
      "This vehicle is already being used by another active trip",
      409
    );
  }

  const updatedAt = nowISO();

  const lock = {
    vehicleId: vehicle.id,
    vehicleRegistration: vehicle.registrationNumber,
    tripId: tripId,
    driverId: user.uid,
    startedAt: updatedAt,
    createdAt: updatedAt
  };

  await commit(env, [
    writeUpdate(
      "trips/" + tripId,
      {
        status: "started",
        startedAt: updatedAt,
        updatedAt
      },
      trip._updateTime
    ),
    writeCreate(lockPath, lock),
    ...(driverLock
      ? [writeDelete(driverLockPath, driverLock._updateTime)]
      : [])
  ]);

  const bookings = await query(
    env,
    "bookings",
    [
      {
        field: "tripId",
        op: "EQUAL",
        value: tripId
      }
    ],
    MAX_QUERY_RESULTS
  );

  const passengers = bookings
    .filter(item => item.status === "confirmed")
    .map(item => item.passengerId);

  await notifyMany(
    env,
    passengers,
    "trip_started",
    "Trip started",
    "Your driver has started the trip",
    { tripId },
    tripId
  );

  return {
    success: true,
    status: "started"
  };
}


async function completeTrip(env, user, tripId) {
  requireUser(user);

  const profile = await getUserProfile(env, user.uid);

  if (profile.role !== "driver") {
    throw httpError("Driver account required", 403);
  }

  const trip = await getTrip(env, tripId);

  if (trip.driverId !== user.uid) {
    throw httpError("You cannot complete this trip", 403);
  }

  if (trip.status !== "started") {
    throw httpError("Trip has not started", 409);
  }

  if (!trip.vehicleId) {
    throw httpError("Trip has no assigned vehicle", 409);
  }

  const lockPath = "vehicleActiveLocks/" + trip.vehicleId;
  const lock = await getDoc(env, lockPath);

  if (!lock || lock.tripId !== tripId) {
    throw httpError(
      "Vehicle lock is missing or belongs to another trip",
      409
    );
  }

  const updatedAt = nowISO();

  await commit(env, [
    writeUpdate(
      "trips/" + tripId,
      {
        status: "completed",
        completedAt: updatedAt,
        updatedAt
      },
      trip._updateTime
    ),
    writeDelete(lockPath, lock._updateTime)
  ]);

  return {
    success: true,
    status: "completed"
  };
}


async function updateTripLiveLocation(env, user, tripId, body = {}) {
  await requireApprovedDriver(env, user);
  const trip = await getTrip(env, tripId);

  if (trip.driverId !== user.uid) {
    throw httpError("You cannot update this trip location", 403);
  }
  if (trip.status !== "started") {
    throw httpError("Trip is not started", 409);
  }

  const latitude = assertNumber(body.latitude, "latitude", -90, 90);
  const longitude = assertNumber(body.longitude, "longitude", -180, 180);
  const path = `tripLiveLocations/${tripId}`;
  const current = await getDoc(env, path);
  const updatedAt = nowISO();

  const location = {
    tripId,
    driverId: user.uid,
    latitude,
    longitude,
    isLive: true,
    updatedAt
  };

  await commit(env, [
    current
      ? writeUpdate(path, location, current._updateTime)
      : writeCreate(path, location)
  ]);

  return { success: true, isLive: true, updatedAt };
}

async function getTripLiveLocation(env, user, tripId) {
  requireUser(user);
  const profile = await getUserProfile(env, user.uid);
  const trip = await getTrip(env, tripId);

  if (profile.role === "driver") {
    if (trip.driverId !== user.uid) {
      throw httpError("You cannot view this trip location", 403);
    }
  } else if (profile.role === "admin") {
    await requireAdmin(env, user);
  } else {
    await requirePassenger(env, user);
    const bookings = await query(env, "bookings", [
      { field: "tripId", op: "EQUAL", value: tripId },
      { field: "passengerId", op: "EQUAL", value: user.uid },
      { field: "status", op: "EQUAL", value: "confirmed" }
    ], MAX_QUERY_RESULTS);

    if (bookings.length === 0) {
      throw httpError("Confirmed booking required", 403);
    }
  }

  if (trip.status !== "started") {
    return { success: true, isLive: false, location: null };
  }

  const location = await getDoc(env, `tripLiveLocations/${tripId}`);
  if (!location || location.isLive !== true) {
    return { success: true, isLive: false, location: null };
  }

  const age = Date.now() - new Date(location.updatedAt).getTime();
  if (!Number.isFinite(age) || age < 0 || age > 150000) {
    return { success: true, isLive: false, location: null };
  }

  return { success: true, isLive: true, location };
}

async function requestDriverStop(env, user, body = {}) {
  const driver = await requireApprovedDriver(env, user);

  if (
    driver.stopStatus === "pending" ||
    driver.stopStatus === "approved"
  ) {
    throw httpError(
      "A driver stop request already exists",
      409
    );
  }

  const reason =
    body.reason === undefined
      ? ""
      : assertString(body.reason, "reason", 0, 500);

  const requestId = makeId("ds");
  const createdAt = nowISO();

  const request = {
    id: requestId,
    driverId: user.uid,
    driverName: driver.fullName || "",
    reason,
    status: "pending",
    createdAt,
    updatedAt: createdAt
  };

  await commit(env, [
    writeCreate(
      `driverStopRequests/${requestId}`,
      request
    ),
    writeUpdate(
      `users/${user.uid}`,
      {
        stopStatus: "pending",
        stopRequestedAt: createdAt,
        updatedAt: createdAt
      },
      driver._updateTime
    )
  ]);

  await notifyMany(
    env,
    await getAdminIds(env),
    "driver_stop_request",
    "Driver stop request",
    `${driver.fullName || "A driver"} requested to stop operating`,
    { requestId, driverId: user.uid },
    requestId
  );

  return {
    success: true,
    requestId,
    status: "pending"
  };
}

async function listDriverStopRequests(env, user) {
  await requireAdmin(env, user);

  const requests = await query(
    env,
    "driverStopRequests",
    [
      {
        field: "status",
        op: "EQUAL",
        value: "pending"
      }
    ],
    MAX_QUERY_RESULTS
  );

  requests.sort(
    (a, b) =>
      new Date(a.createdAt || 0).getTime() -
      new Date(b.createdAt || 0).getTime()
  );

  return {
    success: true,
    requests
  };
}

// ======================================================
// END PART 5/7
// ======================================================

// ======================================================
// GOLDEN LOUAGE WORKER 5.4.0
// PART 6/7 — Admin and Driver Management
// ======================================================

async function listDriverApplications(env, user) {
  await requireAdmin(env, user);

  const applications = await query(
    env,
    "users",
    [
      {
        field: "role",
        op: "EQUAL",
        value: "driver"
      },
      {
        field: "status",
        op: "EQUAL",
        value: "pending"
      }
    ],
    MAX_QUERY_RESULTS
  );

  applications.sort(
    (a, b) =>
      new Date(a.applicationCreatedAt || 0).getTime() -
      new Date(b.applicationCreatedAt || 0).getTime()
  );

  return {
    success: true,
    applications
  };
}

async function approveDriver(env, user, driverId) {
  await requireAdmin(env, user);

  const id = assertString(
    driverId,
    "driver ID",
    1,
    150
  );

  const driver = await getDriver(env, id);

  if (driver.status !== "pending") {
    throw httpError(
      "Driver application is not pending",
      409
    );
  }

  const updatedAt = nowISO();

  await patchDoc(
    env,
    `users/${id}`,
    {
      status: "approved",
      active: true,
      stopped: false,
      stopStatus: "none",
      approvedAt: updatedAt,
      approvedBy: user.uid,
      updatedAt
    },
    driver._updateTime
  );

  await notifyUser(
    env,
    id,
    "driver_approved",
    "Driver account approved",
    "Your driver application has been approved",
    { driverId: id },
    id
  );

  return {
    success: true,
    status: "approved"
  };
}

async function rejectDriver(env, user, driverId, body = {}) {
  await requireAdmin(env, user);

  const id = assertString(
    driverId,
    "driver ID",
    1,
    150
  );

  const driver = await getDriver(env, id);

  if (driver.status !== "pending") {
    throw httpError(
      "Driver application is not pending",
      409
    );
  }

  const reason =
    body.reason === undefined
      ? ""
      : assertString(body.reason, "reason", 0, 500);

  const updatedAt = nowISO();

  await patchDoc(
    env,
    `users/${id}`,
    {
      status: "rejected",
      active: false,
      rejectedAt: updatedAt,
      rejectedBy: user.uid,
      rejectionReason: reason,
      updatedAt
    },
    driver._updateTime
  );

  await notifyUser(
    env,
    id,
    "driver_rejected",
    "Driver application rejected",
    reason || "Your driver application was rejected",
    { driverId: id },
    id
  );

  return {
    success: true,
    status: "rejected"
  };
}

async function stopDriverOpenTrips(env, driverId) {
  const sourceTrips = [];
  const seenTripIds = new Set();

  for (const status of ["open", "scheduled"]) {
    const matching = await query(
      env,
      "trips",
      [
        { field: "driverId", op: "EQUAL", value: driverId },
        { field: "status", op: "EQUAL", value: status }
      ],
      MAX_QUERY_RESULTS
    );

    for (const trip of matching) {
      if (!seenTripIds.has(trip.id)) {
        seenTripIds.add(trip.id);
        sourceTrips.push(trip);
      }
    }
  }

  const candidateCache = new Map();
  const driverCache = new Map();
  const reservedSeats = new Map();

  function coordinatesMatchOrUnavailable(source, candidate) {
    if (!source || !candidate) return true;

    return (
      Number(source.latitude) === Number(candidate.latitude) &&
      Number(source.longitude) === Number(candidate.longitude)
    );
  }

  async function getCandidates(sourceTrip) {
    const key = `${sourceTrip.origin}\u0000${sourceTrip.destination}`;

    if (!candidateCache.has(key)) {
      const matches = await query(
        env,
        "trips",
        [
          { field: "origin", op: "EQUAL", value: sourceTrip.origin },
          { field: "destination", op: "EQUAL", value: sourceTrip.destination },
          { field: "status", op: "EQUAL", value: "open" }
        ],
        MAX_QUERY_RESULTS
      );

      candidateCache.set(key, matches);
    }

    const sourceTime = Date.parse(sourceTrip.departureAt);

    return candidateCache.get(key)
      .filter((trip) => {
        const departure = Date.parse(trip.departureAt);
        return (
          trip.id !== sourceTrip.id &&
          trip.driverId !== driverId &&
          trip.active === true &&
          trip.status === "open" &&
          trip.seats === SEATS &&
          coordinatesMatchOrUnavailable(
            sourceTrip.originCoordinates,
            trip.originCoordinates
          ) &&
          coordinatesMatchOrUnavailable(
            sourceTrip.destinationCoordinates,
            trip.destinationCoordinates
          ) &&
          Number.isFinite(sourceTime) &&
          Number.isFinite(departure) &&
          departure >= sourceTime &&
          departure > Date.now()
        );
      })
      .sort((a, b) =>
        Date.parse(a.departureAt) - Date.parse(b.departureAt)
      );
  }

  async function isEligibleCandidate(trip) {
    if (!driverCache.has(trip.driverId)) {
      driverCache.set(
        trip.driverId,
        getDriver(env, trip.driverId).catch(() => null)
      );
    }

    const driver = await driverCache.get(trip.driverId);

    return Boolean(
      driver &&
      driver.role === "driver" &&
      driver.status === "approved" &&
      driver.active === true &&
      driver.stopped !== true &&
      driver.stopStatus !== "approved"
    );
  }

  async function findReplacement(booking, sourceTrip, candidates) {
    for (const candidate of candidates) {
      if (!(await isEligibleCandidate(candidate))) continue;

      const passengerLockId = passengerTripLockId(
        booking.passengerId,
        candidate.id
      );

      const existingPassengerLock = await getDoc(
        env,
        `passengerTripLocks/${passengerLockId}`
      );

      if (existingPassengerLock) continue;

      if (!reservedSeats.has(candidate.id)) {
        const locks = await query(
          env,
          "seatLocks",
          [{ field: "tripId", op: "EQUAL", value: candidate.id }],
          MAX_QUERY_RESULTS
        );

        reservedSeats.set(
          candidate.id,
          new Set(locks.map((lock) => Number(lock.seatNumber)))
        );
      }

      const occupied = reservedSeats.get(candidate.id);

      for (let seat = 1; seat <= SEATS; seat++) {
        if (!occupied.has(seat)) {
          occupied.add(seat);
          return { trip: candidate, seatNumber: seat };
        }
      }
    }

    return null;
  }

  const driverLockPath = `driverTripLocks/${driverId}`;
  let driverLock = await getDoc(env, driverLockPath);

  for (const sourceTrip of sourceTrips) {
    const bookings = await query(
      env,
      "bookings",
      [{ field: "tripId", op: "EQUAL", value: sourceTrip.id }],
      MAX_QUERY_RESULTS
    );


    const updatedAt = nowISO();
    const writes = [
      writeUpdate(
        `trips/${sourceTrip.id}`,
        {
          status: "cancelled",
          active: false,
          cancellationReason: "driver_stopped",
          cancelledAt: updatedAt,
          updatedAt
        },
        sourceTrip._updateTime
      )
    ];

    const notifications = [];
    const candidates = await getCandidates(sourceTrip);
    const guardedCandidateTripIds = new Set();

    for (const booking of bookings) {
      if (booking.status === "pending" || booking.status === "held") {
        const locks = await getBookingLocks(env, booking);

        if (
          (locks.seatLock && locks.seatLock.bookingId !== booking.id) ||
          (locks.passengerLock && locks.passengerLock.bookingId !== booking.id)
        ) {
          throw httpError(
            `Booking ${booking.id} has a lock owned by another booking`,
            409
          );
        }

        writes.push(
          writeUpdate(
            `bookings/${booking.id}`,
            {
              status: "cancelled",
              cancellationReason: "driver_stopped",
              cancelledAt: updatedAt,
              updatedAt
            },
            booking._updateTime
          )
        );

        addLockDeletionWrites(writes, booking, locks);

        notifications.push({
          userId: booking.passengerId,
          type: "booking_cancelled",
          title: "Booking cancelled",
          message: "Your booking was cancelled because the driver stopped operating.",
          data: { bookingId: booking.id, tripId: sourceTrip.id },
          relatedId: booking.id
        });

        continue;
      }

      if (booking.status !== "confirmed") continue;

      const oldLocks = await getBookingLocks(env, booking);

      if (
        !oldLocks.seatLock ||
        oldLocks.seatLock.bookingId !== booking.id ||
        !oldLocks.passengerLock ||
        oldLocks.passengerLock.bookingId !== booking.id
      ) {
        throw httpError(
          `Confirmed booking ${booking.id} has missing or mismatched locks`,
          409
        );
      }

      const replacement = await findReplacement(
        booking,
        sourceTrip,
        candidates
      );

      if (!replacement) {
        writes.push(
          writeUpdate(
            `bookings/${booking.id}`,
            {
              status: "cancelled",
              cancellationReason: "driver_stopped_no_replacement",
              cancelledAt: updatedAt,
              updatedAt
            },
            booking._updateTime
          )
        );

        addLockDeletionWrites(writes, booking, oldLocks);

        notifications.push({
          userId: booking.passengerId,
          type: "booking_cancelled",
          title: "Booking cancelled",
          message: "Your confirmed booking was cancelled because no suitable replacement trip was available.",
          data: { bookingId: booking.id, tripId: sourceTrip.id },
          relatedId: booking.id
        });

        continue;
      }

      const nextTrip = replacement.trip;
      const nextSeat = replacement.seatNumber;

      if (!nextTrip._updateTime) {
        throw httpError(
          `Replacement trip ${nextTrip.id} has no update-time version`,
          409
        );
      }

      if (!guardedCandidateTripIds.has(nextTrip.id)) {
        writes.push(
          writeUpdate(
            `trips/${nextTrip.id}`,
            { status: "open", active: true },
            nextTrip._updateTime
          )
        );
        guardedCandidateTripIds.add(nextTrip.id);
      }
      const nextLocks = await getBookingLocks(env, {
        tripId: nextTrip.id,
        seatNumber: nextSeat,
        passengerId: booking.passengerId
      });

      if (nextLocks.seatLock || nextLocks.passengerLock) {
        throw httpError("Replacement seat or passenger lock already exists", 409);
      }

      const nextPassengerLockId = passengerTripLockId(
        booking.passengerId,
        nextTrip.id
      );

      const nextSeatLockId = lockDocumentId(nextTrip.id, nextSeat);

      writes.push(
        writeUpdate(
          `bookings/${booking.id}`,
          {
            tripId: nextTrip.id,
            driverId: nextTrip.driverId,
            driverName: nextTrip.driverName || "",
            origin: nextTrip.origin,
            destination: nextTrip.destination,
            departureAt: nextTrip.departureAt,
            seatNumber: nextSeat,
            updatedAt
          },
          booking._updateTime
        ),
        writeDelete(oldLocks.seatPath, oldLocks.seatLock._updateTime),
        writeDelete(oldLocks.passengerPath, oldLocks.passengerLock._updateTime),
        writeCreate(`seatLocks/${nextSeatLockId}`, {
          id: nextSeatLockId,
          tripId: nextTrip.id,
          seatNumber: nextSeat,
          bookingId: booking.id,
          passengerId: booking.passengerId,
          driverId: nextTrip.driverId,
          status: "confirmed",
          createdAt: updatedAt
        }),
        writeCreate(`passengerTripLocks/${nextPassengerLockId}`, {
          id: nextPassengerLockId,
          tripId: nextTrip.id,
          passengerId: booking.passengerId,
          bookingId: booking.id,
          seatNumber: nextSeat,
          status: "confirmed",
          createdAt: updatedAt
        })
      );

      notifications.push({
        userId: booking.passengerId,
        type: "booking_reassigned",
        title: "Booking reassigned",
        message: `Your booking was moved to another trip. Departure: ${nextTrip.departureAt}. Seat: ${nextSeat}. Driver: ${nextTrip.driverName || "Driver"}.`,
        data: {
          bookingId: booking.id,
          oldTripId: sourceTrip.id,
          tripId: nextTrip.id,
          driverId: nextTrip.driverId,
          driverName: nextTrip.driverName || "",
          origin: nextTrip.origin,
          destination: nextTrip.destination,
          departureAt: nextTrip.departureAt,
          seatNumber: nextSeat
        },
        relatedId: booking.id
      });

      notifications.push({
        userId: nextTrip.driverId,
        type: "booking_reassigned",
        title: "New confirmed booking",
        message: `A confirmed booking was transferred to your trip. Seat: ${nextSeat}.`,
        data: {
          bookingId: booking.id,
          tripId: nextTrip.id,
          passengerId: booking.passengerId,
          passengerName: booking.passengerName || "",
          seatNumber: nextSeat
        },
        relatedId: booking.id
      });
    }

    if (writes.length > 500) {
      throw httpError("Too many records to process for one trip", 409);
    }

    if (driverLock && driverLock.tripId === sourceTrip.id) {
      writes.push(
        writeDelete(driverLockPath, driverLock._updateTime)
      );
    }

    await commit(env, writes);

    if (driverLock && driverLock.tripId === sourceTrip.id) {
      driverLock = null;
    }

    candidateCache.clear();

    for (const item of notifications) {
      try {
        await notifyUser(
          env,
          item.userId,
          item.type,
          item.title,
          item.message,
          item.data,
          item.relatedId
        );
      } catch (error) {
        console.error("Stop-processing notification failed:", error);
      }
    }
  }

  // Individual notifications are sent after each successful trip commit.
  // Return an empty list to prevent the callers from sending duplicate
  // generic cancellation notifications.
  return [];
}

async function approveDriverStop(env, user, requestId) {
  await requireAdmin(env, user);

  const id = assertString(requestId, "stop request ID", 1, 150);
  const request = await getDoc(env, `driverStopRequests/${id}`);

  if (!request) {
    throw httpError("Stop request not found", 404);
  }

  const driver = await getDriver(env, request.driverId);
  let newlyApproved = false;

  if (request.status === "pending") {
    if (
      driver.status !== "approved" ||
      driver.stopStatus !== "pending"
    ) {
      throw httpError("Driver stop request is no longer valid", 409);
    }

    const updatedAt = nowISO();

    await commit(env, [
      writeUpdate(
        `users/${request.driverId}`,
        {
          active: false,
          stopped: true,
          stopStatus: "approved",
          stoppedAt: updatedAt,
          stopApprovedBy: user.uid,
          updatedAt
        },
        driver._updateTime
      ),
      writeUpdate(
        `driverStopRequests/${id}`,
        {
          status: "approved",
          approvedAt: updatedAt,
          approvedBy: user.uid,
          updatedAt
        },
        request._updateTime
      )
    ]);

    newlyApproved = true;
  } else if (request.status === "approved") {
    if (
      driver.status !== "approved" ||
      driver.active !== false ||
      driver.stopped !== true ||
      driver.stopStatus !== "approved"
    ) {
      throw httpError("Approved stop request state is inconsistent", 409);
    }
  } else {
    throw httpError("Stop request is no longer valid", 409);
  }

  if (newlyApproved) {
    try {
      await notifyUser(
        env,
        request.driverId,
        "driver_stop_approved",
        "Driver stop request approved",
        "Your request to stop operating has been approved",
        { requestId: id },
        id
      );
    } catch (error) {
      console.error("Driver stop notification failed:", error);
    }
  }

  await stopDriverOpenTrips(env, request.driverId);

  return {
    success: true,
    status: "approved",
    message: "Driver stopped. Trip processing completed."
  };
}

async function suspendDriver(env, user, driverId, body = {}) {
  await requireAdmin(env, user);

  const id = assertString(driverId, "driver ID", 1, 150);
  const driver = await getDriver(env, id);

  const reason =
    body.reason === undefined
      ? ""
      : assertString(body.reason, "reason", 0, 500);

  let newlySuspended = false;

  if (driver.status === "approved") {
    const updatedAt = nowISO();

    await patchDoc(
      env,
      `users/${id}`,
      {
        status: "suspended",
        active: false,
        suspendedAt: updatedAt,
        suspendedBy: user.uid,
        suspensionReason: reason,
        updatedAt
      },
      driver._updateTime
    );

    newlySuspended = true;
  } else if (driver.status === "suspended") {
    if (driver.active !== false) {
      throw httpError("Suspended driver state is inconsistent", 409);
    }
  } else {
    throw httpError("Only approved drivers can be suspended", 409);
  }

  if (newlySuspended) {
    try {
      await notifyUser(
        env,
        id,
        "driver_suspended",
        "Driver account suspended",
        reason || "Your driver account has been suspended",
        { driverId: id },
        id
      );
    } catch (error) {
      console.error("Driver suspension notification failed:", error);
    }
  }

  await stopDriverOpenTrips(env, id);

  return {
    success: true,
    status: "suspended",
    message: "Driver suspended. Trip processing completed."
  };
}

async function listAllDrivers(env, user) {
  await requireAdmin(env, user);

  const drivers = await query(
    env,
    "users",
    [
      {
        field: "role",
        op: "EQUAL",
        value: "driver"
      }
    ],
    MAX_QUERY_RESULTS
  );

  drivers.sort(
    (a, b) =>
      new Date(b.applicationCreatedAt || 0).getTime() -
      new Date(a.applicationCreatedAt || 0).getTime()
  );

  return {
    success: true,
    drivers
  };
}

// ======================================================
// END PART 6/7
// ======================================================

// ======================================================
// GOLDEN LOUAGE WORKER 5.4.0
// PART 7/7 — API Router, Worker Export, Scheduled Tasks
// ======================================================

function apiResponse(data, status = 200) {
  return new Response(
    JSON.stringify(data),
    {
      status,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store"
      }
    }
  );
}

function corsHeaders(request, env) {
  const origin = request.headers.get("Origin") || "*";

  const allowedOrigin = env.ALLOWED_ORIGIN || "*";

  return {
    "Access-Control-Allow-Origin":
      allowedOrigin === "*" ? "*" : allowedOrigin,
    "Access-Control-Allow-Methods":
      "GET, POST, PATCH, DELETE, OPTIONS",
    "Access-Control-Allow-Headers":
      "Authorization, Content-Type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin"
  };
}

function withCors(response, request, env) {
  const headers = new Headers(response.headers);

  const cors = corsHeaders(request, env);

  for (const [key, value] of Object.entries(cors)) {
    headers.set(key, value);
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

async function readJson(request) {
  try {
    const body = await request.json();

    if (
      !body ||
      typeof body !== "object" ||
      Array.isArray(body)
    ) {
      throw httpError("Invalid request body", 400);
    }

    return body;
  } catch (error) {
    if (error.status) throw error;

    throw httpError("Invalid JSON body", 400);
  }
}

async function authenticateRequest(request) {
  return authUser(request);
}

function getPathId(pathname, prefix) {
  if (!pathname.startsWith(prefix)) return null;

  const id = pathname.slice(prefix.length);

  if (!id || id.includes("/")) return null;

  return decodeURIComponent(id);
}

async function routeRequest(request, env) {
  const url = new URL(request.url);
  const method = request.method.toUpperCase();
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const params = Object.fromEntries(url.searchParams.entries());

  if (method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  if (method === "GET" && path === "/health") {
    return apiResponse({
      success: true,
      service: "Golden Louage API",
      version: VERSION,
      status: "running"
    });
  }

  const user = await authenticateRequest(request);

  let body = {};

  if (
    method === "POST" ||
    method === "PATCH" ||
    method === "PUT"
  ) {
    body = await readJson(request);
  }

  // --------------------------------------------------
  if (method === "POST" && path === "/passengers/profile") {
    return apiResponse(
      await createPassengerProfile(env, user, body)
    );
  }

  // DRIVER APPLICATION
  // --------------------------------------------------

  if (method === "GET" && path === "/passengers/me") {
    const passenger = await requirePassenger(env, user);

    if (passenger.role !== "passenger") {
      throw httpError("Passenger account required", 403);
    }

    return apiResponse({
      success: true,
      passenger
    });
  }

  if (method === "POST" && path === "/drivers/apply") {
    return apiResponse(
      await applyDriver(env, user, body)
    );
  }

  if (method === "GET" && path === "/drivers/me") {
    const profile = await getUserProfile(env, user.uid);

    return apiResponse({
      success: true,
      driver: profile
    });
  }

  if (method === "GET" && path === "/drivers") {
    return apiResponse(
      await listAllDrivers(env, user)
    );
  }

  if (method === "GET" && path === "/drivers/applications") {
    return apiResponse(
      await listDriverApplications(env, user)
    );
  }


  const driverActionMatch = path.match(
    /^\/drivers\/([^/]+)\/(approve|reject|suspend)$/
  );

  if (method === "POST" && driverActionMatch) {
    const id = decodeURIComponent(driverActionMatch[1]);
    const action = driverActionMatch[2];

    if (action === "approve") {
      return apiResponse(
        await approveDriver(env, user, id)
      );
    }

    if (action === "reject") {
      return apiResponse(
        await rejectDriver(env, user, id, body)
      );
    }

    if (action === "suspend") {
      return apiResponse(
        await suspendDriver(env, user, id, body)
      );
    }
  }



  // --------------------------------------------------
  // VEHICLES
  // --------------------------------------------------

  if (method === "POST" && path === "/vehicles") {
    return apiResponse(
      await addVehicle(env, user, body)
    );
  }

  if (method === "GET" && path === "/vehicles/mine") {
    return apiResponse(
      await listMyVehicles(env, user)
    );
  }

  if (method === "GET" && path === "/admin/vehicles") {
    return apiResponse(
      await listAllVehicles(env, user)
    );
  }

  const vehicleActionMatch = path.match(
    /^\/admin\/vehicles\/([^/]+)\/(approve|reject|suspend)$/
  );

  if (method === "POST" && vehicleActionMatch) {
    const id = decodeURIComponent(vehicleActionMatch[1]);
    const action = vehicleActionMatch[2];

    return apiResponse(
      await updateVehicleStatus(env, user, id, action, body)
    );
  }

  // --------------------------------------------------
  // TRIPS
  // --------------------------------------------------

  if (method === "GET" && path === "/admin/trips") {
    return apiResponse(
      await listAdminTrips(env, user)
    );
  }

  if (method === "GET" && path === "/trips") {
    return apiResponse(
      await listOpenTrips(env, user, params)
    );
  }

  if (method === "POST" && path === "/trips") {
    return apiResponse(
      await createTrip(env, user, body)
    );
  }

  const liveLocationMatch = path.match(/^\/trips\/([^/]+)\/location$/);
  if (liveLocationMatch && method === "POST") {
    return apiResponse(
      await updateTripLiveLocation(
        env, user, decodeURIComponent(liveLocationMatch[1]), body
      )
    );
  }
  if (liveLocationMatch && method === "GET") {
    return apiResponse(
      await getTripLiveLocation(
        env, user, decodeURIComponent(liveLocationMatch[1])
      )
    );
  }

  if (method === "GET" && path === "/trips/mine") {
    return apiResponse(
      await listDriverTrips(env, user)
    );
  }

  if (method === "GET" && path === "/trips/details") {
    const tripId = assertString(
      params.tripId,
      "trip ID",
      1,
      150
    );

    return apiResponse(
      await getTripDetails(env, user, tripId)
    );
  }

  if (
    method === "POST" &&
    path.startsWith("/trips/") &&
    path.endsWith("/start")
  ) {
    const id = path.slice(
      "/trips/".length,
      -"/start".length
    );

    return apiResponse(
      await startTrip(env, user, decodeURIComponent(id))
    );
  }

  if (
    method === "POST" &&
    path.startsWith("/trips/") &&
    path.endsWith("/complete")
  ) {
    const id = path.slice(
      "/trips/".length,
      -"/complete".length
    );

    return apiResponse(
      await completeTrip(env, user, decodeURIComponent(id))
    );
  }

  if (
    method === "POST" &&
    path.startsWith("/trips/") &&
    path.endsWith("/cancel")
  ) {
    const id = path.slice(
      "/trips/".length,
      -"/cancel".length
    );

    return apiResponse(
      await cancelTrip(env, user, decodeURIComponent(id))
    );
  }

  if (
    method === "PATCH" &&
    path.startsWith("/trips/")
  ) {
    const id = path.slice("/trips/".length);

    if (!id || id.includes("/")) {
      throw httpError("Invalid trip ID", 400);
    }

    return apiResponse(
      await updateTrip(
        env,
        user,
        decodeURIComponent(id),
        body
      )
    );
  }

  // --------------------------------------------------
  // BOOKINGS
  // --------------------------------------------------

  if (method === "POST" && path === "/bookings") {
    return apiResponse(
      await createBooking(env, user, body)
    );
  }

  if (method === "GET" && path === "/bookings/mine") {
    return apiResponse(
      await listPassengerBookings(env, user)
    );
  }

  if (method === "GET" && path === "/bookings/driver") {
    return apiResponse(
      await listDriverBookings(env, user, params)
    );
  }

  if (
    method === "POST" &&
    path.startsWith("/bookings/") &&
    path.endsWith("/respond")
  ) {
    const id = path.slice(
      "/bookings/".length,
      -"/respond".length
    );

    return apiResponse(
      await respondToBooking(
        env,
        user,
        decodeURIComponent(id),
        body
      )
    );
  }

  if (
    method === "POST" &&
    path.startsWith("/bookings/") &&
    path.endsWith("/confirm")
  ) {
    const id = path.slice(
      "/bookings/".length,
      -"/confirm".length
    );

    return apiResponse(
      await confirmBooking(
        env,
        user,
        decodeURIComponent(id)
      )
    );
  }

  if (
    method === "POST" &&
    path.startsWith("/bookings/") &&
    path.endsWith("/cancel")
  ) {
    const id = path.slice(
      "/bookings/".length,
      -"/cancel".length
    );

    return apiResponse(
      await cancelBooking(
        env,
        user,
        decodeURIComponent(id)
      )
    );
  }

  // --------------------------------------------------
  // DRIVER STOP REQUESTS
  // --------------------------------------------------

  if (
    method === "POST" &&
    path === "/drivers/stop-request"
  ) {
    return apiResponse(
      await requestDriverStop(env, user, body)
    );
  }

  if (
    method === "GET" &&
    path === "/admin/driver-stop-requests"
  ) {
    return apiResponse(
      await listDriverStopRequests(env, user)
    );
  }

  if (
    method === "POST" &&
    path.startsWith("/admin/driver-stop-requests/") &&
    path.endsWith("/approve")
  ) {
    const id = path.slice(
      "/admin/driver-stop-requests/".length,
      -"/approve".length
    );

    return apiResponse(
      await approveDriverStop(
        env,
        user,
        decodeURIComponent(id)
      )
    );
  }



  throw httpError("Route not found", 404);
}

// ======================================================
// AUTOMATIC EXPIRATION OF HELD BOOKINGS
// ======================================================

async function expireOldBookings(env) {
  const bookings = await query(
    env,
    "bookings",
    [
      {
        field: "status",
        op: "EQUAL",
        value: "held"
      }
    ],
    MAX_QUERY_RESULTS
  );

  let expiredCount = 0;

  for (const booking of bookings) {
    if (
      booking.holdExpiresAt &&
      isExpired(booking.holdExpiresAt)
    ) {
      try {
        const result = await expireBooking(
          env,
          booking.id
        );

        if (result.expired) {
          expiredCount++;
        }
      } catch (error) {
        // Another request may have changed this booking.
        // Continue processing the remaining bookings.
      }
    }
  }

  return expiredCount;
}

// ======================================================

// ======================================================
// AUTOMATIC COMPLETION OF OLD TRIPS
// ======================================================
async function completeOldTrips(env) {
  const trips = [];

  for (const status of ["open", "scheduled"]) {
    const matching = await query(
      env,
      "trips",
      [{ field: "status", op: "EQUAL", value: status }],
      MAX_QUERY_RESULTS
    );

    trips.push(...matching);
  }

  const cutoff = Date.now() - 60 * 60 * 1000;
  let startedCount = 0;

  for (const trip of trips) {
    const departureTime = new Date(trip.departureAt).getTime();

    if (
      !Number.isFinite(departureTime) ||
      departureTime > cutoff ||
      !trip._updateTime ||
      !trip.vehicleId
    ) {
      continue;
    }

    const updatedAt = nowISO();

    try {
      const vehicleLockPath =
        `vehicleActiveLocks/${trip.vehicleId}`;

      const vehicleLock = await getDoc(env, vehicleLockPath);

      if (vehicleLock && vehicleLock.tripId !== trip.id) {
        continue;
      }

      const driverLockPath = trip.driverId
        ? `driverTripLocks/${trip.driverId}`
        : null;

      const driverLock = driverLockPath
        ? await getDoc(env, driverLockPath)
        : null;

      const lock = {
        vehicleId: trip.vehicleId,
        vehicleRegistration: trip.vehicleRegistration || "",
        tripId: trip.id,
        driverId: trip.driverId,
        startedAt: updatedAt,
        createdAt: updatedAt
      };

      const writes = [
        writeUpdate(
          `trips/${trip.id}`,
          {
            status: "started",
            startedAt: updatedAt,
            updatedAt
          },
          trip._updateTime
        )
      ];

      if (!vehicleLock) {
        writes.push(writeCreate(vehicleLockPath, lock));
      }

      if (driverLock && driverLock.tripId === trip.id) {
        writes.push(
          writeDelete(driverLockPath, driverLock._updateTime)
        );
      }

      await commit(env, writes);
      startedCount++;
    } catch (error) {
      // Ignore conflicts and continue with other trips.
    }
  }

  return startedCount;
}

// CLOUDFLARE WORKER EXPORT
// ======================================================

export default {
  async fetch(request, env, ctx) {
    try {
      const response = await routeRequest(
        request,
        env
      );

      return withCors(response, request, env);
    } catch (error) {
      const status = Number(error.status) || 500;

      const response = apiResponse(
        {
          success: false,
          error:
            status >= 500
              ? "Internal server error"
              : error.message || "Request failed",
          version: VERSION
        },
        status
      );

      return withCors(response, request, env);
    }
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(
      expireOldBookings(env).catch(error => {
        return 0;
      })
    );

    ctx.waitUntil(
      completeOldTrips(env).catch(error => {
        return 0;
      })
    );
  }
};

// ======================================================
// END PART 7/7 — VERSION 5.4.0
// ======================================================
