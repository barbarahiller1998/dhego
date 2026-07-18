const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { logger } = require("firebase-functions");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");

initializeApp();
const RESEND_API_KEY = defineSecret("RESEND_API_KEY");

function isManagerLikeRole(role) {
  return role === "site_manager" || role === "obermonteur";
}

async function requireActiveUserManager(request) {
  if (!request.auth || !request.auth.token || !request.auth.token.email) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const callerEmail = String(request.auth.token.email).trim().toLowerCase();
  return requireActiveUserManagerByEmail(callerEmail);
}

async function requireActiveUserManagerByEmail(callerEmail) {
  const callerSnapshot = await getFirestore()
    .collection("users")
    .where("email", "==", callerEmail)
    .limit(1)
    .get();

  if (callerSnapshot.empty) {
    throw new HttpsError("permission-denied", "User account not found.");
  }

  const caller = callerSnapshot.docs[0].data() || {};
  const callerRole = String(caller.role || "").trim();
  if (caller.active === false || (callerRole !== "admin" && !isManagerLikeRole(callerRole))) {
    throw new HttpsError("permission-denied", "Only active admins or site managers can manage users.");
  }

  return {
    callerEmail,
    callerRole,
    allowedProjectIds: Array.isArray(caller.allowedProjectIds)
      ? caller.allowedProjectIds.map((item) => String(item)).filter(Boolean)
      : [],
  };
}

async function requireActiveUserManagerFromHttp(request) {
  const authHeader = String(request.headers.authorization || "").trim();
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const idToken = authHeader.substring(7).trim();
  if (!idToken) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const decodedToken = await getAuth().verifyIdToken(idToken);
  const callerEmail = String(decodedToken.email || "").trim().toLowerCase();
  if (!callerEmail) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  return requireActiveUserManagerByEmail(callerEmail);
}

function mapAuthError(errorCode, fallbackMessage) {
  if (errorCode === "auth/email-already-exists") {
    return new HttpsError("already-exists", "Vec postoji korisnik s tim e-mailom.");
  }

  if (errorCode === "auth/uid-already-exists") {
    return new HttpsError("already-exists", "Vec postoji korisnik s tim ID-em.");
  }

  if (errorCode === "auth/invalid-password") {
    return new HttpsError("invalid-argument", "Lozinka ne zadovoljava uvjete.");
  }

  if (errorCode === "auth/invalid-email") {
    return new HttpsError("invalid-argument", "E-mail nije ispravan.");
  }

  if (errorCode === "auth/user-not-found") {
    return new HttpsError("not-found", "Korisnik ne postoji u Authentication.");
  }

  return new HttpsError("internal", fallbackMessage);
}

function buildFriendlyAuthError(errorCode, fallbackMessage) {
  return {
    success: false,
    errorCode: errorCode || "internal",
    message: mapAuthError(errorCode, fallbackMessage).message,
  };
}

function sanitizeAllowedTaskGroupsByProject(rawValue, allowedProjectIds) {
  const allowedProjects = Array.isArray(allowedProjectIds)
    ? allowedProjectIds.map((item) => String(item)).filter(Boolean)
    : [];
  const allowedSet = new Set(allowedProjects);
  const source = rawValue && typeof rawValue === "object" ? rawValue : {};
  const result = {};

  for (const [projectIdRaw, groupsRaw] of Object.entries(source)) {
    const projectId = String(projectIdRaw || "").trim();
    if (!projectId || !allowedSet.has(projectId)) {
      continue;
    }

    const groups = Array.isArray(groupsRaw)
      ? [...new Set(groupsRaw.map((item) => String(item || "").trim()).filter(Boolean))]
      : [];
    groups.sort((a, b) => a.localeCompare(b));
    result[projectId] = groups;
  }

  return result;
}

function allowedManagedRolesForCaller(callerRole) {
  if (callerRole === "site_manager") {
    return ["worker"];
  }

  if (callerRole === "obermonteur") {
    return ["worker", "site_manager"];
  }

  return ["worker", "site_manager", "obermonteur", "admin"];
}

