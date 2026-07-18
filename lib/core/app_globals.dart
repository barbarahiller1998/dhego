import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String rememberMePreferenceKey = 'remember_me';
const String savedUsernameKey = 'saved_username';
const String savedPasswordKey = 'saved_password';
const String savedUserProfileKey = 'saved_user_profile';
const String pendingRegisterSubmissionsKey = 'pending_register_submissions';
const String pendingApartmentDocumentSubmissionsKey =
    'pending_apartment_document_submissions';

const FlutterSecureStorage secureStorage = FlutterSecureStorage();
final Set<String> submittedRegisterKeys = <String>{};
final FirebaseFirestore firestore = FirebaseFirestore.instance;
final FirebaseAuth firebaseAuth = FirebaseAuth.instance;
final FirebaseStorage firebaseStorage = FirebaseStorage.instance;
final FirebaseFunctions firebaseFunctions = FirebaseFunctions.instanceFor(
  region: 'europe-west1',
);

String currentSessionUsername = '';
Timer? pendingRegisterSyncTimer;
bool pendingRegisterSyncInProgress = false;
bool pendingApartmentDocumentSyncInProgress = false;
final Set<String> registeredWebImageViewTypes = <String>{};
