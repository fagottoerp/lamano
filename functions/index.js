const admin = require("firebase-admin");
const {logger, setGlobalOptions} = require("firebase-functions/v2");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");

admin.initializeApp();

setGlobalOptions({
  region: "us-central1",
  minInstances: 1,
  maxInstances: 10,
});

exports.sendPushOnNewMessage = onDocumentCreated(
  "messages/{groupChatId}/{subCollectionId}/{messageId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      return;
    }

    const message = snapshot.data();
    const groupChatId = event.params.groupChatId;
    const subCollectionId = event.params.subCollectionId;

    // The app stores nested messages at messages/{groupChatId}/{groupChatId}/{messageId}.
    if (groupChatId !== subCollectionId) {
      return;
    }

    const idFrom = message.idFrom;
    const idTo = message.idTo || "";
    const type = message.type;
    const content = message.content;
    const sentAtMs = Number(message.timestamp || Date.now());

    // Fetch sender's nickname for the notification title
    const senderDoc = await admin.firestore().collection("users").doc(idFrom).get();
    const senderName = senderDoc.exists ? (senderDoc.data().nickname || message.senderName || "La Mano") : (message.senderName || "La Mano");

    let body = "Nuevo mensaje";
    if (type === 0) {
      body = typeof content === "string" ? content : "Nuevo mensaje";
    } else if (type === 1) {
      body = "📷 Foto";
    } else if (type === 2) {
      body = "😄 Sticker";
    } else if (type === 3) {
      body = "📍 Ubicación";
    } else if (type === 5) {
      body = "🎤 Audio";
    } else if (type === 6) {
      body = "📹 Videollamada";
    } else if (type === 7) {
      body = "📞 Llamada";
    }

    // --- 1-on-1 chat push ---
    if (idTo && idTo !== "") {
      const receiverDoc = await admin.firestore().collection("users").doc(idTo).get();
      if (!receiverDoc.exists) {
        logger.warn("Recipient user doc not found", {idTo});
        return;
      }
      const pushToken = (receiverDoc.data() || {}).pushToken;
      if (!pushToken) {
        logger.info("Recipient has no pushToken", {idTo});
        return;
      }
      const payload = {
        token: pushToken,
        notification: { title: senderName, body },
        data: {
          idFrom: String(idFrom),
          idTo: String(idTo),
          groupChatId: String(groupChatId),
          senderName: String(senderName),
          sentAtMs: String(sentAtMs),
          dispatchedAtMs: String(Date.now()),
        },
        android: {
          priority: "high",
          ttl: 1000 * 60,
          notification: { channelId: "flutter_chat_urgent_v2", sound: "default", defaultSound: true, priority: "high" },
        },
      };
      try {
        const response = await admin.messaging().send(payload);
        logger.info("Push sent (1-on-1)", {idTo, response});
      } catch (error) {
        logger.error("Error sending push (1-on-1)", error);
      }
      return;
    }

    // --- Group chat push: fan-out to all members except sender ---
    const groupDoc = await admin.firestore().collection("groups").doc(groupChatId).get();
    if (!groupDoc.exists) {
      logger.warn("Group doc not found", {groupChatId});
      return;
    }
    const groupData = groupDoc.data() || {};
    const groupName = groupData.groupName || groupData.name || "Grupo";
    const members = groupData.members || [];
    const otherMembers = members.filter((uid) => uid !== idFrom);

    if (otherMembers.length === 0) return;

    // Fetch tokens of all members in parallel
    const userDocs = await Promise.all(
      otherMembers.map((uid) => admin.firestore().collection("users").doc(uid).get())
    );

    const messages = [];
    for (const userDoc of userDocs) {
      if (!userDoc.exists) continue;
      const token = (userDoc.data() || {}).pushToken;
      if (!token) continue;
      messages.push({
        token,
        notification: { title: senderName, body: `${groupName}\n${body}` },
        data: {
          idFrom: String(idFrom),
          idTo: "",
          groupChatId: String(groupChatId),
          senderName: String(senderName),
          groupName: String(groupName),
          isGroup: "1",
          sentAtMs: String(sentAtMs),
          dispatchedAtMs: String(Date.now()),
        },
        android: {
          priority: "high",
          ttl: 1000 * 60,
          notification: { channelId: "flutter_chat_urgent_v2", sound: "default", defaultSound: true, priority: "high" },
        },
      });
    }

    if (messages.length === 0) return;

    try {
      const result = await admin.messaging().sendEach(messages);
      logger.info("Group push sent", {groupChatId, successCount: result.successCount, failureCount: result.failureCount});
    } catch (error) {
      logger.error("Error sending group push", error);
    }
  },
);

// ── Panic alert: push to all admin users ──────────────────────────────────
exports.sendPanicAlertPush = onDocumentCreated(
  "panic_alerts/{alertId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const alert = snapshot.data();
    const type = alert.type || "ALERTA";
    const userName = alert.userName || "Usuario";
    const lat = alert.lat;
    const lng = alert.lng;
    const userId = alert.userId || "";

    const isPolice = type === "ALERTA_POLICIAL";
    const emoji = isPolice ? "🚨" : "🔴";
    const title = isPolice ? `${emoji} ALERTA POLICIAL` : `${emoji} ALERTA ROBO`;
    const body = lat != null
      ? `${userName} · Lat: ${Number(lat).toFixed(5)}, Lng: ${Number(lng).toFixed(5)}`
      : `${userName} · Ubicación no disponible`;

    // Fetch all admin users (rolId == "1" or aboutMe contains "admin")
    const usersSnap = await admin.firestore()
      .collection("users")
      .where("rolId", "==", "1")
      .get();

    const messages = [];
    for (const userDoc of usersSnap.docs) {
      if (userDoc.id === userId) continue; // don't push to sender
      const token = (userDoc.data() || {}).pushToken;
      if (!token) continue;
      messages.push({
        token,
        notification: { title, body },
        data: {
          type,
          userId: String(userId),
          lat: lat != null ? String(lat) : "",
          lng: lng != null ? String(lng) : "",
          alertId: event.params.alertId,
        },
        android: {
          priority: "high",
          notification: {
            channelId: "panic_alert_v1",
            sound: "default",
            priority: "max",
            defaultSound: true,
          },
        },
      });
    }

    if (messages.length === 0) {
      logger.info("No admin tokens to send panic alert to");
      return;
    }

    try {
      const result = await admin.messaging().sendEach(messages);
      logger.info("Panic alert push sent", {
        type,
        successCount: result.successCount,
        failureCount: result.failureCount,
      });
    } catch (error) {
      logger.error("Error sending panic alert push", error);
    }
  },
);