async function createUserAccountInternal(data, manager) {
  const { callerRole, allowedProjectIds: managerProjectIds } = manager;
  const id = String(data.id || "").trim();
  const username = String(data.username || "").trim();
  const fullName = String(data.fullName || username).trim();
  const email = String(data.email || "").trim().toLowerCase();
  const password = String(data.password || "");
  const role = String(data.role || "worker").trim();
  const active = data.active !== false;
  let allowedProjectIds = Array.isArray(data.allowedProjectIds)
    ? data.allowedProjectIds.map((item) => String(item)).filter(Boolean)
    : [];

  if (isManagerLikeRole(callerRole)) {
    const allowedRoles = allowedManagedRolesForCaller(callerRole);
    if (!allowedRoles.includes(role)) {
      return {
        success: false,
        errorCode: "permission-denied",
        message: "Voditelj gradilišta može dodavati samo radnike.",
      };
    }
    allowedProjectIds = allowedProjectIds.filter((projectId) =>
      managerProjectIds.includes(projectId),
    );
  }
  const allowedTaskGroupsByProject = sanitizeAllowedTaskGroupsByProject(
    data.allowedTaskGroupsByProject,
    allowedProjectIds,
  );

  if (!id || !username || !fullName || !email || !password) {
    return {
      success: false,
      errorCode: "invalid-argument",
      message: "Nedostaju obavezni podaci za korisnika.",
    };
  }

  const userRecord = await getAuth().createUser({
    uid: id,
    email,
    password,
    displayName: fullName,
    disabled: !active,
  });

  await getFirestore().collection("users").doc(id).set({
    username,
    fullName,
    email,
    role,
    active,
    allowedProjectIds,
    allowedTaskGroupsByProject,
    authUid: userRecord.uid,
    createdAt: new Date(),
  });

  return {
    success: true,
    uid: userRecord.uid,
    email: userRecord.email,
  };
}

async function updateUserAccountInternal(data, manager) {
  const { callerRole, allowedProjectIds: managerProjectIds } = manager;
  const id = String(data.id || "").trim();
  const username = String(data.username || "").trim();
  const fullName = String(data.fullName || username).trim();
  const email = String(data.email || "").trim().toLowerCase();
  const role = String(data.role || "worker").trim();
  const active = data.active !== false;
  let allowedProjectIds = Array.isArray(data.allowedProjectIds)
    ? data.allowedProjectIds.map((item) => String(item)).filter(Boolean)
    : [];

  if (isManagerLikeRole(callerRole)) {
    const existingUserSnapshot = await getFirestore().collection("users").doc(id).get();
    const existingRole = String(existingUserSnapshot.data()?.role || "").trim();
    const allowedRoles = allowedManagedRolesForCaller(callerRole);
    if (!allowedRoles.includes(role) || !allowedRoles.includes(existingRole)) {
      return {
        success: false,
        errorCode: "permission-denied",
        message: "Voditelj gradilišta može uređivati samo radnike.",
      };
    }
    allowedProjectIds = allowedProjectIds.filter((projectId) =>
      managerProjectIds.includes(projectId),
    );
  }
  const allowedTaskGroupsByProject = sanitizeAllowedTaskGroupsByProject(
    data.allowedTaskGroupsByProject,
    allowedProjectIds,
  );

  if (!id || !username || !fullName || !email) {
    return {
      success: false,
      errorCode: "invalid-argument",
      message: "Nedostaju obavezni podaci za korisnika.",
    };
  }

  await getAuth().updateUser(id, {
    email,
    displayName: fullName,
    disabled: !active,
  });

  await getFirestore().collection("users").doc(id).set({
    username,
    fullName,
    email,
    role,
    active,
    allowedProjectIds,
    allowedTaskGroupsByProject,
    authUid: id,
    updatedAt: new Date(),
  }, { merge: true });

  return {
    success: true,
    uid: id,
    email,
  };
}

