const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");

initializeApp();

exports.createUserAccount = onCall({ region: "europe-west1" }, async (request) => {
  if (!request.auth || !request.auth.token || !request.auth.token.email) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const callerEmail = String(request.auth.token.email).trim().toLowerCase();
  const callerSnapshot = await getFirestore()
    .collection("users")
    .where("email", "==", callerEmail)
    .limit(1)
    .get();

  if (callerSnapshot.empty) {
    throw new HttpsError("permission-denied", "Admin account not found.");
  }

  const caller = callerSnapshot.docs[0].data();
  if (caller.role !== "admin" || caller.active === false) {
    throw new HttpsError("permission-denied", "Only active admins can create users.");
  }

  const data = request.data || {};
  const id = String(data.id || "").trim();
  const username = String(data.username || "").trim();
  const email = String(data.email || "").trim().toLowerCase();
  const password = String(data.password || "");
  const role = String(data.role || "worker").trim();
  const active = data.active !== false;
  const allowedProjectIds = Array.isArray(data.allowedProjectIds)
    ? data.allowedProjectIds.map((item) => String(item)).filter(Boolean)
    : [];

  if (!id || !username || !email || !password) {
    throw new HttpsError("invalid-argument", "id, username, email and password are required.");
  }

  try {
    const userRecord = await getAuth().createUser({
      uid: id,
      email,
      password,
      displayName: username,
      disabled: !active,
    });

    await getFirestore().collection("users").doc(id).set({
      username,
      email,
      role,
      active,
      allowedProjectIds,
      authUid: userRecord.uid,
      createdAt: new Date(),
    });

    return {
      success: true,
      uid: userRecord.uid,
      email: userRecord.email,
    };
  } catch (error) {
    logger.error("createUserAccount failed", {
      callerEmail,
      id,
      username,
      email,
      role,
      errorCode: error && typeof error === "object" ? error.code : undefined,
      errorMessage: error instanceof Error ? error.message : String(error),
    });

    const errorCode = error && typeof error === "object" ? error.code : "";
    const message = error instanceof Error ? error.message : "Failed to create user.";

    if (errorCode === "auth/email-already-exists") {
      throw new HttpsError("already-exists", "Već postoji korisnik s tim e-mailom.");
    }

    if (errorCode === "auth/uid-already-exists") {
      throw new HttpsError("already-exists", "Već postoji korisnik s tim ID-em.");
    }

    if (errorCode === "auth/invalid-password") {
      throw new HttpsError("invalid-argument", "Lozinka ne zadovoljava uvjete.");
    }

    throw new HttpsError("internal", message);
  }
});

exports.updateUserAccount = onCall({ region: "europe-west1" }, async (request) => {
  if (!request.auth || !request.auth.token || !request.auth.token.email) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const callerEmail = String(request.auth.token.email).trim().toLowerCase();
  const callerSnapshot = await getFirestore()
    .collection("users")
    .where("email", "==", callerEmail)
    .limit(1)
    .get();

  if (callerSnapshot.empty) {
    throw new HttpsError("permission-denied", "Admin account not found.");
  }

  const caller = callerSnapshot.docs[0].data();
  if (caller.role !== "admin" || caller.active === false) {
    throw new HttpsError("permission-denied", "Only active admins can update users.");
  }

  const data = request.data || {};
  const id = String(data.id || "").trim();
  const username = String(data.username || "").trim();
  const email = String(data.email || "").trim().toLowerCase();
  const role = String(data.role || "worker").trim();
  const active = data.active !== false;
  const allowedProjectIds = Array.isArray(data.allowedProjectIds)
    ? data.allowedProjectIds.map((item) => String(item)).filter(Boolean)
    : [];

  if (!id || !username || !email) {
    throw new HttpsError("invalid-argument", "id, username and email are required.");
  }

  try {
    await getAuth().updateUser(id, {
      email,
      displayName: username,
      disabled: !active,
    });

    await getFirestore().collection("users").doc(id).set({
      username,
      email,
      role,
      active,
      allowedProjectIds,
      authUid: id,
      updatedAt: new Date(),
    }, { merge: true });

    return {
      success: true,
      uid: id,
      email,
    };
  } catch (error) {
    logger.error("updateUserAccount failed", {
      callerEmail,
      id,
      username,
      email,
      role,
      errorCode: error && typeof error === "object" ? error.code : undefined,
      errorMessage: error instanceof Error ? error.message : String(error),
    });

    const errorCode = error && typeof error === "object" ? error.code : "";
    const message = error instanceof Error ? error.message : "Failed to update user.";

    if (errorCode === "auth/email-already-exists") {
      throw new HttpsError("already-exists", "Već postoji korisnik s tim e-mailom.");
    }

    if (errorCode === "auth/user-not-found") {
      throw new HttpsError("not-found", "Korisnik ne postoji u Authentication.");
    }

    throw new HttpsError("internal", message);
  }
});
