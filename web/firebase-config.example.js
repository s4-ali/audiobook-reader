// Optional cloud sync (Firebase) — DISABLED unless you create web/firebase-config.js.
//
// To turn on cross-device sync of reading progress + notes:
//   1. Create a Firebase project (https://console.firebase.google.com) and, in it,
//      enable "Firestore Database" and the "Email/Password" sign-in provider.
//   2. In Project settings → "Your apps", add a Web app and copy its config values.
//   3. Copy this file to  web/firebase-config.js  and paste your values below.
//      (These values are PUBLIC client config, not secrets — Firestore security rules,
//       not the config, are what protect your data. See README "Optional cloud sync".)
//
// If web/firebase-config.js is absent or exports null, the app stays fully local — exactly
// as it behaves today (progress in localStorage, notes over the local server only).
//
// Firestore security rules to paste in the console (per-user isolation):
//   rules_version = '2';
//   service cloud.firestore {
//     match /databases/{database}/documents {
//       match /users/{uid}/{document=**} {
//         allow read, write: if request.auth != null && request.auth.uid == uid;
//       }
//     }
//   }

export default {
  apiKey: "YOUR_API_KEY",
  authDomain: "YOUR_PROJECT.firebaseapp.com",
  projectId: "YOUR_PROJECT_ID",
  appId: "YOUR_APP_ID",
  // storageBucket / messagingSenderId are optional for auth + Firestore.
};