exports.createUserAccount = onCall({ region: "europe-west1" }, async (request) => {
  try {
  const { callerEmail, callerRole, allowedProjectIds: managerProjectIds } =
    await requireActiveUserManager(request);

  const data = request.data || {};
  const id = String(data.id || "").trim();
  const username = String(data.username || "").trim();
  const fullName = String(data.fullName || username).trim();
  const email = String(data.email || "").trim().toLowerCase();
  const password = String(data.password || "");
  const role = String(data.role || "worker").trim();
  const active = data.active !== false;
  let allowedProjectIds = Array.isArray(data.allowedProjectIds)
    ? data.allowedProjectIds.map((item) => String(item)).filter(Boolean)
    : [];

  if (isManagerLikeRole(callerRole)) {
    const allowedRoles = allowedManagedRolesForCaller(callerRole);
    if (!allowedRoles.includes(role)) {
      return {
        success: false,
        errorCode: "permission-denied",
        message: "Voditelj gradilišta može dodavati samo radnike.",
      };
    }
    allowedProjectIds = allowedProjectIds.filter((projectId) =>
      managerProjectIds.includes(projectId),
    );
  }
  const allowedTaskGroupsByProject = sanitizeAllowedTaskGroupsByProject(
    data.allowedTaskGroupsByProject,
    allowedProjectIds,
  );

  if (!id || !username || !fullName || !email || !password) {
    return {
      success: false,
      errorCode: "invalid-argument",
      message: "Nedostaju obavezni podaci za korisnika.",
    };
  }

  try {
    const userRecord = await getAuth().createUser({
      uid: id,
      email,
      password,
      displayName: fullName,
      disabled: !active,
    });

    await getFirestore().collection("users").doc(id).set({
      username,
      fullName,
      email,
      role,
      active,
      allowedProjectIds,
      allowedTaskGroupsByProject,
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
      fullName,
      email,
      role,
      errorCode: error && typeof error === "object" ? error.code : undefined,
      errorMessage: error instanceof Error ? error.message : String(error),
    });

    const errorCode = error && typeof error === "object" ? error.code : "";
    const message = error instanceof Error ? error.message : "Failed to create user.";
    return buildFriendlyAuthError(errorCode, message);
  }
  } catch (error) {
    if (error instanceof HttpsError) {
      return {
        success: false,
        errorCode: error.code || "internal",
        message: error.message || "Nije moguće dodati novog korisnika.",
      };
    }

    logger.error("createUserAccount request failed", {
      callerEmail: request?.auth?.token?.email || "",
      errorCode: error && typeof error === "object" ? error.code : undefined,
      errorMessage: error instanceof Error ? error.message : String(error),
    });

    return {
      success: false,
      errorCode: "internal",
      message: "Nije moguće dodati novog korisnika.",
    };
  }
});

exports.updateUserAccount = onCall({ region: "europe-west1" }, async (request) => {
  try {
  const { callerEmail, callerRole, allowedProjectIds: managerProjectIds } =
    await requireActiveUserManager(request);

  const data = request.data || {};
  const id = String(data.id || "").trim();
  const username = String(data.username || "").trim();
  const fullName = String(data.fullName || username).trim();
  const email = String(data.email || "").trim().toLowerCase();
  const role = String(data.role || "worker").trim();
  const active = data.active !== false;
  let allowedProjectIds = Array.isArray(data.allowedProjectIds)
    ? data.allowedProjectIds.map((item) => String(item)).filter(Boolean)
    : [];

  if (isManagerLikeRole(callerRole)) {
    const existingUserSnapshot = await getFirestore().collection("users").doc(id).get();
    const existingRole = String(existingUserSnapshot.data()?.role || "").trim();
    const allowedRoles = allowedManagedRolesForCaller(callerRole);
    if (!allowedRoles.includes(role) || !allowedRoles.includes(existingRole)) {
      return {
        success: false,
        errorCode: "permission-denied",
        message: "Voditelj gradilišta može uređivati samo radnike.",
      };
    }
    allowedProjectIds = allowedProjectIds.filter((projectId) =>
      managerProjectIds.includes(projectId),
    );
  }
  const allowedTaskGroupsByProject = sanitizeAllowedTaskGroupsByProject(
    data.allowedTaskGroupsByProject,
    allowedProjectIds,
  );

  if (!id || !username || !fullName || !email) {
    return {
      success: false,
      errorCode: "invalid-argument",
      message: "Nedostaju obavezni podaci za korisnika.",
    };
  }

  try {
    await getAuth().updateUser(id, {
      email,
      displayName: fullName,
      disabled: !active,
    });

    await getFirestore().collection("users").doc(id).set({
      username,
      fullName,
      email,
      role,
      active,
      allowedProjectIds,
      allowedTaskGroupsByProject,
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
      fullName,
      email,
      role,
      errorCode: error && typeof error === "object" ? error.code : undefined,
      errorMessage: error instanceof Error ? error.message : String(error),
    });

    const errorCode = error && typeof error === "object" ? error.code : "";
    const message = error instanceof Error ? error.message : "Failed to update user.";
    return buildFriendlyAuthError(errorCode, message);
  }
  } catch (error) {
    if (error instanceof HttpsError) {
      return {
        success: false,
        errorCode: error.code || "internal",
        message: error.message || "Nije moguće ažurirati korisnika.",
      };
    }

    logger.error("updateUserAccount request failed", {
      callerEmail: request?.auth?.token?.email || "",
      errorCode: error && typeof error === "object" ? error.code : undefined,
      errorMessage: error instanceof Error ? error.message : String(error),
    });

    return {
      success: false,
      errorCode: "internal",
      message: "Nije moguće ažurirati korisnika.",
    };
  }
});

