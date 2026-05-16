const admin = require('firebase-admin');
const sa = require('./serviceAccount.json');
admin.initializeApp({ credential: admin.credential.cert(sa) });
const db = admin.firestore();

const JIMMY_UID = 'tUXTSQywZfPWVijrZvhnpugZCSd2';

(async () => {
  const groupsSnap = await db.collection('groups').get();
  let added = 0, skipped = 0;
  for (const doc of groupsSnap.docs) {
    const data = doc.data() || {};
    const members = Array.isArray(data.members) ? data.members : [];
    if (members.includes(JIMMY_UID)) {
      skipped++;
      continue;
    }
    await doc.ref.update({
      members: admin.firestore.FieldValue.arrayUnion(JIMMY_UID),
    });
    console.log('  + agregado a:', data.groupName || data.name || doc.id);
    added++;
  }
  console.log(`\nResumen: agregados=${added}, ya estaba=${skipped}, total grupos=${groupsSnap.size}`);
})().catch(e => { console.error(e); process.exit(1); });