exports.createUserAccountHttp = onRequest({ region: "europe-west1", cors: true }, async (request, response) => {
  if (request.method === "OPTIONS") {
    response.status(204).send("");
    return;
  }

  if (request.method !== "POST") {
    response.status(405).json({ success: false, errorCode: "method-not-allowed", message: "Method not allowed." });
    return;
  }

  try {
    const manager = await requireActiveUserManagerFromHttp(request);
    try {
      const result = await createUserAccountInternal(request.body || {}, manager);
      response.status(result.success ? 200 : 400).json(result);
    } catch (error) {
      logger.error("createUserAccountHttp failed", {
        callerEmail: manager.callerEmail,
        id: request?.body?.id || "",
        username: request?.body?.username || "",
        fullName: request?.body?.fullName || "",
        email: request?.body?.email || "",
        role: request?.body?.role || "",
        errorCode: error && typeof error === "object" ? error.code : undefined,
        errorMessage: error instanceof Error ? error.message : String(error),
      });

      const errorCode = error && typeof error === "object" ? error.code : "";
      const message = error instanceof Error ? error.message : "Failed to create user.";
      response.status(400).json(buildFriendlyAuthError(errorCode, message));
    }
  } catch (error) {
    const status = error instanceof HttpsError && error.code === "unauthenticated"
      ? 401
      : error instanceof HttpsError && error.code === "permission-denied"
        ? 403
        : 400;
    response.status(status).json({
      success: false,
      errorCode: error instanceof HttpsError ? error.code : "internal",
      message: error instanceof HttpsError
        ? error.message
        : "Nije moguće dodati novog korisnika.",
    });
  }
});

exports.updateUserAccountHttp = onRequest({ region: "europe-west1", cors: true }, async (request, response) => {
  if (request.method === "OPTIONS") {
    response.status(204).send("");
    return;
  }

  if (request.method !== "POST") {
    response.status(405).json({ success: false, errorCode: "method-not-allowed", message: "Method not allowed." });
    return;
  }

  try {
    const manager = await requireActiveUserManagerFromHttp(request);
    try {
      const result = await updateUserAccountInternal(request.body || {}, manager);
      response.status(result.success ? 200 : 400).json(result);
    } catch (error) {
      logger.error("updateUserAccountHttp failed", {
        callerEmail: manager.callerEmail,
        id: request?.body?.id || "",
        username: request?.body?.username || "",
        fullName: request?.body?.fullName || "",
        email: request?.body?.email || "",
        role: request?.body?.role || "",
        errorCode: error && typeof error === "object" ? error.code : undefined,
        errorMessage: error instanceof Error ? error.message : String(error),
      });

      const errorCode = error && typeof error === "object" ? error.code : "";
      const message = error instanceof Error ? error.message : "Failed to update user.";
      response.status(400).json(buildFriendlyAuthError(errorCode, message));
    }
  } catch (error) {
    const status = error instanceof HttpsError && error.code === "unauthenticated"
      ? 401
      : error instanceof HttpsError && error.code === "permission-denied"
        ? 403
        : 400;
    response.status(status).json({
      success: false,
      errorCode: error instanceof HttpsError ? error.code : "internal",
      message: error instanceof HttpsError
        ? error.message
        : "Nije moguće ažurirati korisnika.",
    });
  }
});

exports.syncAuthUsersToFirestoreHttp = onRequest({ region: "europe-west1", cors: true }, async (request, response) => {
  if (request.method === "OPTIONS") {
    response.status(204).send("");
    return;
  }

  if (request.method !== "POST") {
    response.status(405).json({ success: false, errorCode: "method-not-allowed", message: "Method not allowed." });
    return;
  }

  try {
    const manager = await requireActiveUserManagerFromHttp(request);
    if (manager.callerRole !== "admin") {
      response.status(403).json({
        success: false,
        errorCode: "permission-denied",
        message: "Samo admin može sinkronizirati korisnike.",
      });
      return;
    }

    const auth = getAuth();
    const db = getFirestore();
    let nextPageToken = undefined;
    let syncedCount = 0;

    do {
      const result = await auth.listUsers(1000, nextPageToken);
      nextPageToken = result.pageToken;

      for (const userRecord of result.users) {
        const userDocRef = db.collection("users").doc(userRecord.uid);
        const existingDoc = await userDocRef.get();
        const existingData = existingDoc.exists ? existingDoc.data() || {} : {};

        await userDocRef.set({
          username: String(existingData.username || userRecord.displayName || userRecord.uid),
          fullName: String(existingData.fullName || userRecord.displayName || existingData.username || userRecord.uid),
          email: String(existingData.email || userRecord.email || "").trim().toLowerCase(),
          role: String(existingData.role || "worker"),
          active: typeof existingData.active === "boolean" ? existingData.active : !userRecord.disabled,
          allowedProjectIds: Array.isArray(existingData.allowedProjectIds) ? existingData.allowedProjectIds : [],
          authUid: userRecord.uid,
          updatedAt: new Date(),
          createdAt: existingData.createdAt || new Date(),
        }, { merge: true });

        syncedCount += 1;
      }
    } while (nextPageToken);

    response.status(200).json({
      success: true,
      syncedCount: String(syncedCount),
    });
  } catch (error) {
    response.status(error instanceof HttpsError && error.code === "unauthenticated" ? 401 : 400).json({
      success: false,
      errorCode: error instanceof HttpsError ? error.code : "internal",
      message: error instanceof HttpsError
        ? error.message
        : "Nije moguće sinkronizirati korisnike.",
    });
  }
});

exports.syncAuthUsersToFirestore = onCall({ region: "europe-west1" }, async (request) => {
  const { callerRole } = await requireActiveUserManager(request);
  if (callerRole !== "admin") {
    throw new HttpsError("permission-denied", "Only active admins can sync users.");
  }

  const auth = getAuth();
  const db = getFirestore();
  let nextPageToken = undefined;
  let syncedCount = 0;

  do {
    const result = await auth.listUsers(1000, nextPageToken);
    nextPageToken = result.pageToken;

    for (const userRecord of result.users) {
      const userDocRef = db.collection("users").doc(userRecord.uid);
      const existingDoc = await userDocRef.get();
      const existingData = existingDoc.exists ? existingDoc.data() || {} : {};

      await userDocRef.set({
        username: String(existingData.username || userRecord.displayName || userRecord.uid),
        fullName: String(existingData.fullName || userRecord.displayName || existingData.username || userRecord.uid),
        email: String(existingData.email || userRecord.email || "").trim().toLowerCase(),
        role: String(existingData.role || "worker"),
        active: typeof existingData.active === "boolean" ? existingData.active : !userRecord.disabled,
        allowedProjectIds: Array.isArray(existingData.allowedProjectIds) ? existingData.allowedProjectIds : [],
        authUid: userRecord.uid,
        updatedAt: new Date(),
        createdAt: existingData.createdAt || new Date(),
      }, { merge: true });

      syncedCount += 1;
    }
  } while (nextPageToken);

  return {
    success: true,
    syncedCount,
  };
});

function escapeCsvValue(value) {
  const stringValue = String(value || "");
  if (stringValue.includes(";") || stringValue.includes('"') || stringValue.includes("\n")) {
    return `"${stringValue.replace(/"/g, '""')}"`;
  }
  return stringValue;
}

function escapeHtml(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatSlotDateTime(date) {
  return new Intl.DateTimeFormat("hr-HR", {
    timeZone: "Europe/Zagreb",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

function formatOrderTime(date) {
  return new Intl.DateTimeFormat("de-DE", {
    timeZone: "Europe/Zagreb",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

async function resolveProjectRecipient(projectId, fallbackOrder) {
  const fallbackEmail = String(fallbackOrder.managerEmail || "").trim().toLowerCase();
  const fallbackName = String(fallbackOrder.managerName || "").trim();
  const fallbackManagerId = String(fallbackOrder.managerId || "").trim();

  const projectDoc = await getFirestore().collection("projects").doc(projectId).get();
  const projectData = projectDoc.exists ? projectDoc.data() || {} : {};

  let email = String(projectData.managerEmail || fallbackEmail || "").trim().toLowerCase();
  let name = String(projectData.managerName || fallbackName || "").trim();
  const managerId = String(projectData.managerId || fallbackManagerId || "").trim();

  if ((!email || !name) && managerId) {
    const userDoc = await getFirestore().collection("users").doc(managerId).get();
    if (userDoc.exists) {
      const userData = userDoc.data() || {};
      if (!email) {
        email = String(userData.email || "").trim().toLowerCase();
      }
      if (!name) {
        name = String(userData.fullName || userData.username || "").trim();
      }
    }
  }

  return { email, name, managerId };
}

function buildOrderEmailRows(orders) {
  const rows = [];
  for (const order of orders) {
    const createdAt = order.createdAt && typeof order.createdAt.toDate === "function"
      ? order.createdAt.toDate()
      : null;
    const orderedByWithTime = createdAt
      ? `${formatOrderTime(createdAt)} - ${String(order.orderedBy || "").trim()}`
      : String(order.orderedBy || "").trim();
    const items = Array.isArray(order.items) ? order.items : [];
    for (const item of items) {
      rows.push({
        orderedBy: orderedByWithTime,
        buildingName: String(order.buildingName || "").trim(),
        category: String(item.category || "").trim(),
        articleNumber: String(item.articleNumber || "").trim(),
        name: String(item.name || "").trim(),
        quantity: String(item.quantity || "").trim(),
        supplier: String(item.supplier || "").trim(),
        note: String(order.note || "").trim(),
      });
    }
  }
  return rows;
}

function buildOrderCsv(rows) {
  const header = [
    "Gesendet von",
    "Gebäude",
    "Kategorie",
    "Artikelnummer",
    "Bezeichnung",
    "Menge",
    "Lieferant",
    "Notiz",
  ];

  const lines = [header.map(escapeCsvValue).join(";")];
  for (const row of rows) {
    lines.push(
      [
        row.orderedBy,
        row.buildingName,
        row.category,
        row.articleNumber,
        row.name,
        row.quantity,
        row.supplier,
        row.note,
      ].map(escapeCsvValue).join(";"),
    );
  }
  return lines.join("\n");
}

function buildOrderHtml(projectName, slotLabel, scheduledAt, recipientName, rows) {
  const tableRows = rows.map((row) => `
    <tr>
      <td>${escapeHtml(row.orderedBy)}</td>
      <td>${escapeHtml(row.buildingName)}</td>
      <td>${escapeHtml(row.category)}</td>
      <td>${escapeHtml(row.articleNumber)}</td>
      <td>${escapeHtml(row.name)}</td>
      <td style="text-align:right;">${escapeHtml(row.quantity)}</td>
      <td>${escapeHtml(row.supplier)}</td>
      <td>${escapeHtml(row.note)}</td>
    </tr>`).join("");

  return `
    <div style="font-family:Arial,Helvetica,sans-serif;color:#1f2937;">
      <p>Guten Tag ${escapeHtml(recipientName || "")},</p>
      <p>anbei und unten finden Sie die gebündelten DHEgo-Bestellungen für das Projekt <strong>${escapeHtml(projectName)}</strong> zum Termin <strong>${escapeHtml(slotLabel)}</strong> (${escapeHtml(formatSlotDateTime(scheduledAt))}).</p>
      <table style="border-collapse:collapse;width:100%;font-size:14px;">
        <thead>
          <tr>
            <th style="border:1px solid #cbd5e1;padding:6px 8px;text-align:left;background:#f8fafc;">Gesendet von</th>
            <th style="border:1px solid #cbd5e1;padding:6px 8px;text-align:left;background:#f8fafc;">Gebäude</th>
            <th style="border:1px solid #cbd5e1;padding:6px 8px;text-align:left;background:#f8fafc;">Kategorie</th>
            <th style="border:1px solid #cbd5e1;padding:6px 8px;text-align:left;background:#f8fafc;">Artikelnummer</th>
            <th style="border:1px solid #cbd5e1;padding:6px 8px;text-align:left;background:#f8fafc;">Bezeichnung</th>
            <th style="border:1px solid #cbd5e1;padding:6px 8px;text-align:right;background:#f8fafc;">Menge</th>
            <th style="border:1px solid #cbd5e1;padding:6px 8px;text-align:left;background:#f8fafc;">Lieferant</th>
            <th style="border:1px solid #cbd5e1;padding:6px 8px;text-align:left;background:#f8fafc;">Notiz</th>
          </tr>
        </thead>
        <tbody>${tableRows}</tbody>
      </table>
      <p style="margin-top:16px;">DHEgo</p>
    </div>`;
}

async function sendResendEmail({ to, subject, html, attachments }) {
  const apiKey = RESEND_API_KEY.value();
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: "DHEgo <orders@dhego.app>",
      to: [to],
      subject,
      html,
      attachments,
    }),
  });

  const json = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`Resend send failed (${response.status}): ${JSON.stringify(json)}`);
  }
  return json;
}

async function deliverOrderBatch(dueOrders, slotLabelOverride = "") {
  if (dueOrders.length === 0) {
    logger.info(`No pending order requests${slotLabelOverride ? ` for slot ${slotLabelOverride}` : ""}.`);
    return { sentOrderCount: 0, sentProjectCount: 0 };
  }

  const ordersByProject = new Map();
  for (const order of dueOrders) {
    const projectId = String(order.projectId || "").trim();
    if (!projectId) {
      continue;
    }
    if (!ordersByProject.has(projectId)) {
      ordersByProject.set(projectId, []);
    }
    ordersByProject.get(projectId).push(order);
  }

  let sentOrderCount = 0;
  let sentProjectCount = 0;

  for (const [projectId, orders] of ordersByProject.entries()) {
    const firstOrder = orders[0];
    const projectName = String(firstOrder.projectName || projectId).trim();
    const recipient = await resolveProjectRecipient(projectId, firstOrder);
    if (!recipient.email) {
      logger.error(`Skipping order batch for project ${projectId}: missing recipient email.`);
      const batch = getFirestore().batch();
      for (const order of orders) {
        batch.set(order.ref, {
          lastAttemptAt: new Date(),
          lastError: "Missing project manager email.",
        }, { merge: true });
      }
      await batch.commit();
      continue;
    }

    const rows = buildOrderEmailRows(orders);
    const csv = buildOrderCsv(rows);
    const scheduledAt = firstOrder.scheduledAt && typeof firstOrder.scheduledAt.toDate === "function"
      ? firstOrder.scheduledAt.toDate()
      : new Date();
    const slotLabel = slotLabelOverride || String(firstOrder.scheduledSlot || "").trim() || "manual";
    const subject = `DHEgo Bestellungen - ${projectName} - ${slotLabel}`;
    const html = buildOrderHtml(
      projectName,
      slotLabel,
      scheduledAt,
      recipient.name || "Bauleitung",
      rows,
    );
    const attachmentName = `narudzbe-${projectName.replace(/\s+/g, "-").toLowerCase()}-${slotLabel.replace(":", "")}.csv`;

    const sendResult = await sendResendEmail({
      to: recipient.email,
      subject,
      html,
      attachments: [
        {
          filename: attachmentName,
          content: Buffer.from(csv, "utf8").toString("base64"),
        },
      ],
    });

    const batch = getFirestore().batch();
    for (const order of orders) {
      batch.set(order.ref, {
        status: "sent",
        sentAt: new Date(),
        resendEmailId: String(sendResult.id || ""),
        lastError: "",
      }, { merge: true });
    }
    await batch.commit();
    sentOrderCount += orders.length;
    sentProjectCount += 1;
  }

  return { sentOrderCount, sentProjectCount };
}

async function processOrderBatch(slotLabel) {
  const now = new Date();
  const snapshot = await getFirestore()
    .collection("order_requests")
    .where("scheduledSlot", "==", slotLabel)
    .get();

  const dueOrders = snapshot.docs
    .map((doc) => ({ id: doc.id, ref: doc.ref, ...doc.data() }))
    .filter((order) => {
      if (String(order.status || "pending") !== "pending") {
        return false;
      }
      const scheduledAt = order.scheduledAt && typeof order.scheduledAt.toDate === "function"
        ? order.scheduledAt.toDate()
        : null;
      return scheduledAt && scheduledAt <= now;
    });

  return deliverOrderBatch(dueOrders, slotLabel);

  if (dueOrders.length === 0) {
    logger.info(`No pending order requests for slot ${slotLabel}.`);
    return;
  }

  const ordersByProject = new Map();
  for (const order of dueOrders) {
    const projectId = String(order.projectId || "").trim();
    if (!projectId) {
      continue;
    }
    if (!ordersByProject.has(projectId)) {
      ordersByProject.set(projectId, []);
    }
    ordersByProject.get(projectId).push(order);
  }

  for (const [projectId, orders] of ordersByProject.entries()) {
    const firstOrder = orders[0];
    const projectName = String(firstOrder.projectName || projectId).trim();
    const recipient = await resolveProjectRecipient(projectId, firstOrder);
    if (!recipient.email) {
      logger.error(`Skipping order batch for project ${projectId}: missing recipient email.`);
      const batch = getFirestore().batch();
      for (const order of orders) {
        batch.set(order.ref, {
          lastAttemptAt: new Date(),
          lastError: "Missing project manager email.",
        }, { merge: true });
      }
      await batch.commit();
      continue;
    }

    const rows = buildOrderEmailRows(orders);
    const csv = buildOrderCsv(rows);
    const scheduledAt = firstOrder.scheduledAt.toDate();
    const subject = `DHEgo Bestellungen - ${projectName} - ${slotLabel}`;
    const html = buildOrderHtml(
      projectName,
      slotLabel,
      scheduledAt,
      recipient.name || "Bauleitung",
      rows,
    );
    const attachmentName = `narudzbe-${projectName.replace(/\s+/g, "-").toLowerCase()}-${slotLabel.replace(":", "")}.csv`;

    const sendResult = await sendResendEmail({
      to: recipient.email,
      subject,
      html,
      attachments: [
        {
          filename: attachmentName,
          content: Buffer.from(csv, "utf8").toString("base64"),
        },
      ],
    });

    const batch = getFirestore().batch();
    for (const order of orders) {
      batch.set(order.ref, {
        status: "sent",
        sentAt: new Date(),
        resendEmailId: String(sendResult.id || ""),
        lastError: "",
      }, { merge: true });
    }
    await batch.commit();
  }
}

exports.sendMiddayOrderBatch = onSchedule(
  {
    region: "europe-west1",
    schedule: "45 12 * * *",
    timeZone: "Europe/Zagreb",
    secrets: [RESEND_API_KEY],
  },
  async () => {
    await processOrderBatch("12:45");
  },
);

exports.sendAfternoonOrderBatch = onSchedule(
  {
    region: "europe-west1",
    schedule: "45 15 * * *",
    timeZone: "Europe/Zagreb",
    secrets: [RESEND_API_KEY],
  },
  async () => {
    await processOrderBatch("15:45");
  },
);

exports.dispatchPendingOrdersNowHttp = onRequest({ region: "europe-west1", cors: true, secrets: [RESEND_API_KEY] }, async (request, response) => {
  if (request.method === "OPTIONS") {
    response.status(204).send("");
    return;
  }

  if (request.method !== "POST") {
    response.status(405).json({ success: false, errorCode: "method-not-allowed", message: "Method not allowed." });
    return;
  }

  try {
    const manager = await requireActiveUserManagerFromHttp(request);
    const snapshot = await getFirestore()
      .collection("order_requests")
      .where("status", "==", "pending")
      .get();

    let dueOrders = snapshot.docs.map((doc) => ({ id: doc.id, ref: doc.ref, ...doc.data() }));
    if (isManagerLikeRole(manager.callerRole)) {
      const allowedProjectIds = new Set(manager.allowedProjectIds || []);
      dueOrders = dueOrders.filter((order) =>
        allowedProjectIds.has(String(order.projectId || "").trim()),
      );
    }

    const result = await deliverOrderBatch(dueOrders, "manual");
    response.status(200).json({
      success: true,
      sentOrderCount: String(result.sentOrderCount),
      sentProjectCount: String(result.sentProjectCount),
    });
  } catch (error) {
    logger.error("dispatchPendingOrdersNowHttp failed", {
      errorCode: error && typeof error === "object" ? error.code : undefined,
      errorMessage: error instanceof Error ? error.message : String(error),
    });
    response.status(error instanceof HttpsError && error.code === "unauthenticated" ? 401 : 400).json({
      success: false,
      errorCode: error instanceof HttpsError ? error.code : "internal",
      message: error instanceof HttpsError
        ? error.message
        : "Nije moguÄ‡e odmah poslati narudÅ¾be.",
    });
  }
});
