import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'core/app_globals.dart';
import 'core/excel_file_share.dart';
import 'core/localization.dart';
import 'core/web_storage_photo_view.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await loadSavedLanguage();
  await initializeSharedPdfHandling();
  syncPendingRegisters();
  syncPendingApartmentDocuments();
  runApp(const DHEgoApp());
}

final ValueNotifier<List<SharedPdfPayload>> pendingSharedPdfNotifier =
    ValueNotifier<List<SharedPdfPayload>>(<SharedPdfPayload>[]);
StreamSubscription<List<SharedMediaFile>>? sharedPdfSubscription;

class SharedPdfPayload {
  const SharedPdfPayload({required this.path, required this.fileName});

  final String path;
  final String fileName;
}

Future<void> initializeSharedPdfHandling() async {
  if (kIsWeb) {
    return;
  }

  try {
    final initialMedia = await ReceiveSharingIntent.instance.getInitialMedia();
    mergePendingSharedPdfs(initialMedia);
    sharedPdfSubscription?.cancel();
    sharedPdfSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(mergePendingSharedPdfs);
  } catch (_) {}
}

void mergePendingSharedPdfs(List<SharedMediaFile> sharedFiles) {
  final incoming = sharedFiles
      .map(
        (file) => SharedPdfPayload(
          path: file.path,
          fileName: sharedFileNameFromPath(file.path),
        ),
      )
      .where((file) => file.path.toLowerCase().endsWith('.pdf'))
      .toList();

  if (incoming.isEmpty) {
    return;
  }

  final merged = <String, SharedPdfPayload>{
    for (final file in pendingSharedPdfNotifier.value) file.path: file,
    for (final file in incoming) file.path: file,
  };
  pendingSharedPdfNotifier.value = merged.values.toList();
}

void removePendingSharedPdfs(Iterable<SharedPdfPayload> files) {
  final removedPaths = files.map((file) => file.path).toSet();
  pendingSharedPdfNotifier.value = pendingSharedPdfNotifier.value
      .where((file) => !removedPaths.contains(file.path))
      .toList();
}

String sharedFileNameFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/');
  return segments.isEmpty ? path : segments.last;
}

class DHEgoApp extends StatelessWidget {
  const DHEgoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: languageNotifier,
      builder: (context, language, child) {
        return LanguageScope(
          notifier: languageNotifier,
          child: MaterialApp(
            title: 'DHEgo',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF0F766E),
              ),
              useMaterial3: true,
            ),
            home: const LoginScreen(),
          ),
        );
      },
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final LocalAuthentication localAuthentication = LocalAuthentication();
  bool rememberMe = false;
  bool hasSavedCredentials = false;
  bool deviceCanUseLocalAuth = false;

  @override
  void initState() {
    super.initState();
    loadRememberedState();
  }

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> loadRememberedState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRememberMe = prefs.getBool(rememberMePreferenceKey) ?? false;
    final savedUsername = await secureStorage.read(key: savedUsernameKey);
    final savedPassword = await secureStorage.read(key: savedPasswordKey);

    var canUseLocalAuth = false;
    try {
      canUseLocalAuth =
          await localAuthentication.canCheckBiometrics ||
          await localAuthentication.isDeviceSupported();
    } catch (_) {
      canUseLocalAuth = false;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      rememberMe = savedRememberMe;
      hasSavedCredentials =
          (savedUsername?.isNotEmpty ?? false) &&
          (savedPassword?.isNotEmpty ?? false);
      deviceCanUseLocalAuth = canUseLocalAuth;
      if (rememberMe && !deviceCanUseLocalAuth && savedUsername != null) {
        usernameController.text = savedUsername;
      }
    });
  }

  Future<void> persistRememberedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(rememberMePreferenceKey, rememberMe);

    if (rememberMe) {
      await secureStorage.write(
        key: savedUsernameKey,
        value: usernameController.text.trim(),
      );
      await secureStorage.write(
        key: savedPasswordKey,
        value: passwordController.text,
      );
      return;
    }

    await secureStorage.delete(key: savedUsernameKey);
    await secureStorage.delete(key: savedPasswordKey);
    await prefs.remove(savedUserProfileKey);
  }

  Future<void> persistRememberedUserProfile(AuthLoginData authLogin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      savedUserProfileKey,
      jsonEncode(<String, dynamic>{
        'username': authLogin.user.username,
        'fullName': authLogin.user.fullName,
        'email': authLogin.email,
        'role': authLogin.user.role,
        'active': authLogin.user.active,
        'allowedProjectIds': authLogin.user.allowedProjectIds,
        'allowedTaskGroupsByProject': authLogin.user.allowedTaskGroupsByProject,
      }),
    );
  }

  AuthLoginData? readSavedUserProfile(SharedPreferences prefs) {
    final raw = prefs.getString(savedUserProfileKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }

      final data = decoded.map((key, value) => MapEntry(key.toString(), value));
      final username = data['username']?.toString() ?? '';
      final fullName = data['fullName']?.toString() ?? username;
      final email = data['email']?.toString() ?? '';
      if (username.isEmpty || email.isEmpty) {
        return null;
      }

      return AuthLoginData(
        email: email,
        user: UserRecord(
          id: username,
          username: username,
          fullName: fullName,
          email: email,
          role: data['role']?.toString() ?? 'worker',
          active: data['active'] as bool? ?? true,
          allowedProjectIds:
              (data['allowedProjectIds'] as List<dynamic>? ?? <dynamic>[])
                  .map((item) => item.toString())
                  .toList(),
          allowedTaskGroupsByProject: parseAllowedTaskGroupsByProject(
            data['allowedTaskGroupsByProject'],
          ),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  void openHome(AuthLoginData authLogin) {
    currentSessionUsername = authLogin.user.username;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => HomeSelectionScreen(
          user: DemoUser(
            username: authLogin.user.username,
            password: '',
            role: authLogin.user.role,
            allowedProjects: authLogin.user.allowedProjectIds,
            allowedTaskGroupsByProject:
                authLogin.user.allowedTaskGroupsByProject,
          ),
        ),
      ),
    );
  }

  String loginErrorMessage(FirebaseAuthException error) {
    switch (error.code) {
      case 'network-request-failed':
        return tr(context, 'login_error_network');
      case 'web-storage-unsupported':
        return tr(context, 'login_error_storage');
      case 'unauthorized-domain':
        return tr(context, 'login_error_domain');
      case 'operation-not-allowed':
        return tr(context, 'login_error_disabled');
      case 'too-many-requests':
        return tr(context, 'login_error_rate_limit');
      default:
        return '${tr(context, 'login_error')} [${error.code}]';
    }
  }

  Future<void> login() async {
    final username = usernameController.text.trim();
    final normalizedUsername = username.toLowerCase();
    final password = passwordController.text;
    final prefs = await SharedPreferences.getInstance();

    try {
      AuthLoginData? authLogin;

      if (normalizedUsername.contains('@')) {
        await firebaseAuth.signInWithEmailAndPassword(
          email: normalizedUsername,
          password: password,
        );
        authLogin = await fetchAuthLoginData(normalizedUsername);
      } else {
        authLogin = await fetchAuthLoginData(normalizedUsername);
        if (authLogin == null) {
          throw FirebaseAuthException(code: 'user-not-found');
        }

        await firebaseAuth.signInWithEmailAndPassword(
          email: authLogin.email.trim().toLowerCase(),
          password: password,
        );
      }

      if (authLogin == null) {
        throw FirebaseAuthException(code: 'user-not-found');
      }

      if (!authLogin.user.active) {
        await firebaseAuth.signOut();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'inactive_user_error'))),
          );
        }
        return;
      }

      await persistRememberedCredentials();
      await persistRememberedUserProfile(authLogin);

      if (!mounted) {
        return;
      }

      openHome(authLogin);
      return;
    } on FirebaseAuthException catch (error) {
      final savedUsername = await secureStorage.read(key: savedUsernameKey);
      final savedPassword = await secureStorage.read(key: savedPasswordKey);
      final savedProfile = readSavedUserProfile(prefs);

      final normalizedInput = username.trim().toLowerCase();
      final savedUsernameNormalized = savedUsername?.trim().toLowerCase();
      final savedProfileUsername = savedProfile?.user.username
          .trim()
          .toLowerCase();
      final savedProfileEmail = savedProfile?.email.trim().toLowerCase();

      final offlineCanLogin =
          rememberMe &&
          savedProfile != null &&
          savedPassword == password &&
          (normalizedInput == savedUsernameNormalized ||
              normalizedInput == savedProfileUsername ||
              normalizedInput == savedProfileEmail);

      if (offlineCanLogin) {
        if (!mounted) {
          return;
        }
        currentSessionUsername = savedProfile.user.username;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'offline_login_success'))),
        );
        openHome(savedProfile);
        return;
      }

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(loginErrorMessage(error))));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(context, 'login_error'))));
    }
  }

  Future<void> sendPasswordReset() async {
    final identifier = usernameController.text.trim();
    final normalizedIdentifier = identifier.toLowerCase();

    try {
      final authLogin = await fetchAuthLoginData(normalizedIdentifier);
      final email = normalizedIdentifier.contains('@')
          ? normalizedIdentifier
          : authLogin?.email;

      if (email == null || email.isEmpty) {
        throw FirebaseAuthException(code: 'user-not-found');
      }

      await firebaseAuth.sendPasswordResetEmail(email: email);

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'password_reset_sent'))),
      );
    } on FirebaseAuthException {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'password_reset_error'))),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'password_reset_error'))),
      );
    }
  }

  Future<void> unlockSavedLogin() async {
    try {
      final authenticated = await localAuthentication.authenticate(
        localizedReason: tr(context, 'biometric_reason'),
        biometricOnly: false,
      );

      if (!authenticated) {
        return;
      }

      final savedUsername = await secureStorage.read(key: savedUsernameKey);
      final savedPassword = await secureStorage.read(key: savedPasswordKey);

      if (!mounted) {
        return;
      }

      if (savedUsername == null || savedPassword == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr(context, 'biometric_error'))));
        return;
      }

      setState(() {
        usernameController.text = savedUsername;
        passwordController.text = savedPassword;
      });

      await login();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(context, 'biometric_error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = LanguageScope.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'app_title')), centerTitle: true),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Image.asset(
                            'assets/images/logo.jpg',
                            height: 120,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        tr(context, 'login_title'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        tr(context, 'language_label'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: LanguageButton(
                              flag: '🇭🇷',
                              label: 'HR',
                              selected: language == AppLanguage.hr,
                              onTap: () => setAppLanguage(AppLanguage.hr),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LanguageButton(
                              flag: '🇩🇪',
                              label: 'DE',
                              selected: language == AppLanguage.de,
                              onTap: () => setAppLanguage(AppLanguage.de),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LanguageButton(
                              flag: '🇬🇧',
                              label: 'EN',
                              selected: language == AppLanguage.en,
                              onTap: () => setAppLanguage(AppLanguage.en),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: usernameController,
                        decoration: InputDecoration(
                          labelText: tr(context, 'username_or_email'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: passwordController,
                        obscureText: true,
                        onSubmitted: (_) => login(),
                        decoration: InputDecoration(
                          labelText: tr(context, 'password'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: sendPasswordReset,
                          child: Text(tr(context, 'forgot_password')),
                        ),
                      ),
                      CheckboxListTile(
                        value: rememberMe,
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'remember_me')),
                        onChanged: (value) {
                          setState(() {
                            rememberMe = value ?? false;
                          });
                        },
                      ),
                      if (hasSavedCredentials && deviceCanUseLocalAuth) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: unlockSavedLogin,
                          icon: const Icon(Icons.lock_open_outlined),
                          label: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(tr(context, 'unlock_saved_login')),
                              Text(
                                tr(context, 'unlock_saved_login_subtitle'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: login,
                          child: Text(tr(context, 'login_button')),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class LanguageButton extends StatelessWidget {
  const LanguageButton({
    super.key,
    required this.flag,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String flag;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? const Color(0xFFDCFCE7)
            : Colors.transparent,
        side: BorderSide(
          color: selected ? const Color(0xFF0F766E) : Colors.grey.shade400,
          width: 1.5,
        ),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(flag, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class HomeSelectionScreen extends StatelessWidget {
  const HomeSelectionScreen({super.key, required this.user});

  final DemoUser user;

  @override
  Widget build(BuildContext context) {
    ensurePendingRegisterSyncStarted();
    syncPendingRegisters();
    syncPendingApartmentDocuments();
    return StreamBuilder<UserRecord?>(
      stream: watchUserByUsername(user.username),
      builder: (context, snapshot) {
        final currentUser = resolveDemoUser(user, snapshot.data);
        final canOpenAdminPanel =
            currentUser.role == 'admin' || isManagerLikeRole(currentUser.role);

        return Scaffold(
          appBar: AppBar(
            title: Text('${tr(context, 'welcome')}, ${currentUser.username}'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ValueListenableBuilder<List<SharedPdfPayload>>(
              valueListenable: pendingSharedPdfNotifier,
              builder: (context, pendingSharedPdfs, child) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (pendingSharedPdfs.isNotEmpty) ...[
                      Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16),
                          leading: CircleAvatar(
                            child: Text('${pendingSharedPdfs.length}'),
                          ),
                          title: Text(
                            tr(context, 'shared_pdf_ready_title'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${pendingSharedPdfs.length} PDF\n${tr(context, 'shared_pdf_ready_message')}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => showSharedPdfAssignmentDialog(
                            context,
                            user: currentUser,
                            pendingFiles: pendingSharedPdfs,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (canOpenAdminPanel) ...[
                      Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16),
                          leading: CircleAvatar(
                            child: Icon(
                              kIsWeb
                                  ? Icons.language
                                  : Icons.admin_panel_settings_outlined,
                            ),
                          ),
                          title: Text(
                            tr(context, 'admin_panel'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(tr(context, 'admin_panel_subtitle')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (context) =>
                                    AdminDashboardScreen(user: currentUser),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: const CircleAvatar(
                          child: Icon(Icons.apartment_outlined),
                        ),
                        title: Text(
                          tr(context, 'project_selection'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          tr(context, 'project_selection_subtitle'),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) =>
                                  ProjectListScreen(user: currentUser),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: const CircleAvatar(
                          child: Icon(Icons.shopping_cart_outlined),
                        ),
                        title: Text(
                          tr(context, 'order_goods'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(tr(context, 'order_goods_subtitle')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) =>
                                  OrderProjectScreen(user: currentUser),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class OrderProjectScreen extends StatelessWidget {
  const OrderProjectScreen({super.key, required this.user});

  final DemoUser user;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserRecord?>(
      stream: watchUserByUsername(user.username),
      builder: (context, userSnapshot) {
        final currentUser = resolveDemoUser(user, userSnapshot.data);
        return Scaffold(
          appBar: AppBar(title: Text(tr(context, 'order_title'))),
          body: StreamBuilder<List<ProjectRecord>>(
            stream: currentUser.role == 'admin'
                ? watchAllProjects()
                : watchProjects(currentUser.allowedProjects),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Center(child: Text(tr(context, 'loading')));
              }

              final projects = snapshot.data ?? <ProjectRecord>[];
              if (projects.isEmpty) {
                return Center(child: Text(tr(context, 'no_data')));
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: projects.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final project = projects[index];
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      title: Text(
                        project.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(tr(context, 'choose_project_for_order')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => OrderItemsScreen(
                              user: currentUser,
                              project: project,
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key, required this.user});

  final DemoUser user;

  @override
  Widget build(BuildContext context) {
    final isAdmin = user.role == 'admin';
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'admin_panel'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AdminProjectsSectionV2(user: user),
          const SizedBox(height: 16),
          AdminBuildingsSection(user: user),
          const SizedBox(height: 16),
          AdminUsersSectionV2(user: user),
          const SizedBox(height: 16),
          AdminOrdersSection(user: user),
          const SizedBox(height: 16),
          AdminRegisterExportsSection(user: user),
        ],
      ),
    );
  }
}

class AdminProjectsSection extends StatelessWidget {
  const AdminProjectsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminSectionCard(
      title: tr(context, 'projects_tab'),
      addLabel: tr(context, 'add_project'),
      onAdd: () => showProjectDialog(context),
      child: StreamBuilder<List<ProjectRecord>>(
        stream: watchAllProjects(),
        builder: (context, snapshot) {
          final projects = snapshot.data ?? <ProjectRecord>[];
          return Column(
            children: projects
                .map(
                  (project) => ListTile(
                    title: Text(project.name),
                    subtitle: Text(
                      '${tr(context, 'manager')}: ${project.managerName}'
                      '${project.active ? '' : ' • ${tr(context, 'inactive')}'}',
                    ),
                    trailing: IconButton(
                      onPressed: () =>
                          showProjectDialog(context, existingProject: project),
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: tr(context, 'edit'),
                    ),
                  ),
                )
                .toList(),
          );
        },
      ),
    );
  }
}

class AdminBuildingsSection extends StatefulWidget {
  const AdminBuildingsSection({super.key, required this.user});

  final DemoUser user;

  @override
  State<AdminBuildingsSection> createState() => _AdminBuildingsSectionState();
}

class _AdminBuildingsSectionState extends State<AdminBuildingsSection> {
  final TextEditingController searchController = TextEditingController();
  String query = '';
  AdminSortOption selectedSort = AdminSortOption.nameAsc;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.user.role == 'admin';
    return AdminSectionCard(
      title: tr(context, 'buildings_tab'),
      addLabel: tr(context, 'add_building'),
      onAdd: () => showBuildingDialog(
        context,
        allowedProjectIds: isAdmin ? null : widget.user.allowedProjects,
      ),
      onImport: (isAdmin || isManagerLikeRole(widget.user.role))
          ? () => showStructureImportDialog(context, widget.user)
          : null,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: searchController,
                  decoration: InputDecoration(
                    labelText: tr(context, 'search'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) =>
                      setState(() => query = value.trim().toLowerCase()),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<AdminSortOption>(
                  initialValue: selectedSort,
                  decoration: InputDecoration(
                    labelText: tr(context, 'sort_by'),
                    border: const OutlineInputBorder(),
                  ),
                  items: AdminSortOption.values
                      .map(
                        (option) => DropdownMenuItem<AdminSortOption>(
                          value: option,
                          child: Text(adminSortOptionLabel(context, option)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() => selectedSort = value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          StreamBuilder<List<ProjectRecord>>(
            stream: watchAllProjects(),
            builder: (context, projectSnapshot) {
              final projects = projectSnapshot.data ?? <ProjectRecord>[];
              final visibleProjects = projects
                  .where(
                    (project) =>
                        isAdmin ||
                        widget.user.allowedProjects.contains(project.id),
                  )
                  .toList();
              return StreamBuilder<List<WohnungRecord>>(
                stream: watchAllWohnungs(),
                builder: (context, wohnungSnapshot) {
                  final wohnungs = wohnungSnapshot.data ?? <WohnungRecord>[];
                  return StreamBuilder<List<BuildingRecord>>(
                    stream: watchAllBuildings(),
                    builder: (context, snapshot) {
                      final buildings = (snapshot.data ?? <BuildingRecord>[])
                          .where(
                            (building) =>
                                isAdmin ||
                                widget.user.allowedProjects.contains(
                                  building.projectId,
                                ),
                          )
                          .where((building) {
                            String? projectName;
                            String? managerName;
                            for (final project in visibleProjects) {
                              if (project.id == building.projectId) {
                                projectName = project.name;
                                managerName = project.managerName;
                                break;
                              }
                            }
                            final searchText = [
                              building.name,
                              projectName ?? '',
                              managerName ?? '',
                            ].join(' ').toLowerCase();
                            return query.isEmpty || searchText.contains(query);
                          })
                          .toList();
                      sortBuildingRecords(buildings, selectedSort);
                      return Column(
                        children: buildings.map((building) {
                          String? projectName;
                          String? managerName;
                          for (final project in visibleProjects) {
                            if (project.id == building.projectId) {
                              projectName = project.name;
                              managerName = project.managerName;
                              break;
                            }
                          }
                          final buildingWohnungs =
                              wohnungs
                                  .where(
                                    (wohnung) =>
                                        wohnung.buildingId == building.id,
                                  )
                                  .toList()
                                ..sort(
                                  (a, b) => compareWohnungNames(a.name, b.name),
                                );

                          return ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: const EdgeInsets.only(bottom: 8),
                            title: Text(building.name),
                            subtitle: Text(
                              '${tr(context, 'project_label')}: ${projectName ?? building.projectId}'
                              '\n${tr(context, 'manager')}: ${managerName?.isEmpty ?? true ? '-' : managerName}'
                              '\n${formatTaskProgressSummary(context, totalPoints: building.workTaskTotalPoints, completedPoints: building.workTaskCompletedPoints, progressPercent: building.workTaskProgressPercent)}'
                              '\nWohnungs: ${buildingWohnungs.length}'
                              '${building.active ? '' : '\n${tr(context, 'inactive')}'}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () => showWohnungDialog(
                                    context,
                                    preselectedBuildingId: building.id,
                                    allowedProjectIds: isAdmin
                                        ? null
                                        : widget.user.allowedProjects,
                                  ),
                                  icon: const Icon(Icons.add_home_outlined),
                                  tooltip: tr(context, 'add_wohnung'),
                                ),
                                if (isAdmin)
                                  IconButton(
                                    onPressed: () async {
                                      await firestore
                                          .collection('buildings')
                                          .doc(building.id)
                                          .set({
                                            'active': !building.active,
                                            'updatedAt': Timestamp.now(),
                                          }, SetOptions(merge: true));
                                    },
                                    icon: Icon(
                                      building.active
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                    ),
                                    tooltip: tr(
                                      context,
                                      building.active
                                          ? 'deactivate'
                                          : 'activate',
                                    ),
                                  ),
                                if (isAdmin)
                                  IconButton(
                                    onPressed: () => showBuildingDialog(
                                      context,
                                      existingBuilding: building,
                                      allowedProjectIds: null,
                                    ),
                                    icon: const Icon(Icons.edit_outlined),
                                    tooltip: tr(context, 'edit'),
                                  ),
                              ],
                            ),
                            children: [
                              if (buildingWohnungs.isEmpty)
                                ListTile(
                                  title: Text(tr(context, 'no_data')),
                                  trailing: FilledButton.icon(
                                    onPressed: () => showWohnungDialog(
                                      context,
                                      preselectedBuildingId: building.id,
                                      allowedProjectIds: isAdmin
                                          ? null
                                          : widget.user.allowedProjects,
                                    ),
                                    icon: const Icon(Icons.add),
                                    label: Text(tr(context, 'add_wohnung')),
                                  ),
                                )
                              else
                                ...buildingWohnungs.map(
                                  (wohnung) => ListTile(
                                    contentPadding: const EdgeInsets.only(
                                      left: 16,
                                      right: 8,
                                    ),
                                    leading: const Icon(
                                      Icons.meeting_room_outlined,
                                    ),
                                    title: Text(wohnung.name),
                                    subtitle: Text(
                                      wohnung.active
                                          ? 'WE'
                                          : tr(context, 'inactive'),
                                    ),
                                    trailing: isAdmin
                                        ? IconButton(
                                            onPressed: () => showWohnungDialog(
                                              context,
                                              existingWohnung: wohnung,
                                              allowedProjectIds: null,
                                            ),
                                            icon: const Icon(
                                              Icons.edit_outlined,
                                            ),
                                            tooltip: tr(context, 'edit'),
                                          )
                                        : null,
                                  ),
                                ),
                            ],
                          );
                        }).toList(),
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class AdminMaterialsSection extends StatelessWidget {
  const AdminMaterialsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminSectionCard(
      title: tr(context, 'materials_tab'),
      child: StreamBuilder<List<MaterialRecord>>(
        stream: watchAllMaterials(),
        builder: (context, snapshot) {
          final materials = snapshot.data ?? <MaterialRecord>[];
          return Column(
            children: materials
                .map(
                  (material) => ListTile(
                    title: Text(material.name),
                    subtitle: Text(
                      [
                        if (material.sheetName.trim().isNotEmpty)
                          material.sheetName.trim(),
                        material.supplierLabel,
                        material.active
                            ? tr(context, 'active_label')
                            : tr(context, 'inactive'),
                      ].join(' • '),
                    ),
                    trailing: IconButton(
                      onPressed: () => showMaterialDialog(
                        context,
                        existingMaterial: material,
                      ),
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: tr(context, 'edit'),
                    ),
                  ),
                )
                .toList(),
          );
        },
      ),
    );
  }
}

class AdminUsersSection extends StatelessWidget {
  const AdminUsersSection({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminSectionCard(
      title: tr(context, 'users_tab'),
      addLabel: tr(context, 'add_user'),
      onAdd: () => showUserDialog(context),
      child: StreamBuilder<List<UserRecord>>(
        stream: watchUsers(),
        builder: (context, snapshot) {
          final users = snapshot.data ?? <UserRecord>[];
          return Column(
            children: users
                .map(
                  (user) => ListTile(
                    title: Text(user.username),
                    subtitle: Text(
                      '${tr(context, 'role_label')}: ${formatUserRoleLabel(user.role)}'
                      '${user.active ? '' : ' • ${tr(context, 'inactive')}'}',
                    ),
                    trailing: IconButton(
                      onPressed: () =>
                          showUserDialog(context, existingUser: user),
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: tr(context, 'edit'),
                    ),
                  ),
                )
                .toList(),
          );
        },
      ),
    );
  }
}

class AdminSectionCard extends StatelessWidget {
  const AdminSectionCard({
    super.key,
    required this.title,
    this.addLabel,
    this.onAdd,
    required this.child,
    this.onImport,
  });

  final String title;
  final String? addLabel;
  final VoidCallback? onAdd;
  final Widget child;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.width < 430;
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (onImport != null)
          OutlinedButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.file_upload_outlined),
            style: isCompact
                ? OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    textStyle: const TextStyle(fontSize: 13),
                  )
                : null,
            label: Text(tr(context, 'import'), overflow: TextOverflow.ellipsis),
          ),
        if (onAdd != null && addLabel != null)
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            style: isCompact
                ? FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    textStyle: const TextStyle(fontSize: 13),
                  )
                : null,
            label: Text(addLabel!, overflow: TextOverflow.ellipsis),
          ),
      ],
    );

    return Card(
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        title: isCompact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (onImport != null || (onAdd != null && addLabel != null))
                    const SizedBox(height: 10),
                  if (onImport != null || (onAdd != null && addLabel != null))
                    actions,
                ],
              )
            : Text(title, style: Theme.of(context).textTheme.titleLarge),
        trailing: isCompact ? null : actions,
        minTileHeight: isCompact ? 88 : null,
        children: [child],
      ),
    );
  }
}

class AdminProjectsSectionV2 extends StatefulWidget {
  const AdminProjectsSectionV2({super.key, required this.user});

  final DemoUser user;

  @override
  State<AdminProjectsSectionV2> createState() => _AdminProjectsSectionV2State();
}

class _AdminProjectsSectionV2State extends State<AdminProjectsSectionV2> {
  final TextEditingController searchController = TextEditingController();
  String query = '';
  AdminSortOption selectedSort = AdminSortOption.nameAsc;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.user.role == 'admin';
    return AdminSectionCard(
      title: tr(context, 'projects_tab'),
      addLabel: isAdmin ? tr(context, 'add_project') : null,
      onAdd: isAdmin ? () => showProjectDialog(context) : null,
      onImport: (isAdmin || isManagerLikeRole(widget.user.role))
          ? () => showStructureImportDialog(context, widget.user)
          : null,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: searchController,
                  decoration: InputDecoration(
                    labelText: tr(context, 'search'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) =>
                      setState(() => query = value.trim().toLowerCase()),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<AdminSortOption>(
                  initialValue: selectedSort,
                  decoration: InputDecoration(
                    labelText: tr(context, 'sort_by'),
                    border: const OutlineInputBorder(),
                  ),
                  items: AdminSortOption.values
                      .map(
                        (option) => DropdownMenuItem<AdminSortOption>(
                          value: option,
                          child: Text(adminSortOptionLabel(context, option)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() => selectedSort = value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          StreamBuilder<List<UserRecord>>(
            stream: watchUsers(),
            builder: (context, userSnapshot) {
              final users = userSnapshot.data ?? <UserRecord>[];
              return StreamBuilder<List<ProjectRecord>>(
                stream: watchAllProjects(),
                builder: (context, projectSnapshot) {
                  final projects = (projectSnapshot.data ?? <ProjectRecord>[])
                      .where(
                        (project) =>
                            isAdmin ||
                            widget.user.allowedProjects.contains(project.id),
                      )
                      .where(
                        (project) =>
                            query.isEmpty ||
                            project.name.toLowerCase().contains(query) ||
                            project.managerName.toLowerCase().contains(query),
                      )
                      .toList();
                  sortProjectRecords(projects, selectedSort);
                  return Column(
                    children: projects.map((project) {
                      final assignedWorkers =
                          users
                              .where(
                                (user) =>
                                    user.role == 'worker' &&
                                    user.allowedProjectIds.contains(project.id),
                              )
                              .map((user) => user.username)
                              .toList()
                            ..sort();
                      final subtitleLines = <String>[
                        '${tr(context, 'manager')}: ${project.managerName.isEmpty ? '-' : project.managerName}',
                        formatTaskProgressSummary(
                          context,
                          totalPoints: project.workTaskTotalPoints,
                          completedPoints: project.workTaskCompletedPoints,
                          progressPercent: project.workTaskProgressPercent,
                        ),
                        '${tr(context, 'assigned_workers_count')}: ${assignedWorkers.length}',
                        if (!project.active) tr(context, 'inactive'),
                      ];
                      final useVerticalProjectActions =
                          MediaQuery.of(context).size.width < 720;
                      final projectActionButtons = <Widget>[
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => showProjectUserAssignmentsDialog(
                            context,
                            project: project,
                          ),
                          icon: const Icon(Icons.person_add_alt_1_outlined),
                          tooltip: tr(context, 'assign_users_to_project'),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => showBuildingDialog(
                            context,
                            preselectedProjectId: project.id,
                            allowedProjectIds: isAdmin
                                ? null
                                : widget.user.allowedProjects,
                          ),
                          icon: const Icon(Icons.add_business_outlined),
                          tooltip: tr(context, 'add_building'),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => showProjectMaterialImportDialog(
                            context,
                            currentUser: widget.user,
                            project: project,
                          ),
                          icon: const Icon(Icons.playlist_add_outlined),
                          tooltip: tr(
                            context,
                            'import_project_materials_tooltip',
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            await downloadProjectWorkbookExportExcel(
                              project,
                              LanguageScope.of(context),
                            );
                          },
                          icon: const Icon(Icons.table_view_outlined),
                          tooltip: tr(context, 'export_project_status_tooltip'),
                        ),
                        if (isAdmin)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () async {
                              await firestore
                                  .collection('projects')
                                  .doc(project.id)
                                  .set({
                                    'active': !project.active,
                                    'updatedAt': Timestamp.now(),
                                  }, SetOptions(merge: true));
                            },
                            icon: Icon(
                              project.active
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                            tooltip: tr(
                              context,
                              project.active ? 'deactivate' : 'activate',
                            ),
                          ),
                        if (isAdmin)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () => showProjectDialog(
                              context,
                              existingProject: project,
                            ),
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: tr(context, 'edit'),
                          ),
                      ];

                      if (useVerticalProjectActions) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                project.name,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              Text(subtitleLines.join('\n')),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: projectActionButtons
                                    .map(
                                      (button) => DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: button,
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListTile(
                        title: Text(project.name),
                        subtitle: Text(subtitleLines.join('\n')),
                        isThreeLine: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: projectActionButtons,
                        ),
                      );
                    }).toList(),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class AdminUsersSectionV2 extends StatefulWidget {
  const AdminUsersSectionV2({super.key, required this.user});

  final DemoUser user;

  @override
  State<AdminUsersSectionV2> createState() => _AdminUsersSectionV2State();
}

class _AdminUsersSectionV2State extends State<AdminUsersSectionV2> {
  final TextEditingController searchController = TextEditingController();
  String query = '';
  String? selectedRoleFilter;
  bool isSyncingUsers = false;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.user.role == 'admin';
    return AdminSectionCard(
      title: tr(context, 'users_tab'),
      addLabel: tr(context, 'add_user'),
      onAdd: () => showUserDialogV2(
        context,
        allowRoleSelection: isAdmin || widget.user.role == 'obermonteur',
        forcedRole: (isAdmin || widget.user.role == 'obermonteur')
            ? null
            : 'worker',
        restrictProjectIds: isAdmin ? null : widget.user.allowedProjects,
        allowedRoles: isAdmin
            ? null
            : widget.user.role == 'obermonteur'
            ? const <String>['worker', 'site_manager']
            : const <String>['worker'],
      ),
      child: Column(
        children: [
          TextField(
            controller: searchController,
            decoration: InputDecoration(
              labelText: tr(context, 'search'),
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) =>
                setState(() => query = value.trim().toLowerCase()),
          ),
          const SizedBox(height: 12),
          if (isAdmin) ...[
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: isSyncingUsers
                    ? null
                    : () async {
                        setState(() {
                          isSyncingUsers = true;
                        });
                        try {
                          await syncFirebaseUsersFromAuth();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  tr(context, 'sync_users_success'),
                                ),
                              ),
                            );
                          }
                        } on FirebaseFunctionsException catch (error) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  (error.message?.isNotEmpty ?? false)
                                      ? error.message!
                                      : tr(context, 'user_create_error'),
                                ),
                              ),
                            );
                          }
                        } catch (error) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() {
                              isSyncingUsers = false;
                            });
                          }
                        }
                      },
                icon: isSyncingUsers
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(tr(context, 'sync_users')),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              value: selectedRoleFilter,
              decoration: InputDecoration(
                labelText: tr(context, 'role_label'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(tr(context, 'all_roles')),
                ),
                DropdownMenuItem<String?>(
                  value: 'worker',
                  child: Text(tr(context, 'role_worker')),
                ),
                DropdownMenuItem<String?>(
                  value: 'site_manager',
                  child: Text(tr(context, 'role_site_manager')),
                ),
                DropdownMenuItem<String?>(
                  value: 'obermonteur',
                  child: Text(tr(context, 'role_obermonteur')),
                ),
                DropdownMenuItem<String?>(
                  value: 'admin',
                  child: Text(tr(context, 'role_admin')),
                ),
              ],
              onChanged: (value) => setState(() => selectedRoleFilter = value),
            ),
            const SizedBox(height: 12),
          ],
          StreamBuilder<List<ProjectRecord>>(
            stream: watchAllProjects(),
            builder: (context, projectSnapshot) {
              final projects = projectSnapshot.data ?? <ProjectRecord>[];
              return StreamBuilder<List<UserRecord>>(
                stream: watchUsers(),
                builder: (context, userSnapshot) {
                  final users = (userSnapshot.data ?? <UserRecord>[]).where((
                    user,
                  ) {
                    final roleMatches =
                        !isAdmin ||
                        selectedRoleFilter == null ||
                        user.role == selectedRoleFilter;
                    final visibleToManager =
                        isAdmin ||
                        ((user.role == 'worker' ||
                                isManagerLikeRole(user.role)) &&
                            user.allowedProjectIds.any(
                              (projectId) => widget.user.allowedProjects
                                  .contains(projectId),
                            ));
                    final searchMatches =
                        query.isEmpty ||
                        user.username.toLowerCase().contains(query) ||
                        user.fullName.toLowerCase().contains(query) ||
                        user.email.toLowerCase().contains(query) ||
                        formatUserRoleLabel(
                          user.role,
                        ).toLowerCase().contains(query);
                    return roleMatches && visibleToManager && searchMatches;
                  }).toList();
                  return Column(
                    children: users.map((user) {
                      final assignedProjectNames =
                          projects
                              .where(
                                (project) =>
                                    user.allowedProjectIds.contains(project.id),
                              )
                              .map((project) => project.name)
                              .toList()
                            ..sort();

                      return ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(user.fullName),
                        subtitle: Text(
                          '${tr(context, 'role_label')}: ${formatUserRoleLabel(user.role)}\n'
                          '${user.username}\n'
                          '${user.email.isEmpty ? '-' : user.email}'
                          '${user.active ? '' : '\n${tr(context, 'inactive')}'}',
                        ),
                        trailing: IconButton(
                          onPressed: () => showUserDialogV2(
                            context,
                            existingUser: user,
                            allowRoleSelection:
                                isAdmin || widget.user.role == 'obermonteur',
                            forcedRole:
                                (isAdmin || widget.user.role == 'obermonteur')
                                ? null
                                : 'worker',
                            restrictProjectIds: isAdmin
                                ? null
                                : widget.user.allowedProjects,
                            allowedRoles: isAdmin
                                ? null
                                : widget.user.role == 'obermonteur'
                                ? const <String>['worker', 'site_manager']
                                : const <String>['worker'],
                          ),
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: tr(context, 'edit'),
                        ),
                        children: [
                          ListTile(
                            contentPadding: const EdgeInsets.only(
                              left: 16,
                              right: 8,
                              bottom: 8,
                            ),
                            title: Text(tr(context, 'assigned_projects')),
                            subtitle: Text(
                              assignedProjectNames.isEmpty
                                  ? '-'
                                  : assignedProjectNames.join(', '),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class AdminOrdersSection extends StatefulWidget {
  const AdminOrdersSection({super.key, required this.user});

  final DemoUser user;

  @override
  State<AdminOrdersSection> createState() => _AdminOrdersSectionState();
}

class _AdminOrdersSectionState extends State<AdminOrdersSection> {
  String? selectedProjectId;
  String? selectedStatus;
  bool sendingNow = false;

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.user.role == 'admin';
    return AdminSectionCard(
      title: tr(context, 'orders_admin_tab'),
      addLabel: tr(context, 'download_excel'),
      onAdd: () async {
        final projects =
            (await watchAllProjects().first)
                .where(
                  (project) =>
                      isAdmin ||
                      widget.user.allowedProjects.contains(project.id),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));
        final allowedProjectIds = projects.map((project) => project.id).toSet();
        final orders =
            (await watchOrderRequests().first)
                .where(
                  (order) =>
                      isAdmin || allowedProjectIds.contains(order.projectId),
                )
                .where(
                  (order) =>
                      selectedProjectId == null ||
                      order.projectId == selectedProjectId,
                )
                .where(
                  (order) =>
                      selectedStatus == null || order.status == selectedStatus,
                )
                .toList()
              ..sort((a, b) {
                final first =
                    b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                final second =
                    a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                return first.compareTo(second);
              });
        await downloadOrderRequestsExportExcel(
          orders,
          LanguageScope.of(context),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'excel_download_ready'))),
          );
        }
      },
      child: StreamBuilder<List<ProjectRecord>>(
        stream: watchAllProjects(),
        builder: (context, projectSnapshot) {
          final projects =
              (projectSnapshot.data ?? <ProjectRecord>[])
                  .where(
                    (project) =>
                        isAdmin ||
                        widget.user.allowedProjects.contains(project.id),
                  )
                  .toList()
                ..sort((a, b) => a.name.compareTo(b.name));
          final allowedProjectIds = projects
              .map((project) => project.id)
              .toSet();

          return StreamBuilder<List<OrderRequestRecord>>(
            stream: watchOrderRequests(),
            builder: (context, snapshot) {
              final orders =
                  (snapshot.data ?? <OrderRequestRecord>[])
                      .where(
                        (order) =>
                            isAdmin ||
                            allowedProjectIds.contains(order.projectId),
                      )
                      .where(
                        (order) =>
                            selectedProjectId == null ||
                            order.projectId == selectedProjectId,
                      )
                      .where(
                        (order) =>
                            selectedStatus == null ||
                            order.status == selectedStatus,
                      )
                      .toList()
                    ..sort((a, b) {
                      final first =
                          b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                      final second =
                          a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                      return first.compareTo(second);
                    });

              return Column(
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: selectedProjectId,
                    decoration: InputDecoration(
                      labelText: tr(context, 'select_project'),
                      border: const OutlineInputBorder(),
                    ),
                    items: <DropdownMenuItem<String?>>[
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(tr(context, 'all_projects')),
                      ),
                      ...projects.map(
                        (project) => DropdownMenuItem<String?>(
                          value: project.id,
                          child: Text(project.name),
                        ),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => selectedProjectId = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedStatus,
                    decoration: InputDecoration(
                      labelText: tr(context, 'status_label'),
                      border: const OutlineInputBorder(),
                    ),
                    items: <DropdownMenuItem<String?>>[
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(tr(context, 'all_statuses')),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'pending',
                        child: Text(tr(context, 'order_status_pending')),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'sent',
                        child: Text(tr(context, 'order_status_sent')),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => selectedStatus = value),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          selectedProjectId = null;
                          selectedStatus = null;
                        });
                      },
                      child: Text(tr(context, 'clear_filters')),
                    ),
                  ),
                  if (orders.any((order) => order.status == 'pending')) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: sendingNow
                            ? null
                            : () async {
                                final shouldSend =
                                    await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text(
                                          tr(context, 'send_orders_now'),
                                        ),
                                        content: Text(
                                          tr(
                                            context,
                                            'send_orders_now_confirm',
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.of(
                                              context,
                                            ).pop(false),
                                            child: Text(tr(context, 'cancel')),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.of(context).pop(true),
                                            child: Text(tr(context, 'send')),
                                          ),
                                        ],
                                      ),
                                    ) ??
                                    false;
                                if (!shouldSend || !mounted) {
                                  return;
                                }

                                setState(() => sendingNow = true);
                                try {
                                  final sentCount =
                                      await dispatchPendingOrdersNowOverHttp();
                                  if (!mounted) {
                                    return;
                                  }
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        sentCount > 0
                                            ? tr(
                                                context,
                                                'send_orders_now_success',
                                              )
                                            : tr(
                                                context,
                                                'send_orders_now_empty',
                                              ),
                                      ),
                                    ),
                                  );
                                } on FirebaseFunctionsException catch (error) {
                                  if (!mounted) {
                                    return;
                                  }
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        error.message?.trim().isNotEmpty == true
                                            ? error.message!
                                            : tr(
                                                context,
                                                'send_orders_now_error',
                                              ),
                                      ),
                                    ),
                                  );
                                } catch (_) {
                                  if (!mounted) {
                                    return;
                                  }
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        tr(context, 'send_orders_now_error'),
                                      ),
                                    ),
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() => sendingNow = false);
                                  }
                                }
                              },
                        icon: sendingNow
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_outlined),
                        label: Text(tr(context, 'send_orders_now')),
                      ),
                    ),
                  ],
                  if (orders.isEmpty)
                    ListTile(title: Text(tr(context, 'no_orders_found')))
                  else
                    ...orders.map(
                      (order) => Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ExpansionTile(
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          childrenPadding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            16,
                          ),
                          title: Text(
                            '${order.projectName} / ${order.buildingName}',
                          ),
                          subtitle: Text(
                            '${tr(context, 'ordered_by_label')}: ${order.orderedBy}'
                            '\n${tr(context, 'scheduled_slot')}: ${order.scheduledSlot}'
                            '${order.createdAt != null ? '\n${tr(context, 'created_at_label')}: ${formatDateTime(order.createdAt!)}' : ''}'
                            '${order.sentAt != null ? '\n${tr(context, 'sent_at_label')}: ${formatDateTime(order.sentAt!)}' : ''}',
                          ),
                          trailing: Chip(
                            label: Text(
                              order.status == 'sent'
                                  ? tr(context, 'order_status_sent')
                                  : tr(context, 'order_status_pending'),
                            ),
                          ),
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '${tr(context, 'items_count_label')}: ${order.items.length}',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...order.items.map((item) {
                              final articleNumber =
                                  item['articleNumber']?.toString().trim() ??
                                  '';
                              final name =
                                  item['name']?.toString().trim() ?? '';
                              final quantity =
                                  item['quantity']?.toString().trim() ?? '';
                              final supplier =
                                  item['supplier']?.toString().trim() ?? '';
                              final category =
                                  item['category']?.toString().trim() ?? '';

                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(name.isEmpty ? '-' : name),
                                subtitle: Text(
                                  [
                                    if (category.isNotEmpty) category,
                                    if (articleNumber.isNotEmpty) articleNumber,
                                    if (supplier.isNotEmpty) supplier,
                                  ].join(' · '),
                                ),
                                trailing: Text(
                                  quantity.isEmpty ? '-' : quantity,
                                ),
                              );
                            }),
                            if (order.note.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '${tr(context, 'note')}: ${order.note}',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class AdminRegisterExportsSection extends StatefulWidget {
  const AdminRegisterExportsSection({super.key, required this.user});

  final DemoUser user;

  @override
  State<AdminRegisterExportsSection> createState() =>
      _AdminRegisterExportsSectionState();
}

class _AdminRegisterExportsSectionState
    extends State<AdminRegisterExportsSection> {
  String? selectedProjectName;
  String? selectedBuildingName;
  String? selectedSignedBy;
  DateTime? fromDate;
  DateTime? toDate;

  Future<void> pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initialDate = isFrom
        ? (fromDate ?? now)
        : (toDate ?? fromDate ?? now);
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (pickedDate == null || !mounted) {
      return;
    }

    setState(() {
      if (isFrom) {
        fromDate = pickedDate;
      } else {
        toDate = pickedDate;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.user.role == 'admin';
    return AdminSectionCard(
      title: tr(context, 'register_exports_tab'),
      addLabel: tr(context, 'download_excel'),
      onAdd: () async {
        final projects = (await watchAllProjects().first)
            .where(
              (project) =>
                  isAdmin || widget.user.allowedProjects.contains(project.id),
            )
            .toList();
        final allowedProjectNames = projects
            .map((project) => normalizeActivityFilterValue(project.name))
            .toSet();
        final submissions = (await watchRegisterSubmissions().first)
            .where(
              (submission) =>
                  isAdmin ||
                  allowedProjectNames.contains(
                    normalizeActivityFilterValue(submission.projectName),
                  ),
            )
            .toList();
        final completedTasks = (await watchCompletedWorkTasks().first)
            .where(
              (task) =>
                  isAdmin ||
                  allowedProjectNames.contains(
                    normalizeActivityFilterValue(task.projectName),
                  ),
            )
            .toList();
        final activities = buildCombinedExportActivities(
          submissions: submissions,
          completedTasks: completedTasks,
        );
        final filteredActivities = applyActivityFilters(activities);
        await downloadActivitiesExportExcel(
          filteredActivities,
          LanguageScope.of(context),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'excel_download_ready'))),
          );
        }
      },
      child: StreamBuilder<List<ProjectRecord>>(
        stream: watchAllProjects(),
        builder: (context, projectSnapshot) {
          final projects = (projectSnapshot.data ?? <ProjectRecord>[])
              .where(
                (project) =>
                    isAdmin || widget.user.allowedProjects.contains(project.id),
              )
              .toList();
          return StreamBuilder<List<RegisterSubmissionRecord>>(
            stream: watchRegisterSubmissions(),
            builder: (context, registerSnapshot) {
              return StreamBuilder<List<WorkTaskRecord>>(
                stream: watchCompletedWorkTasks(),
                builder: (context, taskSnapshot) {
                  final allowedProjectNames = projects
                      .map(
                        (project) => normalizeActivityFilterValue(project.name),
                      )
                      .toSet();
                  final submissions =
                      (registerSnapshot.data ?? <RegisterSubmissionRecord>[])
                          .where(
                            (submission) =>
                                isAdmin ||
                                allowedProjectNames.contains(
                                  normalizeActivityFilterValue(
                                    submission.projectName,
                                  ),
                                ),
                          )
                          .toList();
                  final completedTasks =
                      (taskSnapshot.data ?? <WorkTaskRecord>[])
                          .where(
                            (task) =>
                                isAdmin ||
                                allowedProjectNames.contains(
                                  normalizeActivityFilterValue(
                                    task.projectName,
                                  ),
                                ),
                          )
                          .toList();
                  final activities = buildCombinedExportActivities(
                    submissions: submissions,
                    completedTasks: completedTasks,
                  );
                  final filteredActivities = applyActivityFilters(activities);
                  final availableBuildings =
                      activities
                          .where(
                            (activity) =>
                                selectedProjectName == null ||
                                normalizeActivityFilterValue(
                                      activity.projectName,
                                    ) ==
                                    normalizeActivityFilterValue(
                                      selectedProjectName!,
                                    ),
                          )
                          .map((activity) => activity.buildingName)
                          .where((name) => name.trim().isNotEmpty)
                          .toSet()
                          .toList()
                        ..sort();
                  final availableWorkers =
                      activities
                          .where(
                            (activity) =>
                                (selectedProjectName == null ||
                                    normalizeActivityFilterValue(
                                          activity.projectName,
                                        ) ==
                                        normalizeActivityFilterValue(
                                          selectedProjectName!,
                                        )) &&
                                (selectedBuildingName == null ||
                                    normalizeActivityFilterValue(
                                          activity.buildingName,
                                        ) ==
                                        normalizeActivityFilterValue(
                                          selectedBuildingName!,
                                        )),
                          )
                          .map((activity) => activity.signedBy)
                          .where((name) => name.trim().isNotEmpty)
                          .toSet()
                          .toList()
                        ..sort();

                  return Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            tr(context, 'signed_apartment_when'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ),
                      DropdownButtonFormField<String?>(
                        initialValue: selectedProjectName,
                        decoration: InputDecoration(
                          labelText: tr(context, 'select_project'),
                          border: const OutlineInputBorder(),
                        ),
                        items: <DropdownMenuItem<String?>>[
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(tr(context, 'all_projects')),
                          ),
                          ...projects.map(
                            (project) => DropdownMenuItem<String?>(
                              value: project.name,
                              child: Text(project.name),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() {
                            selectedProjectName = value;
                            selectedBuildingName = null;
                            selectedSignedBy = null;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String?>(
                        initialValue: selectedBuildingName,
                        decoration: InputDecoration(
                          labelText: tr(context, 'select_building_admin'),
                          border: const OutlineInputBorder(),
                        ),
                        items: <DropdownMenuItem<String?>>[
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(tr(context, 'all_buildings')),
                          ),
                          ...availableBuildings.map(
                            (building) => DropdownMenuItem<String?>(
                              value: building,
                              child: Text(building),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() {
                            selectedBuildingName = value;
                            selectedSignedBy = null;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String?>(
                        initialValue: selectedSignedBy,
                        decoration: InputDecoration(
                          labelText: tr(context, 'signed_by'),
                          border: const OutlineInputBorder(),
                        ),
                        items: <DropdownMenuItem<String?>>[
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(tr(context, 'all_workers')),
                          ),
                          ...availableWorkers.map(
                            (worker) => DropdownMenuItem<String?>(
                              value: worker,
                              child: Text(worker),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() {
                            selectedSignedBy = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => pickDate(isFrom: true),
                              child: Text(
                                fromDate == null
                                    ? tr(context, 'date_from')
                                    : '${tr(context, 'date_from')}: ${formatDate(fromDate!)}',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => pickDate(isFrom: false),
                              child: Text(
                                toDate == null
                                    ? tr(context, 'date_to')
                                    : '${tr(context, 'date_to')}: ${formatDate(toDate!)}',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            setState(() {
                              selectedProjectName = null;
                              selectedBuildingName = null;
                              selectedSignedBy = null;
                              fromDate = null;
                              toDate = null;
                            });
                          },
                          child: Text(tr(context, 'clear_filters')),
                        ),
                      ),
                      ...filteredActivities.map(
                        (activity) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${activity.projectName} / ${activity.buildingName} / ${activity.apartmentName}',
                          ),
                          subtitle: Text(
                            '${activity.activityType == 'register' ? 'Register' : activity.activityGroup}'
                            '${activity.roomName.trim().isEmpty ? '' : ' / ${activity.roomName}'}'
                            '\n${activity.activityLabel}'
                            '\n${tr(context, 'signature_time')}: ${formatDateTime(activity.signedAt)}'
                            '\n${tr(context, 'signed_by')}: ${activity.signedBy}',
                          ),
                          trailing:
                              activity.photoCount > 0 ||
                                  activity.signature != null
                              ? Wrap(
                                  spacing: 8,
                                  children: [
                                    if (activity.photoCount > 0)
                                      TextButton(
                                        onPressed: () => showPhotoGallery(
                                          context,
                                          photos: activity.photos,
                                        ),
                                        child: Text(
                                          '${tr(context, 'view_photos')} (${activity.photoCount})',
                                        ),
                                      ),
                                    if (activity.signature != null)
                                      TextButton(
                                        onPressed: () => showPhotoGallery(
                                          context,
                                          photos: [activity.signature!],
                                        ),
                                        child: Text(tr(context, 'signature')),
                                      ),
                                  ],
                                )
                              : null,
                          isThreeLine: true,
                        ),
                      ),
                      if (filteredActivities.isEmpty)
                        ListTile(title: Text(tr(context, 'no_data'))),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  List<ExportActivityRecord> applyActivityFilters(
    List<ExportActivityRecord> activities,
  ) {
    return activities.where((activity) {
      final projectMatches =
          selectedProjectName == null ||
          normalizeActivityFilterValue(activity.projectName) ==
              normalizeActivityFilterValue(selectedProjectName!);
      final buildingMatches =
          selectedBuildingName == null ||
          normalizeActivityFilterValue(activity.buildingName) ==
              normalizeActivityFilterValue(selectedBuildingName!);
      final workerMatches =
          selectedSignedBy == null ||
          normalizeActivityFilterValue(activity.signedBy) ==
              normalizeActivityFilterValue(selectedSignedBy!);
      final date = DateTime(
        activity.signedAt.year,
        activity.signedAt.month,
        activity.signedAt.day,
      );
      final fromMatches = fromDate == null || !date.isBefore(fromDate!);
      final toMatches = toDate == null || !date.isAfter(toDate!);

      return projectMatches &&
          buildingMatches &&
          workerMatches &&
          fromMatches &&
          toMatches;
    }).toList();
  }
}

class OrderItemsScreen extends StatefulWidget {
  const OrderItemsScreen({
    super.key,
    required this.user,
    required this.project,
  });

  final DemoUser user;
  final ProjectRecord project;

  @override
  State<OrderItemsScreen> createState() => _OrderItemsScreenState();
}

Future<void> showPhotoGallery(
  BuildContext context, {
  required List<Map<String, dynamic>> photos,
}) async {
  if (photos.isEmpty) {
    return;
  }

  final pageController = PageController();
  final currentIndex = ValueNotifier<int>(0);

  await showDialog<void>(
    context: context,
    builder: (context) {
      return Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 900,
          height: 680,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ValueListenableBuilder<int>(
              valueListenable: currentIndex,
              builder: (context, index, child) {
                final photo = photos[index];
                final label = photo['labelHr']?.toString() ?? '';

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text('${index + 1} / ${photos.length}'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: index > 0
                                ? () {
                                    pageController.previousPage(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      curve: Curves.easeInOut,
                                    );
                                  }
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                            child: PageView.builder(
                              controller: pageController,
                              onPageChanged: (value) =>
                                  currentIndex.value = value,
                              itemCount: photos.length,
                              itemBuilder: (context, pageIndex) {
                                final item = photos[pageIndex];
                                return InteractiveViewer(
                                  child: _StoragePhotoImage(
                                    photo: item,
                                    fit: BoxFit.contain,
                                  ),
                                );
                              },
                            ),
                          ),
                          IconButton(
                            onPressed: index < photos.length - 1
                                ? () {
                                    pageController.nextPage(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      curve: Curves.easeInOut,
                                    );
                                  }
                                : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 90,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: photos.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(width: 8),
                        itemBuilder: (context, thumbIndex) {
                          final item = photos[thumbIndex];
                          final isSelected = thumbIndex == index;
                          return InkWell(
                            onTap: () {
                              pageController.animateToPage(
                                thumbIndex,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                              );
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: isSelected
                                      ? Colors.teal
                                      : Colors.transparent,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: _StoragePhotoImage(
                                  photo: item,
                                  width: 90,
                                  height: 90,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    },
  );

  pageController.dispose();
  currentIndex.dispose();
}

class _StoragePhotoImage extends StatelessWidget {
  const _StoragePhotoImage({
    required this.photo,
    this.width,
    this.height,
    required this.fit,
  });

  final Map<String, dynamic> photo;
  final double? width;
  final double? height;
  final BoxFit fit;

  Future<String?> loadImageUrl() async {
    final storedUrl = photo['downloadUrl']?.toString() ?? '';
    if (storedUrl.isNotEmpty) {
      return storedUrl;
    }

    final path = photo['path']?.toString() ?? '';
    if (path.isNotEmpty) {
      try {
        return await firebaseStorage.ref(path).getDownloadURL();
      } catch (_) {}
    }

    return null;
  }

  Future<Uint8List?> loadBytes() async {
    final path = photo['path']?.toString() ?? '';
    if (path.isNotEmpty) {
      try {
        return await firebaseStorage.ref(path).getData(15 * 1024 * 1024);
      } catch (_) {}
    }

    final storedUrl = photo['downloadUrl']?.toString() ?? '';
    if (storedUrl.isNotEmpty) {
      try {
        final ref = firebaseStorage.refFromURL(storedUrl);
        return await ref.getData(15 * 1024 * 1024);
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return FutureBuilder<String?>(
        future: loadImageUrl(),
        builder: (context, snapshot) {
          final imageUrl = snapshot.data;
          if (imageUrl == null || imageUrl.isEmpty) {
            return _brokenImagePlaceholder(width: width, height: height);
          }

          return buildWebStoragePhotoView(
            imageUrl: imageUrl,
            width: width,
            height: height,
            fit: fit,
          );
        },
      );
    }

    return FutureBuilder<Uint8List?>(
      future: loadBytes(),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return _brokenImagePlaceholder(width: width, height: height);
        }

        return Image.memory(bytes, width: width, height: height, fit: fit);
      },
    );
  }
}

Widget _brokenImagePlaceholder({double? width, double? height}) {
  return Container(
    width: width,
    height: height,
    color: Colors.grey.shade300,
    alignment: Alignment.center,
    child: const Icon(Icons.broken_image_outlined),
  );
}

class _OrderItemsScreenState extends State<OrderItemsScreen> {
  final TextEditingController noteController = TextEditingController();
  final TextEditingController searchController = TextEditingController();
  String? selectedBuilding;
  bool attemptedOrderSubmit = false;
  String searchQuery = '';
  String? selectedSheetName;
  Map<String, int> materialUsageCounts = <String, int>{};
  List<MaterialRecord> latestAvailableMaterials = <MaterialRecord>[];

  final List<CartLine> cartLines = <CartLine>[];

  bool get hasCartItems => cartLines.isNotEmpty;
  int get cartItemCount =>
      cartLines.fold<int>(0, (sum, line) => sum + line.quantity);

  @override
  void initState() {
    super.initState();
    searchController.addListener(() {
      final nextQuery = searchController.text.trim();
      if (nextQuery == searchQuery) {
        return;
      }
      setState(() {
        searchQuery = nextQuery;
      });
    });
    unawaited(_loadMaterialUsageCounts());
  }

  @override
  void dispose() {
    noteController.dispose();
    searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMaterialUsageCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('material_usage_counts');
    if (raw == null || raw.trim().isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }

      final nextCounts = <String, int>{};
      decoded.forEach((key, value) {
        final parsed = int.tryParse(value.toString());
        if (parsed != null && parsed > 0) {
          nextCounts[key.toString()] = parsed;
        }
      });

      if (!mounted) {
        return;
      }

      setState(() {
        materialUsageCounts = nextCounts;
      });
    } catch (_) {}
  }

  Future<void> _saveMaterialUsageCounts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'material_usage_counts',
      jsonEncode(materialUsageCounts),
    );
  }

  Future<bool> _confirmLeaveOrderScreen() async {
    if (!hasCartItems) {
      return true;
    }

    final shouldLeave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'leave_order_title')),
        content: Text(tr(context, 'leave_order_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr(context, 'no')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr(context, 'yes')),
          ),
        ],
      ),
    );

    return shouldLeave ?? false;
  }

  Color _sheetColor(int index) {
    const palette = <Color>[
      Color(0xFFCC6B00),
      Color(0xFF0F766E),
      Color(0xFF0A6EC7),
      Color(0xFF7C3AED),
      Color(0xFFB54708),
      Color(0xFF1D4ED8),
      Color(0xFF15803D),
      Color(0xFFA21CAF),
    ];
    return palette[index % palette.length];
  }

  void _addMaterialToCart(MaterialRecord material) {
    setState(() {
      final existingIndex = cartLines.indexWhere(
        (line) => line.material.id == material.id,
      );
      if (existingIndex >= 0) {
        cartLines[existingIndex].quantity += 1;
      } else {
        cartLines.add(CartLine(material: material));
      }
      attemptedOrderSubmit = false;
    });
  }

  String _normalizeBarcodeValue(String value) {
    return normalizeScanLookupValue(value);
  }

  Future<void> _scanBarcodeAndAddMaterial(
    List<MaterialRecord> materials,
  ) async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'barcode_scanner_unavailable_web'))),
      );
      return;
    }

    final scannedCode = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (context) => BarcodeScannerScreen(
          title: tr(context, 'barcode_scanner_title'),
          hintText: tr(context, 'barcode_scanner_hint'),
        ),
      ),
    );

    if (!mounted || scannedCode == null || scannedCode.trim().isEmpty) {
      return;
    }

    final normalizedCode = _normalizeBarcodeValue(scannedCode);
    MaterialRecord? matchedMaterial;
    var bestScore = 0;
    for (final material in materials) {
      final score = material.scanMatchScore(normalizedCode);
      if (score > bestScore) {
        bestScore = score;
        matchedMaterial = material;
      }
    }

    if (matchedMaterial == null || bestScore <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(context, 'barcode_not_found'))));
      return;
    }

    _addMaterialToCart(matchedMaterial);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'barcode_added_to_cart'))),
    );
  }

  void _setCartQuantity(CartLine line, int nextQuantity) {
    setState(() {
      if (nextQuantity <= 0) {
        cartLines.removeWhere((entry) => entry.material.id == line.material.id);
        return;
      }

      line.quantity = nextQuantity;
      attemptedOrderSubmit = false;
    });
  }

  Future<void> _openCartSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            void updateQuantity(CartLine line, int nextQuantity) {
              setState(() {
                if (nextQuantity <= 0) {
                  cartLines.removeWhere(
                    (entry) => entry.material.id == line.material.id,
                  );
                } else {
                  line.quantity = nextQuantity;
                }
                attemptedOrderSubmit = false;
              });
              modalSetState(() {});
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.72,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${tr(context, 'order_cart_title')} ($cartItemCount)',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          Text(
                            '$cartItemCount ${tr(context, 'quantity')}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: cartLines.isEmpty
                            ? Center(
                                child: Text(tr(context, 'order_cart_empty')),
                              )
                            : ListView.separated(
                                itemCount: cartLines.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final line = cartLines[index];
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade50,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.grey.shade200,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            line.material.name,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => updateQuantity(
                                            line,
                                            line.quantity - 1,
                                          ),
                                          icon: const Icon(
                                            Icons.remove_circle_outline,
                                          ),
                                        ),
                                        SizedBox(
                                          width: 28,
                                          child: Text(
                                            '${line.quantity}',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => updateQuantity(
                                            line,
                                            line.quantity + 1,
                                          ),
                                          icon: const Icon(
                                            Icons.add_circle_outline,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openMobileSheetCatalog(
    String sheetName,
    List<MaterialRecord> allMaterials,
  ) async {
    final sheetMaterials = allMaterials
        .where((material) => material.sheetName.trim() == sheetName)
        .toList();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.86,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          sheetName,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
                    children: _buildGroupedMaterials(sheetMaterials, 1),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _categoryForDepth(MaterialRecord material, int depth) {
    switch (depth) {
      case 1:
        return material.level1.trim();
      case 2:
        return material.level2.trim();
      case 3:
        return material.level3.trim();
      case 4:
        return material.level4.trim();
      default:
        return '';
    }
  }

  bool _hasCategoryDepth(List<MaterialRecord> materials, int depth) {
    return materials.any(
      (material) => _categoryForDepth(material, depth).isNotEmpty,
    );
  }

  List<Widget> _buildMaterialLeafTiles(List<MaterialRecord> materials) {
    return materials
        .map(
          (material) => ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(material.name, style: const TextStyle(fontSize: 14)),
            trailing: IconButton(
              onPressed: () => _addMaterialToCart(material),
              icon: const Icon(Icons.add_circle_outline),
              tooltip: tr(context, 'add'),
            ),
          ),
        )
        .toList();
  }

  List<Widget> _buildGroupedMaterials(
    List<MaterialRecord> materials,
    int depth,
  ) {
    if (depth > 4 || !_hasCategoryDepth(materials, depth)) {
      return _buildMaterialLeafTiles(materials);
    }

    final groups = <String, List<MaterialRecord>>{};
    final uncategorized = <MaterialRecord>[];

    for (final material in materials) {
      final category = _categoryForDepth(material, depth);
      if (category.isEmpty) {
        uncategorized.add(material);
      } else {
        groups.putIfAbsent(category, () => <MaterialRecord>[]).add(material);
      }
    }

    final widgets = <Widget>[];
    for (final entry in groups.entries) {
      widgets.add(
        Card(
          margin: EdgeInsets.only(left: (depth - 1) * 8, bottom: 8),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 2,
            ),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: Text(
              entry.key,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            children: _buildGroupedMaterials(entry.value, depth + 1),
          ),
        ),
      );
    }

    if (uncategorized.isNotEmpty) {
      widgets.addAll(_buildMaterialLeafTiles(uncategorized));
    }

    return widgets;
  }

  DateTime _nextOrderDispatchTime(DateTime now) {
    final midday = DateTime(now.year, now.month, now.day, 12, 45);
    final afternoon = DateTime(now.year, now.month, now.day, 15, 45);
    if (!now.isAfter(midday)) {
      return midday;
    }
    if (!now.isAfter(afternoon)) {
      return afternoon;
    }
    return DateTime(now.year, now.month, now.day + 1, 12, 45);
  }

  String _formatDispatchSlot(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> sendOrderEmail() async {
    setState(() {
      attemptedOrderSubmit = true;
    });

    if (selectedBuilding == null || selectedBuilding!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'select_building_error'))),
      );
      return;
    }

    if (cartLines.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(context, 'add_item_error'))));
      return;
    }

    String recipientEmail = widget.project.managerEmail.trim();
    String recipientManagerName = widget.project.managerName.trim();
    if (widget.project.managerId.trim().isNotEmpty) {
      final users = await watchUsers().first;
      final matchedManager = users.cast<UserRecord?>().firstWhere(
        (user) => user?.id == widget.project.managerId,
        orElse: () => null,
      );
      if (matchedManager != null) {
        if (matchedManager.email.trim().isNotEmpty) {
          recipientEmail = matchedManager.email.trim();
        }
        if (matchedManager.fullName.trim().isNotEmpty) {
          recipientManagerName = matchedManager.fullName.trim();
        } else if (matchedManager.username.trim().isNotEmpty) {
          recipientManagerName = matchedManager.username.trim();
        }
      }
    }

    if (recipientEmail.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'project_manager_missing'))),
      );
      return;
    }

    final dispatchAt = _nextOrderDispatchTime(DateTime.now());
    final dispatchSlot = _formatDispatchSlot(dispatchAt);
    final orderItems = cartLines
        .map(
          (line) => <String, dynamic>{
            'materialId': line.material.id,
            'category': line.material.sheetName.trim(),
            'articleNumber': line.material.articleLabel,
            'name': line.material.name,
            'quantity': line.quantity,
            'supplier': line.material.supplierLabel,
          },
        )
        .toList();

    await firestore.collection('order_requests').add(<String, dynamic>{
      'projectId': widget.project.id,
      'projectName': widget.project.name,
      'buildingName': selectedBuilding,
      'managerId': widget.project.managerId.trim(),
      'managerName': recipientManagerName,
      'managerEmail': recipientEmail,
      'orderedBy': widget.user.username,
      'note': noteController.text.trim(),
      'items': orderItems,
      'status': 'pending',
      'scheduledSlot': dispatchSlot,
      'scheduledAt': Timestamp.fromDate(dispatchAt),
      'createdAt': Timestamp.now(),
    });

    for (final line in cartLines) {
      materialUsageCounts[line.material.id] =
          (materialUsageCounts[line.material.id] ?? 0) + line.quantity;
    }
    await _saveMaterialUsageCounts();

    if (!mounted) {
      return;
    }

    setState(() {
      cartLines.clear();
      noteController.clear();
      searchController.clear();
      searchQuery = '';
      attemptedOrderSubmit = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr(
            context,
            'order_saved_for_batch',
          ).replaceFirst('{time}', dispatchSlot),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCompactOrderLayout =
        !kIsWeb || MediaQuery.of(context).size.width < 1100;
    final managerLookupFuture = widget.project.managerId.trim().isEmpty
        ? Future<UserRecord?>.value(null)
        : watchUsers().first.then(
            (users) => users.cast<UserRecord?>().firstWhere(
              (user) => user?.id == widget.project.managerId,
              orElse: () => null,
            ),
          );

    return WillPopScope(
      onWillPop: _confirmLeaveOrderScreen,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.project.name),
          actions: isCompactOrderLayout
              ? [
                  IconButton(
                    tooltip: tr(context, 'scan_barcode'),
                    onPressed: latestAvailableMaterials.isEmpty
                        ? null
                        : () => _scanBarcodeAndAddMaterial(
                            latestAvailableMaterials,
                          ),
                    icon: const Icon(Icons.qr_code_scanner_outlined),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: IconButton(
                      tooltip: tr(context, 'order_cart_title'),
                      onPressed: _openCartSheet,
                      icon: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.shopping_cart_outlined),
                          if (cartItemCount > 0)
                            Positioned(
                              right: -6,
                              top: -6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade600,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '$cartItemCount',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ]
              : null,
        ),
        body: StreamBuilder<List<MaterialRecord>>(
          stream: watchActiveProjectMaterialRecords(widget.project.id),
          builder: (context, projectMaterialsSnapshot) {
            return StreamBuilder<List<MaterialRecord>>(
              stream: watchActiveMaterialRecords(),
              builder: (context, materialsSnapshot) {
                final projectMaterials =
                    projectMaterialsSnapshot.data ?? <MaterialRecord>[];
                final globalMaterials =
                    materialsSnapshot.data ?? <MaterialRecord>[];
                final allMaterials = projectMaterials.isNotEmpty
                    ? projectMaterials
                    : globalMaterials;
                if (!listEquals(latestAvailableMaterials, allMaterials)) {
                  latestAvailableMaterials = List<MaterialRecord>.from(
                    allMaterials,
                  );
                }
                final sheetNames =
                    allMaterials
                        .map((material) => material.sheetName.trim())
                        .where((sheet) => sheet.isNotEmpty)
                        .toSet()
                        .toList()
                      ..sort(
                        (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                      );

                final currentSheet = sheetNames.contains(selectedSheetName)
                    ? selectedSheetName
                    : (sheetNames.isEmpty ? null : sheetNames.first);

                final sheetMaterials = currentSheet == null
                    ? allMaterials
                    : allMaterials
                          .where(
                            (material) =>
                                material.sheetName.trim() == currentSheet,
                          )
                          .toList();

                final searchBaseMaterials = searchQuery.isEmpty
                    ? sheetMaterials
                    : allMaterials;

                final filteredMaterials = searchBaseMaterials
                    .where(
                      (material) =>
                          searchQuery.isEmpty ||
                          material.searchIndex.contains(
                            searchQuery.toLowerCase(),
                          ),
                    )
                    .toList();

                final frequentSourceMaterials = isCompactOrderLayout
                    ? allMaterials
                    : sheetMaterials;

                final frequentMaterials =
                    [
                      ...frequentSourceMaterials.where(
                        (material) =>
                            (materialUsageCounts[material.id] ?? 0) > 0,
                      ),
                    ]..sort(
                      (a, b) => (materialUsageCounts[b.id] ?? 0).compareTo(
                        materialUsageCounts[a.id] ?? 0,
                      ),
                    );

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final isWideWeb = kIsWeb && constraints.maxWidth >= 1100;
                    final compactTopSpacing = isWideWeb ? 18.0 : 12.0;
                    final compactFieldDensity = isWideWeb
                        ? const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 16,
                          )
                        : const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          );

                    final projectInfoCard = Card(
                      child: FutureBuilder<UserRecord?>(
                        future: managerLookupFuture,
                        builder: (context, snapshot) {
                          final manager = snapshot.data;
                          final managerName =
                              manager?.fullName.trim().isNotEmpty == true
                              ? manager!.fullName.trim()
                              : manager?.username.trim().isNotEmpty == true
                              ? manager!.username.trim()
                              : widget.project.managerName;
                          final managerEmail =
                              manager?.email.trim().isNotEmpty == true
                              ? manager!.email.trim()
                              : widget.project.managerEmail;

                          return Padding(
                            padding: EdgeInsets.all(isWideWeb ? 18 : 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.project.name,
                                  style:
                                      (isWideWeb
                                              ? Theme.of(
                                                  context,
                                                ).textTheme.titleLarge
                                              : Theme.of(
                                                  context,
                                                ).textTheme.titleMedium)
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                ),
                                SizedBox(height: isWideWeb ? 10 : 6),
                                Wrap(
                                  spacing: isWideWeb ? 16 : 10,
                                  runSpacing: 4,
                                  children: [
                                    Text(
                                      '${tr(context, 'manager')}: $managerName',
                                      style: TextStyle(
                                        fontSize: isWideWeb ? 14 : 12,
                                      ),
                                    ),
                                    Text(
                                      '${tr(context, 'email')}: $managerEmail',
                                      style: TextStyle(
                                        fontSize: isWideWeb ? 14 : 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    );

                    final buildingField = StreamBuilder<List<BuildingRecord>>(
                      stream: watchBuildings(widget.project.id),
                      builder: (context, snapshot) {
                        final buildings = snapshot.data ?? <BuildingRecord>[];
                        return DropdownButtonFormField<String>(
                          value: selectedBuilding,
                          decoration: InputDecoration(
                            labelText: '${tr(context, 'choose_building')} *',
                            border: const OutlineInputBorder(),
                            filled: true,
                            fillColor: Colors.white,
                            isDense: !isWideWeb,
                            contentPadding: compactFieldDensity,
                            errorText:
                                attemptedOrderSubmit &&
                                    (selectedBuilding == null ||
                                        selectedBuilding!.isEmpty)
                                ? tr(context, 'select_building_error')
                                : null,
                          ),
                          items: buildings
                              .map(
                                (building) => DropdownMenuItem<String>(
                                  value: building.name,
                                  child: Text(building.name),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            setState(() {
                              selectedBuilding = value;
                              attemptedOrderSubmit = false;
                            });
                          },
                        );
                      },
                    );

                    final searchField = TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        labelText: tr(context, 'search'),
                        prefixIcon: const Icon(Icons.search, size: 18),
                        border: const OutlineInputBorder(),
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: compactFieldDensity,
                      ),
                      style: TextStyle(fontSize: isWideWeb ? 14 : 13),
                    );

                    final sheetSelector = sheetNames.isEmpty
                        ? const SizedBox.shrink()
                        : SizedBox(
                            height: 48,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: sheetNames.length,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (context, index) {
                                final sheet = sheetNames[index];
                                final color = _sheetColor(index);
                                final selected = sheet == currentSheet;
                                return ChoiceChip(
                                  selected: selected,
                                  label: Text(sheet),
                                  avatar: Icon(
                                    Icons.inventory_2_outlined,
                                    size: 16,
                                    color: selected ? Colors.white : color,
                                  ),
                                  side: BorderSide(
                                    color: color.withOpacity(0.35),
                                  ),
                                  backgroundColor: Colors.white,
                                  selectedColor: color,
                                  labelStyle: TextStyle(
                                    color: selected ? Colors.white : color,
                                    fontSize: isWideWeb ? 13 : 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  onSelected: (_) {
                                    setState(() {
                                      selectedSheetName = sheet;
                                    });
                                  },
                                );
                              },
                            ),
                          );

                    final frequentSection =
                        searchQuery.isEmpty && frequentMaterials.isNotEmpty
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tr(context, 'frequent_items_title'),
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: frequentMaterials
                                    .take(isWideWeb ? 10 : 8)
                                    .map(
                                      (material) => ActionChip(
                                        avatar: const Icon(
                                          Icons.add_circle_outline,
                                          size: 16,
                                        ),
                                        label: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 220,
                                          ),
                                          child: Text(
                                            material.name,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        onPressed: () =>
                                            _addMaterialToCart(material),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                          )
                        : const SizedBox.shrink();

                    final catalogCard = Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
                            child: Text(
                              tr(context, 'quick_add_title'),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: filteredMaterials.isEmpty
                                ? Center(child: Text(tr(context, 'no_data')))
                                : ListView(
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      10,
                                      8,
                                      10,
                                    ),
                                    children: searchQuery.isNotEmpty
                                        ? _buildMaterialLeafTiles(
                                            filteredMaterials,
                                          )
                                        : _buildGroupedMaterials(
                                            filteredMaterials,
                                            1,
                                          ),
                                  ),
                          ),
                        ],
                      ),
                    );

                    final cartCard = Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${tr(context, 'order_cart_title')} (${cartLines.length})',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                Text(
                                  '${cartLines.fold<int>(0, (sum, line) => sum + line.quantity)} ${tr(context, 'quantity')}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (cartLines.isEmpty)
                              Text(
                                tr(context, 'order_cart_empty'),
                                style: Theme.of(context).textTheme.bodyMedium,
                              )
                            else
                              ...cartLines.map(
                                (line) => Container(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          line.material.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => _setCartQuantity(
                                          line,
                                          line.quantity - 1,
                                        ),
                                        icon: const Icon(
                                          Icons.remove_circle_outline,
                                        ),
                                      ),
                                      SizedBox(
                                        width: 28,
                                        child: Text(
                                          '${line.quantity}',
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => _setCartQuantity(
                                          line,
                                          line.quantity + 1,
                                        ),
                                        icon: const Icon(
                                          Icons.add_circle_outline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );

                    final noteAndSendCard = Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: noteController,
                              minLines: isWideWeb ? 5 : 2,
                              maxLines: isWideWeb ? 8 : 3,
                              decoration: InputDecoration(
                                labelText: tr(context, 'note'),
                                border: const OutlineInputBorder(),
                                filled: true,
                                fillColor: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              height: 52,
                              child: ElevatedButton.icon(
                                onPressed:
                                    selectedBuilding == null ||
                                        selectedBuilding!.isEmpty
                                    ? null
                                    : sendOrderEmail,
                                icon: const Icon(Icons.mail_outline),
                                label: Text(tr(context, 'send_order')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );

                    if (isWideWeb) {
                      return Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            projectInfoCard,
                            const SizedBox(height: 16),
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    flex: 7,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              flex: 3,
                                              child: buildingField,
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              flex: 4,
                                              child: searchField,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 14),
                                        sheetSelector,
                                        if (sheetNames.isNotEmpty)
                                          const SizedBox(height: 14),
                                        if (searchQuery.isEmpty &&
                                            frequentMaterials.isNotEmpty) ...[
                                          frequentSection,
                                          const SizedBox(height: 14),
                                        ],
                                        Expanded(child: catalogCard),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  Expanded(
                                    flex: 4,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Expanded(
                                          child: SingleChildScrollView(
                                            child: cartCard,
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        noteAndSendCard,
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: ListView(
                        children: [
                          projectInfoCard,
                          SizedBox(height: compactTopSpacing),
                          buildingField,
                          SizedBox(height: compactTopSpacing),
                          searchField,
                          SizedBox(height: compactTopSpacing),
                          if (hasCartItems)
                            Card(
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 2,
                                ),
                                leading: const Icon(
                                  Icons.shopping_cart_outlined,
                                ),
                                title: Text(
                                  '${tr(context, 'order_cart_title')} ($cartItemCount)',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  tr(context, 'tap_to_open'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: _openCartSheet,
                              ),
                            ),
                          if (hasCartItems) SizedBox(height: compactTopSpacing),
                          if (searchQuery.isEmpty &&
                              frequentMaterials.isNotEmpty) ...[
                            frequentSection,
                            SizedBox(height: compactTopSpacing),
                          ],
                          if (searchQuery.isEmpty) ...[
                            Text(
                              tr(context, 'quick_add_title'),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: sheetNames.length,
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    mainAxisSpacing: 10,
                                    crossAxisSpacing: 10,
                                    childAspectRatio: 2.2,
                                  ),
                              itemBuilder: (context, index) {
                                final sheet = sheetNames[index];
                                final color = _sheetColor(index);
                                return InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () => _openMobileSheetCatalog(
                                    sheet,
                                    allMaterials,
                                  ),
                                  child: Ink(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: color.withOpacity(0.35),
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.inventory_2_outlined,
                                            color: color,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              sheet,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: color,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ] else ...[
                            Text(
                              tr(context, 'search'),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Card(
                              clipBehavior: Clip.antiAlias,
                              child: filteredMaterials.isEmpty
                                  ? Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: Center(
                                        child: Text(tr(context, 'no_data')),
                                      ),
                                    )
                                  : ListView(
                                      shrinkWrap: true,
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      padding: const EdgeInsets.fromLTRB(
                                        8,
                                        10,
                                        8,
                                        10,
                                      ),
                                      children: _buildMaterialLeafTiles(
                                        filteredMaterials,
                                      ),
                                    ),
                            ),
                          ],
                          SizedBox(height: compactTopSpacing),
                          noteAndSendCard,
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class ProjectListScreen extends StatelessWidget {
  const ProjectListScreen({super.key, required this.user});

  final DemoUser user;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserRecord?>(
      stream: watchUserByUsername(user.username),
      builder: (context, userSnapshot) {
        final currentUser = resolveDemoUser(user, userSnapshot.data);
        return Scaffold(
          appBar: AppBar(title: Text(tr(context, 'project_selection'))),
          body: StreamBuilder<List<ProjectRecord>>(
            stream: currentUser.role == 'admin'
                ? watchAllProjects()
                : watchProjects(currentUser.allowedProjects),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Center(child: Text(tr(context, 'loading')));
              }

              final projects = snapshot.data ?? <ProjectRecord>[];
              if (projects.isEmpty) {
                return Center(child: Text(tr(context, 'no_data')));
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: projects.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final project = projects[index];
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      title: Text(
                        project.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${tr(context, 'choose_project')}'
                        '\n${formatTaskProgressSummary(context, totalPoints: project.workTaskTotalPoints, completedPoints: project.workTaskCompletedPoints, progressPercent: project.workTaskProgressPercent)}',
                      ),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => BuildingListScreen(
                              user: currentUser,
                              project: project,
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class BuildingListScreen extends StatelessWidget {
  const BuildingListScreen({
    super.key,
    required this.user,
    required this.project,
  });

  final DemoUser user;
  final ProjectRecord project;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(project.name)),
      body: StreamBuilder<List<BuildingRecord>>(
        stream: watchBuildings(project.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: Text(tr(context, 'loading')));
          }

          final buildings = snapshot.data ?? <BuildingRecord>[];
          if (buildings.isEmpty) {
            return Center(child: Text(tr(context, 'no_data')));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: buildings.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final building = buildings[index];
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(
                    building.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${tr(context, 'user_label')}: ${user.username}'
                    '\n${formatTaskProgressSummary(context, totalPoints: building.workTaskTotalPoints, completedPoints: building.workTaskCompletedPoints, progressPercent: building.workTaskProgressPercent)}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) =>
                            isProductionProjectType(project.projectType)
                            ? ProductionBuildingModeScreen(
                                user: user,
                                project: project,
                                building: building,
                              )
                            : ApartmentListScreen(
                                user: user,
                                project: project,
                                building: building,
                              ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ProductionBuildingModeScreen extends StatelessWidget {
  const ProductionBuildingModeScreen({
    super.key,
    required this.user,
    required this.project,
    required this.building,
  });

  final DemoUser user;
  final ProjectRecord project;
  final BuildingRecord building;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(building.name)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr(context, 'production_mode_hint'),
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final vertical = constraints.maxWidth < 700;
                  final apartmentCard = Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => ApartmentListScreen(
                              user: user,
                              project: project,
                              building: building,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.apartment_outlined, size: 42),
                            const SizedBox(height: 12),
                            Text(
                              tr(context, 'choose_by_apartment'),
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                  final taskCard = Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => ProductionTaskSelectionScreen(
                              user: user,
                              project: project,
                              building: building,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.playlist_add_check_circle_outlined,
                              size: 42,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              tr(context, 'choose_by_task'),
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );

                  if (vertical) {
                    return Column(
                      children: [
                        Expanded(child: apartmentCard),
                        const SizedBox(height: 16),
                        Expanded(child: taskCard),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: apartmentCard),
                      const SizedBox(width: 16),
                      Expanded(child: taskCard),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ApartmentListScreen extends StatelessWidget {
  const ApartmentListScreen({
    super.key,
    required this.user,
    required this.project,
    required this.building,
  });

  final DemoUser user;
  final ProjectRecord project;
  final BuildingRecord building;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(building.name)),
      body: StreamBuilder<List<WohnungRecord>>(
        stream: watchWohnungs(building.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: Text(tr(context, 'loading')));
          }

          final wohnungs = snapshot.data ?? <WohnungRecord>[];
          if (wohnungs.isEmpty) {
            return Center(child: Text(tr(context, 'no_data')));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: wohnungs.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final wohnung = wohnungs[index];
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(
                    wohnung.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${tr(context, 'choose_apartment')}'
                    '\n${formatTaskProgressSummary(context, totalPoints: wohnung.workTaskTotalPoints, completedPoints: wohnung.workTaskCompletedPoints, progressPercent: wohnung.workTaskProgressPercent)}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => ApartmentTaskListScreen(
                          user: user,
                          project: project,
                          building: building,
                          wohnung: wohnung,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ProductionTaskOption {
  const ProductionTaskOption({
    required this.taskGroup,
    required this.taskType,
    required this.taskLabel,
    required this.tasks,
  });

  final String taskGroup;
  final String taskType;
  final String taskLabel;
  final List<WorkTaskRecord> tasks;

  String get key =>
      '${normalizeImportUserKey(taskGroup)}|${normalizeImportUserKey(taskType)}|${normalizeImportUserKey(taskLabel)}';
}

class ProductionTaskSelectionScreen extends StatelessWidget {
  const ProductionTaskSelectionScreen({
    super.key,
    required this.user,
    required this.project,
    required this.building,
  });

  final DemoUser user;
  final ProjectRecord project;
  final BuildingRecord building;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'choose_by_task'))),
      body: StreamBuilder<List<WorkTaskRecord>>(
        stream: watchWorkTasksForBuilding(building.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: Text(tr(context, 'loading')));
          }

          final allTasks = snapshot.data ?? <WorkTaskRecord>[];
          final availableTasks = allTasks
              .where((task) => !task.completed)
              .where(
                (task) => userCanCompleteTaskGroup(
                  user: user,
                  projectId: project.id,
                  taskGroup: task.taskGroup,
                ),
              )
              .toList();
          if (availableTasks.isEmpty) {
            return Center(child: Text(tr(context, 'no_data')));
          }

          final grouped = <String, ProductionTaskOption>{};
          for (final task in availableTasks) {
            final option = ProductionTaskOption(
              taskGroup: task.taskGroup,
              taskType: task.taskType,
              taskLabel: task.taskLabel,
              tasks: [task],
            );
            final existing = grouped[option.key];
            if (existing == null) {
              grouped[option.key] = option;
            } else {
              grouped[option.key] = ProductionTaskOption(
                taskGroup: existing.taskGroup,
                taskType: existing.taskType,
                taskLabel: existing.taskLabel,
                tasks: [...existing.tasks, task],
              );
            }
          }

          final options = grouped.values.toList()
            ..sort(
              (a, b) => a.taskLabel.toLowerCase().compareTo(
                b.taskLabel.toLowerCase(),
              ),
            );

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: options.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final option = options[index];
              final apartments = option.tasks
                  .map((task) => task.apartmentName)
                  .toSet()
                  .length;
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(
                    option.taskLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${tr(context, 'apartments_label')}: $apartments',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) =>
                            ProductionTaskApartmentSelectionScreen(
                              user: user,
                              project: project,
                              building: building,
                              option: option,
                            ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ProductionTaskApartmentSelectionScreen extends StatefulWidget {
  const ProductionTaskApartmentSelectionScreen({
    super.key,
    required this.user,
    required this.project,
    required this.building,
    required this.option,
  });

  final DemoUser user;
  final ProjectRecord project;
  final BuildingRecord building;
  final ProductionTaskOption option;

  @override
  State<ProductionTaskApartmentSelectionScreen> createState() =>
      _ProductionTaskApartmentSelectionScreenState();
}

class _ProductionTaskApartmentSelectionScreenState
    extends State<ProductionTaskApartmentSelectionScreen> {
  late final Map<String, bool> selections = <String, bool>{
    for (final task in widget.option.tasks) task.id: false,
  };

  @override
  Widget build(BuildContext context) {
    final sortedTasks = [...widget.option.tasks]
      ..sort((a, b) => compareWohnungNames(a.apartmentName, b.apartmentName));
    final selectedTasks = sortedTasks
        .where((task) => selections[task.id] ?? false)
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text(widget.option.taskLabel)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr(context, 'select_apartments_for_task'),
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: sortedTasks.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final task = sortedTasks[index];
                  return CheckboxListTile(
                    value: selections[task.id] ?? false,
                    title: Text(task.apartmentName),
                    subtitle: Text(task.taskGroup),
                    onChanged: (value) {
                      setState(() {
                        selections[task.id] = value ?? false;
                      });
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 20),
              child: SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: selectedTasks.isEmpty
                      ? null
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) =>
                                  ProductionBatchSignatureScreen(
                                    user: widget.user,
                                    project: widget.project,
                                    building: widget.building,
                                    taskLabel: widget.option.taskLabel,
                                    tasks: selectedTasks,
                                  ),
                            ),
                          );
                        },
                  child: Text(tr(context, 'go_to_signature')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ApartmentTaskListScreen extends StatelessWidget {
  const ApartmentTaskListScreen({
    super.key,
    required this.user,
    required this.project,
    required this.building,
    required this.wohnung,
  });

  final DemoUser user;
  final ProjectRecord project;
  final BuildingRecord building;
  final WohnungRecord wohnung;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${building.name} • ${wohnung.name}'),
        actions: [
          ValueListenableBuilder<List<SharedPdfPayload>>(
            valueListenable: pendingSharedPdfNotifier,
            builder: (context, pendingFiles, child) {
              return IconButton(
                tooltip: tr(context, 'attach_document'),
                onPressed: () => attachPendingSharedDocumentsForWohnung(
                  context,
                  user: user,
                  project: project,
                  building: building,
                  wohnung: wohnung,
                  pendingFiles: pendingFiles,
                ),
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.picture_as_pdf_outlined),
                    if (pendingFiles.isNotEmpty)
                      Positioned(
                        right: -6,
                        top: -6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${pendingFiles.length}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<List<WorkTaskRecord>>(
        stream: watchWorkTasksForWohnung(wohnung.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: Text(tr(context, 'loading')));
          }

          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(context, 'work_tasks_load_error'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(tr(context, 'refresh_and_try_again')),
                    ],
                  ),
                ),
              ),
            );
          }

          final rawTasks = snapshot.data ?? <WorkTaskRecord>[];
          final tasks = rawTasks;
          if (tasks.isEmpty) {
            final expectedTasks = wohnung.workTaskTotalPoints > 0;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        expectedTasks
                            ? tr(context, 'work_tasks_load_error')
                            : tr(context, 'no_work_tasks_for_apartment'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  if (expectedTasks && rawTasks.isEmpty) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(tr(context, 'refresh_and_try_again')),
                    ),
                  ],
                  if (rawTasks.isNotEmpty) const SizedBox(height: 8),
                  const SizedBox(height: 16),
                  if (rawTasks.isEmpty)
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => RegisterEntryScreen(
                              projectName: project.name,
                              projectType: project.projectType,
                              buildingName: building.name,
                              apartmentName: wohnung.name,
                              roomName: '',
                              checklistType: wohnung.checklistType,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(
                        Icons.playlist_add_check_circle_outlined,
                      ),
                      label: Text(tr(context, 'open_register')),
                    ),
                ],
              ),
            );
          }

          final totalPoints = tasks.fold<int>(
            0,
            (sum, task) => sum + task.pointValue,
          );
          final completedPoints = tasks.fold<int>(
            0,
            (sum, task) => sum + (task.completed ? task.pointValue : 0),
          );
          final progressPercent = calculateTaskProgressPercent(
            totalPoints: totalPoints,
            completedPoints: completedPoints,
          );

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        wohnung.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        formatTaskProgressSummary(
                          context,
                          totalPoints: totalPoints,
                          completedPoints: completedPoints,
                          progressPercent: progressPercent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              StreamBuilder<List<ApartmentDocumentRecord>>(
                stream: watchApartmentDocuments(wohnung.id),
                builder: (context, documentSnapshot) {
                  final documents =
                      documentSnapshot.data ?? <ApartmentDocumentRecord>[];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  tr(context, 'apartment_documents'),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => savePickedPdfForWohnung(
                                  context,
                                  user: user,
                                  project: project,
                                  building: building,
                                  wohnung: wohnung,
                                ),
                                icon: const Icon(Icons.upload_file_outlined),
                                label: Text(tr(context, 'add_pdf')),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (documents.isEmpty)
                            Text(tr(context, 'no_documents'))
                          else
                            ...documents.map(
                              (document) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                leading: const Icon(
                                  Icons.picture_as_pdf_outlined,
                                ),
                                title: Text(document.fileName),
                                subtitle: Text(
                                  '${document.uploadedBy}\n${formatDateTime(document.uploadedAt)}',
                                ),
                                isThreeLine: true,
                                onTap: () async {
                                  final uri = Uri.tryParse(
                                    document.downloadUrl,
                                  );
                                  if (uri == null) {
                                    return;
                                  }
                                  await launchUrl(
                                    uri,
                                    mode: LaunchMode.externalApplication,
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              ...tasks.map((task) {
                final normalizedGroup = normalizeImportUserKey(task.taskGroup);
                final canCompleteTask = userCanCompleteTaskGroup(
                  user: user,
                  projectId: project.id,
                  taskGroup: task.taskGroup,
                );

                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    title: Text(task.taskLabel),
                    subtitle: Text(
                      task.completed
                          ? task.completedViaImport
                                ? tr(context, 'task_completed_via_import')
                                : '${tr(context, 'completed_label')}: ${task.completedBy.isEmpty ? '-' : task.completedBy}'
                          : (task.taskGroup.isEmpty
                                ? tr(context, 'task_pending')
                                : task.taskGroup),
                    ),
                    trailing: task.completed
                        ? Icon(
                            Icons.check_circle,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : FilledButton.icon(
                            onPressed: canCompleteTask
                                ? () {
                                    if (normalizedGroup == 'register' &&
                                        !isProductionProjectType(
                                          project.projectType,
                                        )) {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (context) =>
                                              RegisterEntryScreen(
                                                projectName: project.name,
                                                projectType:
                                                    project.projectType,
                                                buildingName: building.name,
                                                apartmentName: wohnung.name,
                                                roomName: '',
                                                checklistType:
                                                    wohnung.checklistType
                                                        .trim()
                                                        .isEmpty
                                                    ? 'Medientrager'
                                                    : wohnung.checklistType,
                                                initialRegisterName:
                                                    task.taskType
                                                        .trim()
                                                        .isNotEmpty
                                                    ? task.taskType
                                                    : task.taskLabel,
                                                lockRegisterName: true,
                                                taskToComplete: task,
                                              ),
                                        ),
                                      );
                                      return;
                                    }

                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (context) =>
                                            WorkTaskSignatureScreen(
                                              user: user,
                                              task: task,
                                            ),
                                      ),
                                    );
                                  }
                                : null,
                            icon: Icon(
                              normalizedGroup == 'register'
                                  ? Icons.playlist_add_check_circle_outlined
                                  : Icons.draw_outlined,
                            ),
                            label: Text(
                              normalizedGroup == 'register'
                                  ? tr(context, 'open_register')
                                  : tr(context, 'complete_task'),
                            ),
                          ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

class WorkTaskSignatureScreen extends StatefulWidget {
  const WorkTaskSignatureScreen({
    super.key,
    required this.user,
    required this.task,
  });

  final DemoUser user;
  final WorkTaskRecord task;

  @override
  State<WorkTaskSignatureScreen> createState() =>
      _WorkTaskSignatureScreenState();
}

class _WorkTaskSignatureScreenState extends State<WorkTaskSignatureScreen> {
  final GlobalKey signaturePadKey = GlobalKey();
  final List<Offset?> points = <Offset?>[];
  bool isSubmitting = false;

  bool get hasSignature => points.any((point) => point != null);

  void clearSignature() {
    setState(() {
      points.clear();
    });
  }

  void addPoint(Offset globalPosition) {
    final renderBox =
        signaturePadKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }

    final localPosition = renderBox.globalToLocal(globalPosition);
    setState(() {
      points.add(localPosition);
    });
  }

  Future<Uint8List?> captureSignatureBytes() async {
    final boundary =
        signaturePadKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      return null;
    }

    final image = await boundary.toImage(pixelRatio: 1.5);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<void> finishTaskWithSignature() async {
    if (!hasSignature || isSubmitting) {
      if (!hasSignature) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'signature_required_for_task'))),
        );
      }
      return;
    }

    setState(() {
      isSubmitting = true;
    });

    try {
      final signedAt = DateTime.now();
      final signatureBytes = await captureSignatureBytes();
      Map<String, dynamic>? uploadedSignature;
      try {
        uploadedSignature = await uploadWorkTaskSignature(
          task: widget.task,
          signedAt: signedAt,
          signatureBytes: signatureBytes,
        ).timeout(const Duration(seconds: 15));
      } catch (_) {
        uploadedSignature = buildInlineWorkTaskSignaturePayload(
          signatureBytes: signatureBytes,
        );
      }

      final completed = await completeWorkTask(
        task: widget.task,
        completedBy: widget.user.username,
        signature: uploadedSignature,
      ).timeout(const Duration(seconds: 15));

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              context,
              completed ? 'task_completed_success' : 'task_already_completed',
            ),
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'task_complete_error'))),
      );
    } finally {
      if (mounted) {
        setState(() {
          isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'signature'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.task.apartmentName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(widget.task.taskLabel),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr(context, 'signature_instruction'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: RepaintBoundary(
                key: signaturePadKey,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.teal, width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: GestureDetector(
                      onPanStart: (details) => addPoint(details.globalPosition),
                      onPanUpdate: (details) =>
                          addPoint(details.globalPosition),
                      onPanEnd: (_) {
                        setState(() {
                          points.add(null);
                        });
                      },
                      child: CustomPaint(
                        painter: SignaturePainter(points),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (isSubmitting) ...[
              Text(
                tr(context, 'saving_signature'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 16),
            ],
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 28),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: isSubmitting ? null : clearSignature,
                      child: Text(tr(context, 'clear_signature')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: isSubmitting ? null : finishTaskWithSignature,
                      child: Text(tr(context, 'complete_task')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProductionBatchSignatureScreen extends StatefulWidget {
  const ProductionBatchSignatureScreen({
    super.key,
    required this.user,
    required this.project,
    required this.building,
    required this.taskLabel,
    required this.tasks,
  });

  final DemoUser user;
  final ProjectRecord project;
  final BuildingRecord building;
  final String taskLabel;
  final List<WorkTaskRecord> tasks;

  @override
  State<ProductionBatchSignatureScreen> createState() =>
      _ProductionBatchSignatureScreenState();
}

class _ProductionBatchSignatureScreenState
    extends State<ProductionBatchSignatureScreen> {
  final GlobalKey signaturePadKey = GlobalKey();
  final List<Offset?> points = <Offset?>[];
  bool isSubmitting = false;

  bool get hasSignature => points.any((point) => point != null);

  void clearSignature() {
    setState(() {
      points.clear();
    });
  }

  void addPoint(Offset globalPosition) {
    final renderBox =
        signaturePadKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }

    final localPosition = renderBox.globalToLocal(globalPosition);
    setState(() {
      points.add(localPosition);
    });
  }

  Future<Uint8List?> captureSignatureBytes() async {
    final boundary =
        signaturePadKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      return null;
    }

    final image = await boundary.toImage(pixelRatio: 1.5);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<void> finishBatch() async {
    if (!hasSignature || isSubmitting) {
      if (!hasSignature) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'signature_required_for_task'))),
        );
      }
      return;
    }

    setState(() => isSubmitting = true);
    final signatureBytes = await captureSignatureBytes();
    final signature = buildInlineWorkTaskSignaturePayload(
      signatureBytes: signatureBytes,
    );

    var completedCount = 0;
    for (final task in widget.tasks) {
      final completed = await completeWorkTask(
        task: task,
        completedBy: currentSessionUsername.isEmpty
            ? widget.user.username
            : currentSessionUsername,
        signature: signature,
      );
      if (completed) {
        completedCount++;
      }
    }

    if (!mounted) {
      return;
    }

    setState(() => isSubmitting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr(
            context,
            'batch_task_completed_message',
          ).replaceFirst('{count}', completedCount.toString()),
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final apartmentNames =
        widget.tasks.map((task) => task.apartmentName).toList()
          ..sort(compareWohnungNames);

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'signature'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.taskLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${tr(context, 'apartments_label')}: ${apartmentNames.join(', ')}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr(context, 'signature_instruction'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: RepaintBoundary(
                key: signaturePadKey,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (details) => addPoint(details.globalPosition),
                  onPanUpdate: (details) => addPoint(details.globalPosition),
                  onPanEnd: (_) => points.add(null),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.white,
                    ),
                    child: CustomPaint(
                      painter: SignaturePainter(points),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: isSubmitting ? null : clearSignature,
                    child: Text(tr(context, 'clear_signature')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: isSubmitting ? null : finishBatch,
                    child: Text(tr(context, 'save')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class RegisterEntryScreen extends StatefulWidget {
  const RegisterEntryScreen({
    super.key,
    required this.projectName,
    required this.projectType,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
    required this.checklistType,
    this.initialRegisterName,
    this.lockRegisterName = false,
    this.taskToComplete,
  });

  final String projectName;
  final String projectType;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String checklistType;
  final String? initialRegisterName;
  final bool lockRegisterName;
  final WorkTaskRecord? taskToComplete;

  @override
  State<RegisterEntryScreen> createState() => _RegisterEntryScreenState();
}

class _RegisterEntryScreenState extends State<RegisterEntryScreen> {
  final TextEditingController registerController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if ((widget.initialRegisterName ?? '').trim().isNotEmpty) {
      registerController.text = widget.initialRegisterName!.trim();
    }
  }

  @override
  void dispose() {
    registerController.dispose();
    super.dispose();
  }

  Future<void> continueToChecklist() async {
    final registerName = registerController.text.trim();
    if (registerName.isEmpty) {
      return;
    }

    final registerKey = buildRegisterKey(
      projectName: widget.projectName,
      buildingName: widget.buildingName,
      apartmentName: widget.apartmentName,
      roomName: widget.roomName,
      registerName: registerName,
    );

    var shouldContinue = true;

    final pendingSubmissions = await loadPendingRegisterSubmissions();
    final pendingRegisterAlreadySaved = pendingSubmissions.any(
      (submission) => submission.registerKey == registerKey,
    );

    var registerAlreadySent =
        submittedRegisterKeys.contains(registerKey) ||
        pendingRegisterAlreadySaved;

    if (!registerAlreadySent) {
      try {
        registerAlreadySent =
            (await firestore
                    .collection('register_submissions')
                    .where('registerKey', isEqualTo: registerKey)
                    .limit(1)
                    .get())
                .docs
                .isNotEmpty;
      } catch (_) {
        registerAlreadySent = false;
      }
    }

    if (registerAlreadySent) {
      shouldContinue =
          await showDialog<bool>(
            context: context,
            builder: (context) {
              return AlertDialog(
                title: Text(tr(context, 'register_already_sent_title')),
                content: Text(tr(context, 'register_already_sent_message')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(tr(context, 'cancel')),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(tr(context, 'send_again')),
                  ),
                ],
              );
            },
          ) ??
          false;
    }

    if (!shouldContinue || !mounted) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChecklistScreen(
          projectName: widget.projectName,
          projectType: widget.projectType,
          buildingName: widget.buildingName,
          apartmentName: widget.apartmentName,
          roomName: widget.roomName,
          registerName: registerName,
          checklistType: widget.checklistType.trim().isEmpty
              ? 'Medientrager'
              : widget.checklistType,
          taskToComplete: widget.taskToComplete,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'register_entry'))),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.projectName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.buildingName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.apartmentName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              widget.roomName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: registerController,
              enabled: !widget.lockRegisterName,
              decoration: InputDecoration(
                labelText: tr(context, 'enter_register'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: continueToChecklist,
                child: Text(tr(context, 'continue_checklist')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChecklistScreen extends StatefulWidget {
  const ChecklistScreen({
    super.key,
    required this.projectName,
    required this.projectType,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
    required this.registerName,
    required this.checklistType,
    this.taskToComplete,
  });

  final String projectName;
  final String projectType;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String registerName;
  final String checklistType;
  final WorkTaskRecord? taskToComplete;

  @override
  State<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<ChecklistScreen> {
  late final List<ChecklistItem> items = buildChecklistItemsForType(
    widget.checklistType,
  );

  bool get allDone => items.every((item) => item.done);

  @override
  Widget build(BuildContext context) {
    final language = LanguageScope.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'checklist'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InfoCard(
              projectName: widget.projectName,
              buildingName: widget.buildingName,
              apartmentName: widget.apartmentName,
              roomName: widget.roomName,
              registerName: widget.registerName,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return CheckboxListTile(
                    value: item.done,
                    title: Text(
                      language == AppLanguage.hr ? item.titleHr : item.titleDe,
                    ),
                    onChanged: (value) {
                      setState(() {
                        item.done = value ?? false;
                      });
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 28),
              child: SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () {
                    if (!allDone) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(tr(context, 'complete_items_error')),
                        ),
                      );
                      return;
                    }

                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) =>
                            isProductionProjectType(widget.projectType)
                            ? SignatureScreen(
                                projectName: widget.projectName,
                                buildingName: widget.buildingName,
                                apartmentName: widget.apartmentName,
                                roomName: widget.roomName,
                                registerName: widget.registerName,
                                photoItems: const <PhotoItem>[],
                                taskToComplete: widget.taskToComplete,
                              )
                            : PhotoDocumentationScreen(
                                projectName: widget.projectName,
                                buildingName: widget.buildingName,
                                apartmentName: widget.apartmentName,
                                roomName: widget.roomName,
                                registerName: widget.registerName,
                                taskToComplete: widget.taskToComplete,
                              ),
                      ),
                    );
                  },
                  child: Text(tr(context, 'go_to_signature')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PhotoDocumentationScreen extends StatefulWidget {
  const PhotoDocumentationScreen({
    super.key,
    required this.projectName,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
    required this.registerName,
    this.taskToComplete,
  });

  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String registerName;
  final WorkTaskRecord? taskToComplete;

  @override
  State<PhotoDocumentationScreen> createState() =>
      _PhotoDocumentationScreenState();
}

class _PhotoDocumentationScreenState extends State<PhotoDocumentationScreen> {
  final ImagePicker imagePicker = ImagePicker();
  int extraPhotoCounter = 1;
  late final List<PhotoItem> photoItems = <PhotoItem>[
    PhotoItem(
      titleHr: 'Fotografija registra',
      titleDe: 'Pflichtfoto',
      requiredPhoto: true,
    ),
    PhotoItem(
      titleHr: 'Dodatna fotografija',
      titleDe: 'Zusatzliches Foto',
      requiredPhoto: false,
    ),
  ];

  bool get hasRequiredPhoto =>
      photoItems.where((item) => item.requiredPhoto).every((item) => item.done);

  void addExtraPhotoItem() {
    extraPhotoCounter += 1;
    setState(() {
      photoItems.add(
        PhotoItem(
          titleHr: 'Dodatna fotografija $extraPhotoCounter',
          titleDe: 'Zusätzliches Foto $extraPhotoCounter',
          requiredPhoto: false,
        ),
      );
    });
  }

  Future<void> capturePhoto(PhotoItem item) async {
    Uint8List? originalBytes;

    if (kIsWeb) {
      originalBytes = await pickImageBytesForWeb();
    } else {
      final pickedFile = await imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 100,
      );

      if (pickedFile == null) {
        return;
      }

      originalBytes = await pickedFile.readAsBytes();
    }

    if (originalBytes == null) {
      return;
    }

    Uint8List finalBytes = originalBytes;
    try {
      final compressedBytes = await FlutterImageCompress.compressWithList(
        originalBytes,
        quality: 75,
        minWidth: 1600,
        minHeight: 1600,
        format: CompressFormat.jpeg,
      );

      if (compressedBytes.isNotEmpty) {
        finalBytes = compressedBytes;
      }
    } catch (_) {
      finalBytes = originalBytes;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      item.done = true;
      item.previewBytes = finalBytes;
      item.originalBytesSize = originalBytes!.length;
      item.compressedBytesSize = finalBytes.length;
    });
  }

  void removePhoto(PhotoItem item) {
    setState(() {
      item.done = false;
      item.previewBytes = null;
      item.originalBytesSize = null;
      item.compressedBytesSize = null;
    });
  }

  String buildPhotoSubtitle(BuildContext context, PhotoItem item) {
    final originalSize = item.originalBytesSize;
    final compressedSize = item.compressedBytesSize;

    if (originalSize == null || compressedSize == null) {
      return tr(context, 'photo_marked');
    }

    return '${tr(context, 'photo_compressed')}\n'
        '${formatFileSize(originalSize)} -> ${formatFileSize(compressedSize)}';
  }

  @override
  Widget build(BuildContext context) {
    final language = LanguageScope.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'photo_docs'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InfoCard(
              projectName: widget.projectName,
              buildingName: widget.buildingName,
              apartmentName: widget.apartmentName,
              roomName: widget.roomName,
              registerName: widget.registerName,
            ),
            const SizedBox(height: 12),
            Text(
              tr(context, 'photo_instruction'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: photoItems.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final item = photoItems[index];
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      leading: item.previewBytes != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.memory(
                                item.previewBytes!,
                                width: 52,
                                height: 52,
                                fit: BoxFit.cover,
                              ),
                            )
                          : CircleAvatar(
                              backgroundColor: item.done
                                  ? Colors.teal
                                  : Colors.grey.shade300,
                              child: Icon(
                                item.done
                                    ? Icons.check
                                    : Icons.photo_camera_outlined,
                                color: item.done
                                    ? Colors.white
                                    : Colors.black54,
                              ),
                            ),
                      title: Text(
                        '${language == AppLanguage.hr ? item.titleHr : item.titleDe}'
                        '${item.requiredPhoto ? ' *' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        item.done
                            ? buildPhotoSubtitle(context, item)
                            : tr(context, 'add_photo'),
                      ),
                      isThreeLine: item.done,
                      minVerticalPadding: 12,
                      trailing: TextButton(
                        onPressed: () =>
                            item.done ? removePhoto(item) : capturePhoto(item),
                        child: Text(
                          item.done
                              ? tr(context, 'remove')
                              : tr(context, 'add'),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: addExtraPhotoItem,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: Text(tr(context, 'add_extra_photo')),
            ),
            const SizedBox(height: 12),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 28),
              child: SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () {
                    if (!hasRequiredPhoto) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr(context, 'photo_required'))),
                      );
                      return;
                    }

                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => SignatureScreen(
                          projectName: widget.projectName,
                          buildingName: widget.buildingName,
                          apartmentName: widget.apartmentName,
                          roomName: widget.roomName,
                          registerName: widget.registerName,
                          photoItems: photoItems
                              .where((item) => item.previewBytes != null)
                              .map((item) => item.copy())
                              .toList(),
                          taskToComplete: widget.taskToComplete,
                        ),
                      ),
                    );
                  },
                  child: Text(tr(context, 'continue_signature')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SignatureScreen extends StatefulWidget {
  const SignatureScreen({
    super.key,
    required this.projectName,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
    required this.registerName,
    required this.photoItems,
    this.taskToComplete,
  });

  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String registerName;
  final List<PhotoItem> photoItems;
  final WorkTaskRecord? taskToComplete;

  @override
  State<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends State<SignatureScreen> {
  final GlobalKey signaturePadKey = GlobalKey();
  final List<Offset?> points = <Offset?>[];
  bool isSubmitting = false;

  bool get hasSignature => points.any((point) => point != null);

  void clearSignature() {
    setState(() {
      points.clear();
    });
  }

  Future<Uint8List?> captureSignatureBytes() async {
    final boundary =
        signaturePadKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      return null;
    }

    final image = await boundary.toImage(pixelRatio: 1.5);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  PendingRegisterSubmission buildPendingSubmission({
    required DateTime signedAt,
    required String registerKey,
    required Uint8List? signatureBytes,
  }) {
    return PendingRegisterSubmission(
      projectName: widget.projectName,
      buildingName: widget.buildingName,
      apartmentName: widget.apartmentName,
      roomName: widget.roomName,
      registerName: widget.registerName,
      signedBy: currentSessionUsername.isEmpty
          ? 'unknown'
          : currentSessionUsername,
      signedAt: signedAt,
      registerKey: registerKey,
      photos: widget.photoItems
          .where((item) => item.previewBytes != null)
          .map(
            (item) => <String, dynamic>{
              'labelHr': item.titleHr,
              'labelDe': item.titleDe,
              'bytesBase64': base64Encode(item.previewBytes!),
            },
          )
          .toList(),
      signatureBytesBase64: signatureBytes == null
          ? null
          : base64Encode(signatureBytes),
    );
  }

  Future<DemoUser> buildCurrentSessionHomeUser() async {
    final username = currentSessionUsername.trim();
    if (username.isNotEmpty) {
      try {
        final liveUser = await watchUserByUsername(username).first;
        if (liveUser != null) {
          return DemoUser(
            username: liveUser.username,
            password: '',
            role: liveUser.role,
            allowedProjects: liveUser.allowedProjectIds,
            allowedTaskGroupsByProject: liveUser.allowedTaskGroupsByProject,
          );
        }
      } catch (_) {}

      return DemoUser(
        username: username,
        password: '',
        role: 'worker',
        allowedProjects: const <String>[],
        allowedTaskGroupsByProject: const <String, List<String>>{},
      );
    }

    return const DemoUser(
      username: '',
      password: '',
      role: 'worker',
      allowedProjects: <String>[],
      allowedTaskGroupsByProject: <String, List<String>>{},
    );
  }

  Future<void> showRegisterCompletionDialog({
    required DateTime signedAt,
    required bool offlineSaved,
  }) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            offlineSaved
                ? tr(context, 'register_saved_offline_title')
                : tr(context, 'register_closed'),
          ),
          content: Text(
            [
              '${tr(context, 'project_selection')}: ${widget.projectName}',
              '${tr(context, 'signature_saved_for')} ${widget.apartmentName}.',
              if (widget.roomName.trim().isNotEmpty)
                '${tr(context, 'room')}: ${widget.roomName}',
              '${tr(context, 'signature_time')}: ${formatDateTime(signedAt)}',
              if (offlineSaved) tr(context, 'register_saved_offline_message'),
            ].join('\n'),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final homeUser = await buildCurrentSessionHomeUser();
                if (!context.mounted) {
                  return;
                }

                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute<void>(
                    builder: (context) => HomeSelectionScreen(user: homeUser),
                  ),
                  (route) => false,
                );
              },
              child: Text(tr(context, 'ok')),
            ),
          ],
        );
      },
    );
  }

  Future<void> finishRegister() async {
    if (!hasSignature) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'signature_required'))),
      );
      return;
    }

    if (isSubmitting) {
      return;
    }

    final signedAt = DateTime.now();
    final registerKey = buildRegisterKey(
      projectName: widget.projectName,
      buildingName: widget.buildingName,
      apartmentName: widget.apartmentName,
      roomName: widget.roomName,
      registerName: widget.registerName,
    );

    if (widget.taskToComplete != null) {
      final currentTaskDoc = await firestore
          .collection('work_tasks')
          .doc(widget.taskToComplete!.id)
          .get();
      if ((currentTaskDoc.data()?['completed'] as bool? ?? false) == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'task_already_completed'))),
          );
        }
        return;
      }
    }

    setState(() {
      isSubmitting = true;
    });

    final signatureBytes = await captureSignatureBytes();
    try {
      await (() async {
        final uploadedPhotos = await uploadRegisterPhotos(
          registerKey: registerKey,
          signedAt: signedAt,
          photoItems: widget.photoItems,
        );
        final uploadedSignature = await uploadRegisterSignature(
          registerKey: registerKey,
          signedAt: signedAt,
          signatureBytes: signatureBytes,
        );

        submittedRegisterKeys.add(registerKey);
        await firestore.collection('register_submissions').add({
          'projectName': widget.projectName,
          'buildingName': widget.buildingName,
          'apartmentName': widget.apartmentName,
          'roomName': widget.roomName,
          'registerName': widget.registerName,
          'signedBy': currentSessionUsername.isEmpty
              ? 'unknown'
              : currentSessionUsername,
          'signedAt': Timestamp.fromDate(signedAt),
          'registerKey': registerKey,
          'createdAt': Timestamp.now(),
          'photoCount': uploadedPhotos.length,
          'photos': uploadedPhotos,
          'signature': uploadedSignature,
        });
        if (widget.taskToComplete != null) {
          final completed = await completeWorkTask(
            task: widget.taskToComplete!,
            completedBy: currentSessionUsername.isEmpty
                ? 'unknown'
                : currentSessionUsername,
            signature: uploadedSignature,
          );
          if (!completed) {
            throw StateError('task_already_completed');
          }
        }
      })().timeout(const Duration(seconds: 20));
    } on FirebaseException {
      final pendingSubmission = buildPendingSubmission(
        signedAt: signedAt,
        registerKey: registerKey,
        signatureBytes: signatureBytes,
      );
      await enqueuePendingRegisterSubmission(pendingSubmission);
      await showRegisterCompletionDialog(
        signedAt: signedAt,
        offlineSaved: true,
      );
      return;
    } on StateError catch (error) {
      if (error.message == 'task_already_completed') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'task_already_completed'))),
          );
        }
        return;
      }
      rethrow;
    } catch (_) {
      final pendingSubmission = buildPendingSubmission(
        signedAt: signedAt,
        registerKey: registerKey,
        signatureBytes: signatureBytes,
      );
      await enqueuePendingRegisterSubmission(pendingSubmission);
      await showRegisterCompletionDialog(
        signedAt: signedAt,
        offlineSaved: true,
      );
      return;
    } finally {
      if (mounted) {
        setState(() {
          isSubmitting = false;
        });
      }
    }

    if (!mounted) {
      return;
    }

    await showRegisterCompletionDialog(signedAt: signedAt, offlineSaved: false);
  }

  void addPoint(Offset globalPosition) {
    final renderBox =
        signaturePadKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }

    final localPosition = renderBox.globalToLocal(globalPosition);
    setState(() {
      points.add(localPosition);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'signature'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InfoCard(
              projectName: widget.projectName,
              buildingName: widget.buildingName,
              apartmentName: widget.apartmentName,
              roomName: widget.roomName,
              registerName: widget.registerName,
            ),
            const SizedBox(height: 16),
            Text(
              tr(context, 'signature_instruction'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: RepaintBoundary(
                key: signaturePadKey,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.teal, width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: GestureDetector(
                      onPanStart: (details) {
                        addPoint(details.globalPosition);
                      },
                      onPanUpdate: (details) {
                        addPoint(details.globalPosition);
                      },
                      onPanEnd: (_) {
                        setState(() {
                          points.add(null);
                        });
                      },
                      child: CustomPaint(
                        painter: SignaturePainter(points),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (isSubmitting) ...[
              Text(
                tr(context, 'uploading_photos'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 8),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 28),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: isSubmitting ? null : clearSignature,
                      child: Text(tr(context, 'clear_signature')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: isSubmitting ? null : finishRegister,
                      child: Text(tr(context, 'close_register')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SignaturePainter extends CustomPainter {
  SignaturePainter(this.points);

  final List<Offset?> points;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black87
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    for (var index = 0; index < points.length - 1; index++) {
      final current = points[index];
      final next = points[index + 1];

      if (current != null && next != null) {
        canvas.drawLine(current, next, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant SignaturePainter oldDelegate) {
    return true;
  }
}

String buildRegisterKey({
  required String projectName,
  required String buildingName,
  required String apartmentName,
  required String roomName,
  required String registerName,
}) {
  return <String>[
    projectName.trim(),
    buildingName.trim(),
    apartmentName.trim(),
    roomName.trim(),
    registerName.trim(),
  ].join('|');
}

Future<List<Map<String, dynamic>>> uploadRegisterPhotoPayloads({
  required String registerKey,
  required DateTime signedAt,
  required List<Map<String, dynamic>> photoPayloads,
}) async {
  final uploads = <Map<String, dynamic>>[];
  final signedAtLabel = signedAt.toIso8601String().replaceAll(':', '-');
  final registerFolder = slugifyForStorage(registerKey);

  for (var index = 0; index < photoPayloads.length; index++) {
    final payload = photoPayloads[index];
    final bytes = payload['bytes'] as Uint8List?;
    if (bytes == null || bytes.isEmpty) {
      continue;
    }

    final labelHr = payload['labelHr']?.toString() ?? '';
    final labelDe = payload['labelDe']?.toString() ?? '';
    final itemName = slugifyForStorage(labelHr);
    final fileName = '${signedAtLabel}_${index + 1}_$itemName.jpg';
    final path = 'register_photos/$registerFolder/$fileName';

    final ref = firebaseStorage.ref().child(path);
    await ref.putData(
      bytes,
      SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: <String, String>{
          'registerKey': registerKey,
          'labelHr': labelHr,
          'labelDe': labelDe,
        },
      ),
    );

    final downloadUrl = await ref.getDownloadURL();
    uploads.add(<String, dynamic>{
      'labelHr': labelHr,
      'labelDe': labelDe,
      'path': path,
      'downloadUrl': downloadUrl,
      'sizeBytes': bytes.length,
      'uploadedAt': Timestamp.now(),
    });
  }

  return uploads;
}

Future<List<Map<String, dynamic>>> uploadRegisterPhotos({
  required String registerKey,
  required DateTime signedAt,
  required List<PhotoItem> photoItems,
}) async {
  return uploadRegisterPhotoPayloads(
    registerKey: registerKey,
    signedAt: signedAt,
    photoPayloads: photoItems
        .map(
          (item) => <String, dynamic>{
            'labelHr': item.titleHr,
            'labelDe': item.titleDe,
            'bytes': item.previewBytes,
          },
        )
        .toList(),
  );
}

Future<Map<String, dynamic>?> uploadRegisterSignature({
  required String registerKey,
  required DateTime signedAt,
  required Uint8List? signatureBytes,
}) async {
  if (signatureBytes == null || signatureBytes.isEmpty) {
    return null;
  }

  final signedAtLabel = signedAt.toIso8601String().replaceAll(':', '-');
  final registerFolder = slugifyForStorage(registerKey);
  final path =
      'register_signatures/$registerFolder/${signedAtLabel}_signature.png';

  final ref = firebaseStorage.ref().child(path);
  await ref.putData(
    signatureBytes,
    SettableMetadata(
      contentType: 'image/png',
      customMetadata: <String, String>{'registerKey': registerKey},
    ),
  );

  final downloadUrl = await ref.getDownloadURL();
  return <String, dynamic>{
    'labelHr': 'Potpis',
    'labelDe': 'Unterschrift',
    'path': path,
    'downloadUrl': downloadUrl,
    'sizeBytes': signatureBytes.length,
    'uploadedAt': Timestamp.now(),
  };
}

Future<Map<String, dynamic>?> uploadWorkTaskSignature({
  required WorkTaskRecord task,
  required DateTime signedAt,
  required Uint8List? signatureBytes,
}) async {
  if (signatureBytes == null || signatureBytes.isEmpty) {
    return null;
  }

  final signedAtLabel = signedAt.toIso8601String().replaceAll(':', '-');
  final taskFolder = slugifyForStorage(task.id);
  final path =
      'work_task_signatures/$taskFolder/${signedAtLabel}_signature.png';

  final ref = firebaseStorage.ref().child(path);
  await ref.putData(
    signatureBytes,
    SettableMetadata(
      contentType: 'image/png',
      customMetadata: <String, String>{
        'workTaskId': task.id,
        'taskLabel': task.taskLabel,
      },
    ),
  );

  final downloadUrl = await ref.getDownloadURL();
  return <String, dynamic>{
    'labelHr': 'Potpis',
    'labelDe': 'Unterschrift',
    'path': path,
    'downloadUrl': downloadUrl,
    'sizeBytes': signatureBytes.length,
    'uploadedAt': Timestamp.now(),
  };
}

Map<String, dynamic>? buildInlineWorkTaskSignaturePayload({
  required Uint8List? signatureBytes,
}) {
  if (signatureBytes == null || signatureBytes.isEmpty) {
    return null;
  }

  return <String, dynamic>{
    'labelHr': 'Potpis',
    'labelDe': 'Unterschrift',
    'inlineBase64': base64Encode(signatureBytes),
    'sizeBytes': signatureBytes.length,
    'uploadedAt': Timestamp.now(),
  };
}

List<PendingRegisterSubmission> parsePendingRegisterSubmissions(
  String rawJson,
) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) {
    return <PendingRegisterSubmission>[];
  }

  return decoded
      .whereType<Map>()
      .map(
        (entry) => PendingRegisterSubmission.fromMap(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        ),
      )
      .toList();
}

List<PendingApartmentDocumentSubmission>
parsePendingApartmentDocumentSubmissions(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) {
    return <PendingApartmentDocumentSubmission>[];
  }

  return decoded
      .whereType<Map>()
      .map(
        (entry) => PendingApartmentDocumentSubmission.fromMap(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        ),
      )
      .toList();
}

Future<List<PendingRegisterSubmission>> loadPendingRegisterSubmissions() async {
  final prefs = await SharedPreferences.getInstance();
  final rawJson = prefs.getString(pendingRegisterSubmissionsKey);
  if (rawJson == null || rawJson.trim().isEmpty) {
    return <PendingRegisterSubmission>[];
  }

  try {
    return parsePendingRegisterSubmissions(rawJson);
  } catch (_) {
    return <PendingRegisterSubmission>[];
  }
}

Future<List<PendingApartmentDocumentSubmission>>
loadPendingApartmentDocumentSubmissions() async {
  final prefs = await SharedPreferences.getInstance();
  final rawJson = prefs.getString(pendingApartmentDocumentSubmissionsKey);
  if (rawJson == null || rawJson.trim().isEmpty) {
    return <PendingApartmentDocumentSubmission>[];
  }

  try {
    return parsePendingApartmentDocumentSubmissions(rawJson);
  } catch (_) {
    return <PendingApartmentDocumentSubmission>[];
  }
}

Future<void> savePendingRegisterSubmissions(
  List<PendingRegisterSubmission> submissions,
) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    pendingRegisterSubmissionsKey,
    jsonEncode(submissions.map((entry) => entry.toMap()).toList()),
  );
}

Future<void> savePendingApartmentDocumentSubmissions(
  List<PendingApartmentDocumentSubmission> submissions,
) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    pendingApartmentDocumentSubmissionsKey,
    jsonEncode(submissions.map((entry) => entry.toMap()).toList()),
  );
}

Future<void> enqueuePendingRegisterSubmission(
  PendingRegisterSubmission submission,
) async {
  final submissions = await loadPendingRegisterSubmissions();
  submissions.removeWhere(
    (entry) => entry.registerKey == submission.registerKey,
  );
  submissions.add(submission);
  await savePendingRegisterSubmissions(submissions);
}

Future<void> enqueuePendingApartmentDocumentSubmission(
  PendingApartmentDocumentSubmission submission,
) async {
  final submissions = await loadPendingApartmentDocumentSubmissions();
  submissions.removeWhere((entry) => entry.documentId == submission.documentId);
  submissions.add(submission);
  await savePendingApartmentDocumentSubmissions(submissions);
}

Future<void> uploadPendingApartmentDocumentSubmission(
  PendingApartmentDocumentSubmission submission,
) async {
  final sanitizedFileName = sanitizeSharedDocumentFileName(submission.fileName);
  final storagePath =
      'apartment_documents/${submission.projectId}/${submission.buildingId}/${submission.wohnungId}/${submission.documentId}-$sanitizedFileName';
  final ref = firebaseStorage.ref().child(storagePath);
  await ref.putData(
    Uint8List.fromList(base64Decode(submission.bytesBase64)),
    SettableMetadata(
      contentType: 'application/pdf',
      customMetadata: <String, String>{
        'projectId': submission.projectId,
        'buildingId': submission.buildingId,
        'wohnungId': submission.wohnungId,
      },
    ),
  );
  final downloadUrl = await ref.getDownloadURL();

  await firestore
      .collection('apartment_documents')
      .doc(submission.documentId)
      .set({
        'projectId': submission.projectId,
        'projectName': submission.projectName,
        'buildingId': submission.buildingId,
        'buildingName': submission.buildingName,
        'wohnungId': submission.wohnungId,
        'apartmentName': submission.apartmentName,
        'fileName': sanitizedFileName,
        'storagePath': storagePath,
        'downloadUrl': downloadUrl,
        'uploadedBy': submission.uploadedBy,
        'uploadedAt': Timestamp.fromDate(submission.queuedAt),
      }, SetOptions(merge: true));
}

Future<int> syncPendingRegisters() async {
  if (pendingRegisterSyncInProgress) {
    return 0;
  }

  pendingRegisterSyncInProgress = true;
  try {
    final submissions = await loadPendingRegisterSubmissions();
    if (submissions.isEmpty) {
      return 0;
    }

    final remaining = <PendingRegisterSubmission>[];
    var syncedCount = 0;

    for (final submission in submissions) {
      try {
        final uploadedPhotos = await uploadRegisterPhotoPayloads(
          registerKey: submission.registerKey,
          signedAt: submission.signedAt,
          photoPayloads: submission.photos
              .map(
                (photo) => <String, dynamic>{
                  'labelHr': photo['labelHr']?.toString() ?? '',
                  'labelDe': photo['labelDe']?.toString() ?? '',
                  'bytes': Uint8List.fromList(
                    base64Decode(photo['bytesBase64']?.toString() ?? ''),
                  ),
                },
              )
              .toList(),
        );
        final uploadedSignature = await uploadRegisterSignature(
          registerKey: submission.registerKey,
          signedAt: submission.signedAt,
          signatureBytes: submission.signatureBytesBase64 == null
              ? null
              : Uint8List.fromList(
                  base64Decode(submission.signatureBytesBase64!),
                ),
        );

        submittedRegisterKeys.add(submission.registerKey);
        await firestore.collection('register_submissions').add({
          'projectName': submission.projectName,
          'buildingName': submission.buildingName,
          'apartmentName': submission.apartmentName,
          'roomName': submission.roomName,
          'registerName': submission.registerName,
          'signedBy': submission.signedBy,
          'signedAt': Timestamp.fromDate(submission.signedAt),
          'registerKey': submission.registerKey,
          'createdAt': Timestamp.now(),
          'photoCount': uploadedPhotos.length,
          'photos': uploadedPhotos,
          'signature': uploadedSignature,
        });

        syncedCount += 1;
      } catch (_) {
        remaining.add(submission);
      }
    }

    await savePendingRegisterSubmissions(remaining);
    return syncedCount;
  } finally {
    pendingRegisterSyncInProgress = false;
  }
}

Future<int> syncPendingApartmentDocuments() async {
  if (pendingApartmentDocumentSyncInProgress) {
    return 0;
  }

  pendingApartmentDocumentSyncInProgress = true;
  try {
    final submissions = await loadPendingApartmentDocumentSubmissions();
    if (submissions.isEmpty) {
      return 0;
    }

    final remaining = <PendingApartmentDocumentSubmission>[];
    var syncedCount = 0;

    for (final submission in submissions) {
      try {
        await uploadPendingApartmentDocumentSubmission(submission);
        syncedCount += 1;
      } catch (_) {
        remaining.add(submission);
      }
    }

    await savePendingApartmentDocumentSubmissions(remaining);
    return syncedCount;
  } finally {
    pendingApartmentDocumentSyncInProgress = false;
  }
}

void ensurePendingRegisterSyncStarted() {
  pendingRegisterSyncTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
    syncPendingRegisters();
    syncPendingApartmentDocuments();
  });
}

String buildRegisterExportCsv(List<RegisterSubmissionRecord> submissions) {
  final rows = <List<String>>[
    <String>[
      'project',
      'building',
      'apartment',
      'room',
      'register',
      'signed_by',
      'signed_at',
      'photo_count',
      'register_photo',
      'extra_photo',
    ],
    ...submissions.map((submission) {
      final registerPhoto = submission.photos.firstWhere(
        (photo) =>
            (photo['labelHr'] as String? ?? '') == 'Fotografija registra',
        orElse: () => <String, dynamic>{},
      );
      final extraPhoto = submission.photos.firstWhere(
        (photo) => (photo['labelHr'] as String? ?? '') == 'Dodatna fotografija',
        orElse: () => <String, dynamic>{},
      );

      return <String>[
        submission.projectName,
        submission.buildingName,
        submission.apartmentName,
        submission.roomName,
        submission.registerName,
        submission.signedBy,
        submission.signedAt.toIso8601String(),
        submission.photoCount.toString(),
        registerPhoto['downloadUrl']?.toString() ?? '',
        extraPhoto['downloadUrl']?.toString() ?? '',
      ];
    }),
  ];

  return rows.map((row) => row.map(_escapeCsvValue).join(',')).join('\n');
}

ExportActivityRecord mapRegisterSubmissionToExportActivity(
  RegisterSubmissionRecord submission,
) {
  return ExportActivityRecord(
    id: submission.id,
    projectName: submission.projectName.trim(),
    buildingName: submission.buildingName.trim(),
    apartmentName: submission.apartmentName.trim(),
    roomName: submission.roomName.trim(),
    activityType: 'register',
    activityGroup: submission.registerName.trim(),
    activityLabel: submission.registerName.trim(),
    signedBy: submission.signedBy.trim(),
    signedAt: submission.signedAt,
    photoCount: submission.photoCount,
    photos: submission.photos,
    signature: submission.signature,
  );
}

ExportActivityRecord mapWorkTaskToExportActivity(WorkTaskRecord task) {
  return ExportActivityRecord(
    id: task.id,
    projectName: task.projectName.trim(),
    buildingName: task.buildingName.trim(),
    apartmentName: task.apartmentName.trim(),
    roomName: '',
    activityType: 'task',
    activityGroup: task.taskGroup.trim(),
    activityLabel: task.taskLabel.trim(),
    signedBy: task.completedBy.trim(),
    signedAt: task.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    photoCount: 0,
    photos: const <Map<String, dynamic>>[],
    signature: task.signature,
  );
}

List<ExportActivityRecord> buildCombinedExportActivities({
  required List<RegisterSubmissionRecord> submissions,
  required List<WorkTaskRecord> completedTasks,
}) {
  final activities = <ExportActivityRecord>[
    ...submissions.map(mapRegisterSubmissionToExportActivity),
    ...completedTasks
        .where((task) => task.completed)
        .map(mapWorkTaskToExportActivity),
  ];

  activities.sort((a, b) => b.signedAt.compareTo(a.signedAt));
  return activities;
}

String buildActivitiesExportCsv(List<ExportActivityRecord> activities) {
  final rows = <List<String>>[
    <String>[
      'project',
      'building',
      'apartment',
      'room',
      'activity_type',
      'activity_group',
      'activity_label',
      'signed_by',
      'signed_at',
      'photo_count',
      'register_photo',
      'extra_photo',
      'signature',
    ],
    ...activities.map((activity) {
      final registerPhoto = activity.photos.firstWhere(
        (photo) =>
            (photo['labelHr'] as String? ?? '') == 'Fotografija registra',
        orElse: () => <String, dynamic>{},
      );
      final extraPhoto = activity.photos.firstWhere(
        (photo) => (photo['labelHr'] as String? ?? '') == 'Dodatna fotografija',
        orElse: () => <String, dynamic>{},
      );

      return <String>[
        activity.projectName,
        activity.buildingName,
        activity.apartmentName,
        activity.roomName,
        activity.activityType,
        activity.activityGroup,
        activity.activityLabel,
        activity.signedBy,
        activity.signedAt.toIso8601String(),
        activity.photoCount.toString(),
        registerPhoto['downloadUrl']?.toString() ?? '',
        extraPhoto['downloadUrl']?.toString() ?? '',
        activity.signature?['downloadUrl']?.toString() ??
            activity.signature?['path']?.toString() ??
            '',
      ];
    }),
  ];

  return rows.map((row) => row.map(_escapeCsvValue).join(',')).join('\n');
}

String _escapeCsvValue(String value) {
  final escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}

String exportText(AppLanguage language, String key) {
  const values = <String, Map<AppLanguage, String>>{
    'sheet_signatures': {
      AppLanguage.hr: 'Potpisi',
      AppLanguage.de: 'Unterschriften',
      AppLanguage.en: 'Signatures',
    },
    'sheet_orders': {
      AppLanguage.hr: 'Narudzbe',
      AppLanguage.de: 'Bestellungen',
      AppLanguage.en: 'Orders',
    },
    'sheet_summary': {
      AppLanguage.hr: 'Pregled',
      AppLanguage.de: 'Ubersicht',
      AppLanguage.en: 'Overview',
    },
    'project': {
      AppLanguage.hr: 'Projekt',
      AppLanguage.de: 'Projekt',
      AppLanguage.en: 'Project',
    },
    'building': {
      AppLanguage.hr: 'Zgrada',
      AppLanguage.de: 'Gebaude',
      AppLanguage.en: 'Building',
    },
    'apartment': {
      AppLanguage.hr: 'Stan',
      AppLanguage.de: 'Wohnung',
      AppLanguage.en: 'Apartment',
    },
    'room': {
      AppLanguage.hr: 'Prostorija',
      AppLanguage.de: 'Raum',
      AppLanguage.en: 'Room',
    },
    'register': {
      AppLanguage.hr: 'Registar',
      AppLanguage.de: 'Register',
      AppLanguage.en: 'Register',
    },
    'signed_by': {
      AppLanguage.hr: 'Potpisao',
      AppLanguage.de: 'Unterschrieben von',
      AppLanguage.en: 'Signed by',
    },
    'signature_date': {
      AppLanguage.hr: 'Datum potpisa',
      AppLanguage.de: 'Unterschriftsdatum',
      AppLanguage.en: 'Signature date',
    },
    'signature_time': {
      AppLanguage.hr: 'Vrijeme potpisa',
      AppLanguage.de: 'Unterschriftszeit',
      AppLanguage.en: 'Signature time',
    },
    'photo_count': {
      AppLanguage.hr: 'Broj fotografija',
      AppLanguage.de: 'Anzahl Fotos',
      AppLanguage.en: 'Photo count',
    },
    'register_photo': {
      AppLanguage.hr: 'Fotografija registra',
      AppLanguage.de: 'Registerfoto',
      AppLanguage.en: 'Register photo',
    },
    'extra_photo': {
      AppLanguage.hr: 'Dodatna fotografija',
      AppLanguage.de: 'Zusatzfoto',
      AppLanguage.en: 'Extra photo',
    },
    'signature': {
      AppLanguage.hr: 'Potpis',
      AppLanguage.de: 'Unterschrift',
      AppLanguage.en: 'Signature',
    },
    'type': {
      AppLanguage.hr: 'Tip',
      AppLanguage.de: 'Typ',
      AppLanguage.en: 'Type',
    },
    'task_group': {
      AppLanguage.hr: 'Grupa posla',
      AppLanguage.de: 'Arbeitsgruppe',
      AppLanguage.en: 'Task group',
    },
    'item': {
      AppLanguage.hr: 'Stavka',
      AppLanguage.de: 'Eintrag',
      AppLanguage.en: 'Item',
    },
    'status': {
      AppLanguage.hr: 'Status',
      AppLanguage.de: 'Status',
      AppLanguage.en: 'Status',
    },
    'send_slot': {
      AppLanguage.hr: 'Termin slanja',
      AppLanguage.de: 'Versandtermin',
      AppLanguage.en: 'Send slot',
    },
    'created_date': {
      AppLanguage.hr: 'Kreirano datum',
      AppLanguage.de: 'Erstellt am',
      AppLanguage.en: 'Created date',
    },
    'created_time': {
      AppLanguage.hr: 'Kreirano vrijeme',
      AppLanguage.de: 'Erstellt um',
      AppLanguage.en: 'Created time',
    },
    'sent_date': {
      AppLanguage.hr: 'Poslano datum',
      AppLanguage.de: 'Gesendet am',
      AppLanguage.en: 'Sent date',
    },
    'sent_time': {
      AppLanguage.hr: 'Poslano vrijeme',
      AppLanguage.de: 'Gesendet um',
      AppLanguage.en: 'Sent time',
    },
    'ordered_by': {
      AppLanguage.hr: 'Poslao',
      AppLanguage.de: 'Bestellt von',
      AppLanguage.en: 'Ordered by',
    },
    'article_number': {
      AppLanguage.hr: 'Artikelnummer',
      AppLanguage.de: 'Artikelnummer',
      AppLanguage.en: 'Article number',
    },
    'name': {
      AppLanguage.hr: 'Naziv',
      AppLanguage.de: 'Bezeichnung',
      AppLanguage.en: 'Name',
    },
    'quantity': {
      AppLanguage.hr: 'Kolicina',
      AppLanguage.de: 'Menge',
      AppLanguage.en: 'Quantity',
    },
    'supplier': {
      AppLanguage.hr: 'Dobavljac',
      AppLanguage.de: 'Lieferant',
      AppLanguage.en: 'Supplier',
    },
    'category': {
      AppLanguage.hr: 'Kategorija',
      AppLanguage.de: 'Kategorie',
      AppLanguage.en: 'Category',
    },
    'note': {
      AppLanguage.hr: 'Napomena',
      AppLanguage.de: 'Notiz',
      AppLanguage.en: 'Note',
    },
    'exported': {
      AppLanguage.hr: 'Izvezeno',
      AppLanguage.de: 'Exportiert',
      AppLanguage.en: 'Exported',
    },
    'total_tasks': {
      AppLanguage.hr: 'Ukupno zadataka',
      AppLanguage.de: 'Aufgaben gesamt',
      AppLanguage.en: 'Total tasks',
    },
    'completed': {
      AppLanguage.hr: 'Gotovo',
      AppLanguage.de: 'Erledigt',
      AppLanguage.en: 'Completed',
    },
    'apartments': {
      AppLanguage.hr: 'Stanovi',
      AppLanguage.de: 'Wohnungen',
      AppLanguage.en: 'Apartments',
    },
    'completion': {
      AppLanguage.hr: 'Dovrsenost',
      AppLanguage.de: 'Fortschritt',
      AppLanguage.en: 'Completion',
    },
    'green_done': {
      AppLanguage.hr: 'Zeleno = gotovo',
      AppLanguage.de: 'Grun = erledigt',
      AppLanguage.en: 'Green = completed',
    },
    'red_pending': {
      AppLanguage.hr: 'Crveno = nije gotovo',
      AppLanguage.de: 'Rot = nicht erledigt',
      AppLanguage.en: 'Red = not completed',
    },
    'grey_missing': {
      AppLanguage.hr: 'Sivo = nema zadatka',
      AppLanguage.de: 'Grau = keine Aufgabe',
      AppLanguage.en: 'Grey = no task',
    },
    'building_completion': {
      AppLanguage.hr: 'Dovrsenost zgrade',
      AppLanguage.de: 'Gebaudefortschritt',
      AppLanguage.en: 'Building completion',
    },
    'floor': {
      AppLanguage.hr: 'Kat',
      AppLanguage.de: 'Etage',
      AppLanguage.en: 'Floor',
    },
    'file_signatures': {
      AppLanguage.hr: 'dhego_potpisi.xlsx',
      AppLanguage.de: 'dhego_unterschriften.xlsx',
      AppLanguage.en: 'dhego_signatures.xlsx',
    },
    'file_signatures_and_tasks': {
      AppLanguage.hr: 'dhego_potpisi_i_poslovi.xlsx',
      AppLanguage.de: 'dhego_unterschriften_und_aufgaben.xlsx',
      AppLanguage.en: 'dhego_signatures_and_tasks.xlsx',
    },
    'file_orders': {
      AppLanguage.hr: 'dhego_narudzbe.xlsx',
      AppLanguage.de: 'dhego_bestellungen.xlsx',
      AppLanguage.en: 'dhego_orders.xlsx',
    },
    'file_project_export_suffix': {
      AppLanguage.hr: 'projekt_export',
      AppLanguage.de: 'projekt_export',
      AppLanguage.en: 'project_export',
    },
  };

  return values[key]?[language] ?? values[key]?[AppLanguage.hr] ?? key;
}

Future<void> downloadRegisterExportExcel(
  List<RegisterSubmissionRecord> submissions,
  AppLanguage language,
) async {
  final excel = Excel.createExcel();
  final sheet = excel[exportText(language, 'sheet_signatures')];

  sheet.appendRow(<CellValue>[
    TextCellValue(exportText(language, 'project')),
    TextCellValue(exportText(language, 'building')),
    TextCellValue(exportText(language, 'apartment')),
    TextCellValue(exportText(language, 'room')),
    TextCellValue(exportText(language, 'register')),
    TextCellValue(exportText(language, 'signed_by')),
    TextCellValue(exportText(language, 'signature_date')),
    TextCellValue(exportText(language, 'signature_time')),
    TextCellValue(exportText(language, 'photo_count')),
    TextCellValue(exportText(language, 'register_photo')),
    TextCellValue(exportText(language, 'extra_photo')),
  ]);

  for (final submission in submissions) {
    final registerPhoto = submission.photos.firstWhere(
      (photo) => (photo['labelHr'] as String? ?? '') == 'Fotografija registra',
      orElse: () => <String, dynamic>{},
    );
    final extraPhoto = submission.photos.firstWhere(
      (photo) => (photo['labelHr'] as String? ?? '') == 'Dodatna fotografija',
      orElse: () => <String, dynamic>{},
    );

    sheet.appendRow(<CellValue>[
      TextCellValue(submission.projectName),
      TextCellValue(submission.buildingName),
      TextCellValue(submission.apartmentName),
      TextCellValue(submission.roomName),
      TextCellValue(submission.registerName),
      TextCellValue(submission.signedBy),
      TextCellValue(formatDate(submission.signedAt)),
      TextCellValue(formatTime(submission.signedAt)),
      IntCellValue(submission.photoCount),
      TextCellValue(registerPhoto['downloadUrl']?.toString() ?? ''),
      TextCellValue(extraPhoto['downloadUrl']?.toString() ?? ''),
    ]);
  }

  final bytes = excel.encode();
  if (bytes == null) {
    return;
  }

  if (kIsWeb) {
    final blob = html.Blob(<dynamic>[
      Uint8List.fromList(bytes),
    ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', exportText(language, 'file_signatures'))
      ..click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    return;
  }

  await shareExcelFileOnDevice(
    Uint8List.fromList(bytes),
    exportText(language, 'file_signatures'),
  );
}

Future<void> downloadActivitiesExportExcel(
  List<ExportActivityRecord> activities,
  AppLanguage language,
) async {
  final excel = Excel.createExcel();
  final sheet = excel[exportText(language, 'sheet_signatures')];

  sheet.appendRow(<CellValue>[
    TextCellValue(exportText(language, 'project')),
    TextCellValue(exportText(language, 'building')),
    TextCellValue(exportText(language, 'apartment')),
    TextCellValue(exportText(language, 'room')),
    TextCellValue(exportText(language, 'type')),
    TextCellValue(exportText(language, 'task_group')),
    TextCellValue(exportText(language, 'item')),
    TextCellValue(exportText(language, 'signed_by')),
    TextCellValue(exportText(language, 'signature_date')),
    TextCellValue(exportText(language, 'signature_time')),
    TextCellValue(exportText(language, 'photo_count')),
    TextCellValue(exportText(language, 'register_photo')),
    TextCellValue(exportText(language, 'extra_photo')),
    TextCellValue(exportText(language, 'signature')),
  ]);

  for (final activity in activities) {
    final registerPhoto = activity.photos.firstWhere(
      (photo) => (photo['labelHr'] as String? ?? '') == 'Fotografija registra',
      orElse: () => <String, dynamic>{},
    );
    final extraPhoto = activity.photos.firstWhere(
      (photo) => (photo['labelHr'] as String? ?? '') == 'Dodatna fotografija',
      orElse: () => <String, dynamic>{},
    );

    sheet.appendRow(<CellValue>[
      TextCellValue(activity.projectName),
      TextCellValue(activity.buildingName),
      TextCellValue(activity.apartmentName),
      TextCellValue(activity.roomName),
      TextCellValue(activity.activityType),
      TextCellValue(activity.activityGroup),
      TextCellValue(activity.activityLabel),
      TextCellValue(activity.signedBy),
      TextCellValue(formatDate(activity.signedAt)),
      TextCellValue(formatTime(activity.signedAt)),
      IntCellValue(activity.photoCount),
      TextCellValue(registerPhoto['downloadUrl']?.toString() ?? ''),
      TextCellValue(extraPhoto['downloadUrl']?.toString() ?? ''),
      TextCellValue(
        activity.signature?['downloadUrl']?.toString() ??
            activity.signature?['path']?.toString() ??
            '',
      ),
    ]);
  }

  final bytes = excel.encode();
  if (bytes == null) {
    return;
  }

  if (kIsWeb) {
    final blob = html.Blob(<dynamic>[
      Uint8List.fromList(bytes),
    ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute(
        'download',
        exportText(language, 'file_signatures_and_tasks'),
      )
      ..click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    return;
  }

  await shareExcelFileOnDevice(
    Uint8List.fromList(bytes),
    exportText(language, 'file_signatures_and_tasks'),
  );
}

Future<void> downloadOrderRequestsExportExcel(
  List<OrderRequestRecord> orders,
  AppLanguage language,
) async {
  final excel = Excel.createExcel();
  final sheet = excel[exportText(language, 'sheet_orders')];

  sheet.appendRow(<CellValue>[
    TextCellValue(exportText(language, 'project')),
    TextCellValue(exportText(language, 'building')),
    TextCellValue(exportText(language, 'status')),
    TextCellValue(exportText(language, 'send_slot')),
    TextCellValue(exportText(language, 'created_date')),
    TextCellValue(exportText(language, 'created_time')),
    TextCellValue(exportText(language, 'sent_date')),
    TextCellValue(exportText(language, 'sent_time')),
    TextCellValue(exportText(language, 'ordered_by')),
    TextCellValue(exportText(language, 'article_number')),
    TextCellValue(exportText(language, 'name')),
    TextCellValue(exportText(language, 'quantity')),
    TextCellValue(exportText(language, 'supplier')),
    TextCellValue(exportText(language, 'category')),
    TextCellValue(exportText(language, 'note')),
  ]);

  for (final order in orders) {
    final items = order.items.isEmpty
        ? const <Map<String, dynamic>>[<String, dynamic>{}]
        : order.items;

    for (final item in items) {
      final articleNumber = item['articleNumber']?.toString().trim() ?? '';
      final name = item['name']?.toString().trim() ?? '';
      final quantity = item['quantity']?.toString().trim() ?? '';
      final supplier = item['supplier']?.toString().trim() ?? '';
      final category = item['category']?.toString().trim() ?? '';

      sheet.appendRow(<CellValue>[
        TextCellValue(order.projectName),
        TextCellValue(order.buildingName),
        TextCellValue(order.status),
        TextCellValue(order.scheduledSlot),
        TextCellValue(
          order.createdAt == null ? '' : formatDate(order.createdAt!),
        ),
        TextCellValue(
          order.createdAt == null ? '' : formatTime(order.createdAt!),
        ),
        TextCellValue(order.sentAt == null ? '' : formatDate(order.sentAt!)),
        TextCellValue(order.sentAt == null ? '' : formatTime(order.sentAt!)),
        TextCellValue(order.orderedBy),
        TextCellValue(articleNumber),
        TextCellValue(name),
        TextCellValue(quantity),
        TextCellValue(supplier),
        TextCellValue(category),
        TextCellValue(order.note),
      ]);
    }
  }

  final bytes = excel.encode();
  if (bytes == null) {
    return;
  }

  if (kIsWeb) {
    final blob = html.Blob(<dynamic>[
      Uint8List.fromList(bytes),
    ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', exportText(language, 'file_orders'))
      ..click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    return;
  }

  await shareExcelFileOnDevice(
    Uint8List.fromList(bytes),
    exportText(language, 'file_orders'),
  );
}

Future<void> downloadProjectWorkbookExportExcel(
  ProjectRecord project,
  AppLanguage language,
) async {
  final buildingsSnapshot = await firestore
      .collection('buildings')
      .where('projectId', isEqualTo: project.id)
      .get();
  final buildings =
      buildingsSnapshot.docs
          .map(
            (doc) => BuildingRecord(
              id: doc.id,
              projectId: doc.data()['projectId']?.toString() ?? '',
              name: doc.data()['name']?.toString() ?? '',
              active: doc.data()['active'] as bool? ?? true,
              workTaskTotalPoints: readIntValue(
                doc.data()['workTaskTotalPoints'],
              ),
              workTaskCompletedPoints: readIntValue(
                doc.data()['workTaskCompletedPoints'],
              ),
              workTaskProgressPercent: readIntValue(
                doc.data()['workTaskProgressPercent'],
              ),
              createdAt: timestampToDateTime(doc.data()['createdAt']),
              updatedAt: timestampToDateTime(doc.data()['updatedAt']),
            ),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  final allWohnungs = <WohnungRecord>[];
  for (final building in buildings) {
    final wohnungSnapshot = await firestore
        .collection('wohnungs')
        .where('buildingId', isEqualTo: building.id)
        .get();
    allWohnungs.addAll(
      wohnungSnapshot.docs.map(
        (doc) => WohnungRecord(
          id: doc.id,
          buildingId: doc.data()['buildingId']?.toString() ?? '',
          name: doc.data()['name']?.toString() ?? '',
          active: doc.data()['active'] as bool? ?? true,
          checklistType: doc.data()['checklistType']?.toString() ?? '',
          workTaskTotalPoints: readIntValue(doc.data()['workTaskTotalPoints']),
          workTaskCompletedPoints: readIntValue(
            doc.data()['workTaskCompletedPoints'],
          ),
          workTaskProgressPercent: readIntValue(
            doc.data()['workTaskProgressPercent'],
          ),
        ),
      ),
    );
  }

  final taskSnapshot = await firestore
      .collection('work_tasks')
      .where('projectId', isEqualTo: project.id)
      .get();
  final activeTaskDocs = taskSnapshot.docs
      .where((doc) => doc.data()['active'] as bool? ?? true)
      .toList();

  final excel = Excel.createExcel();
  final defaultSheetName = excel.getDefaultSheet();
  final summarySheetName = exportText(language, 'sheet_summary');
  if (defaultSheetName != null && defaultSheetName != summarySheetName) {
    excel.rename(defaultSheetName, summarySheetName);
  }
  final summarySheet = excel[summarySheetName];
  final summaryHeaderStyle = CellStyle(
    bold: true,
    backgroundColorHex: ExcelColor.teal100,
  );
  final titleStyle = CellStyle(
    bold: true,
    fontSize: 14,
    backgroundColorHex: ExcelColor.teal200,
  );
  final completedStyle = CellStyle(
    backgroundColorHex: ExcelColor.lightGreen100,
  );
  final pendingStyle = CellStyle(backgroundColorHex: ExcelColor.red100);
  final missingStyle = CellStyle(backgroundColorHex: ExcelColor.grey300);

  summarySheet
      .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
      .value = TextCellValue(
    project.name,
  );
  summarySheet.merge(
    CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
    CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: 0),
  );
  summarySheet.setMergedCellStyle(
    CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
    titleStyle,
  );
  summarySheet
      .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1))
      .value = TextCellValue(
    exportText(language, 'exported'),
  );
  summarySheet
      .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 1))
      .value = TextCellValue(
    '${formatDate(DateTime.now())} ${formatTime(DateTime.now())}',
  );
  summarySheet
      .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 2))
      .value = TextCellValue(
    exportText(language, 'total_tasks'),
  );
  summarySheet
      .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 2))
      .value = IntCellValue(
    project.workTaskTotalPoints,
  );
  summarySheet
      .cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: 2))
      .value = TextCellValue(
    exportText(language, 'completed'),
  );
  summarySheet
      .cell(CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: 2))
      .value = IntCellValue(
    project.workTaskCompletedPoints,
  );
  summarySheet
      .cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: 2))
      .value = TextCellValue(
    '${project.workTaskProgressPercent}%',
  );

  const summaryHeaders = <String>[
    'building',
    'apartments',
    'total_tasks',
    'completed',
    'completion',
  ];
  for (var index = 0; index < summaryHeaders.length; index++) {
    final cell = summarySheet.cell(
      CellIndex.indexByColumnRow(columnIndex: index, rowIndex: 4),
    );
    cell.value = TextCellValue(exportText(language, summaryHeaders[index]));
    cell.cellStyle = summaryHeaderStyle;
  }

  var summaryRowIndex = 5;
  for (final building in buildings) {
    final buildingWohnungs = allWohnungs
        .where((wohnung) => wohnung.buildingId == building.id)
        .toList();
    summarySheet
        .cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: summaryRowIndex),
        )
        .value = TextCellValue(
      building.name,
    );
    summarySheet
        .cell(
          CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: summaryRowIndex),
        )
        .value = IntCellValue(
      buildingWohnungs.length,
    );
    summarySheet
        .cell(
          CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: summaryRowIndex),
        )
        .value = IntCellValue(
      building.workTaskTotalPoints,
    );
    summarySheet
        .cell(
          CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: summaryRowIndex),
        )
        .value = IntCellValue(
      building.workTaskCompletedPoints,
    );
    summarySheet
        .cell(
          CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: summaryRowIndex),
        )
        .value = TextCellValue(
      '${building.workTaskProgressPercent}%',
    );
    summaryRowIndex++;
  }

  summaryRowIndex += 1;
  final legend = <({String label, CellStyle style})>[
    (label: exportText(language, 'green_done'), style: completedStyle),
    (label: exportText(language, 'red_pending'), style: pendingStyle),
    (label: exportText(language, 'grey_missing'), style: missingStyle),
  ];
  for (var index = 0; index < legend.length; index++) {
    final legendCell = summarySheet.cell(
      CellIndex.indexByColumnRow(
        columnIndex: 0,
        rowIndex: summaryRowIndex + index,
      ),
    );
    legendCell.value = TextCellValue(legend[index].label);
    legendCell.cellStyle = legend[index].style;
  }

  summarySheet.setColumnWidth(0, 28);
  summarySheet.setColumnWidth(1, 12);
  summarySheet.setColumnWidth(2, 18);
  summarySheet.setColumnWidth(3, 12);
  summarySheet.setColumnWidth(4, 14);

  for (final building in buildings) {
    final buildingSheetName = buildProjectExportSheetName(
      building.name,
      existingNames: excel.tables.keys.toSet(),
    );
    final sheet = excel[buildingSheetName];
    final buildingWohnungs =
        allWohnungs
            .where(
              (wohnung) => wohnung.buildingId == building.id && wohnung.active,
            )
            .toList()
          ..sort(compareWohnungRecordsForExport);
    final buildingTasks = activeTaskDocs
        .where((doc) => doc.data()['buildingId']?.toString() == building.id)
        .toList();

    final columns = buildProjectExportColumns(buildingTasks);
    final taskByWohnungAndColumn =
        <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final doc in buildingTasks) {
      final data = doc.data();
      final columnKey = projectExportColumnKey(
        sourceColumn: readIntValue(
          data['sourceColumn'],
          fallback: readIntValue(data['sortOrder']) + 3,
        ),
        taskGroup: data['taskGroup']?.toString() ?? '',
        taskType: data['taskType']?.toString() ?? '',
      );
      final wohnungId = data['wohnungId']?.toString() ?? '';
      taskByWohnungAndColumn['$wohnungId::$columnKey'] = doc;
    }

    final maxColumnIndex = columns.isEmpty ? 4 : columns.length + 3;
    final titleCell = sheet.cell(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
    );
    titleCell.value = TextCellValue('${project.name} - ${building.name}');
    sheet.merge(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
      CellIndex.indexByColumnRow(columnIndex: maxColumnIndex, rowIndex: 0),
    );
    sheet.setMergedCellStyle(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
      titleStyle,
    );
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1)).value =
        TextCellValue(exportText(language, 'building_completion'));
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 1)).value =
        TextCellValue('${building.workTaskProgressPercent}%');

    final leftHeaderStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.blueGrey100,
    );
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 3)).value =
        TextCellValue(exportText(language, 'floor'));
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 3)).value =
        TextCellValue(exportText(language, 'apartment'));
    sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 4))
            .cellStyle =
        leftHeaderStyle;
    sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 4))
            .cellStyle =
        leftHeaderStyle;
    sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 3))
            .cellStyle =
        leftHeaderStyle;
    sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 3))
            .cellStyle =
        leftHeaderStyle;

    for (var index = 0; index < columns.length; index++) {
      final column = columns[index];
      final columnIndex = index + 3;
      final groupCell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: columnIndex, rowIndex: 3),
      );
      final typeCell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: columnIndex, rowIndex: 4),
      );
      groupCell.value = TextCellValue(column.taskGroup);
      typeCell.value = TextCellValue(column.taskType);
      groupCell.cellStyle = summaryHeaderStyle;
      typeCell.cellStyle = summaryHeaderStyle;
      sheet.setColumnWidth(columnIndex, 20);
    }

    var mergeStart = 3;
    while (mergeStart < columns.length + 3) {
      final currentGroup = columns[mergeStart - 3].taskGroup;
      var mergeEnd = mergeStart;
      while (mergeEnd + 1 < columns.length + 3 &&
          columns[mergeEnd + 1 - 3].taskGroup == currentGroup) {
        mergeEnd++;
      }
      if (mergeEnd > mergeStart) {
        sheet.merge(
          CellIndex.indexByColumnRow(columnIndex: mergeStart, rowIndex: 3),
          CellIndex.indexByColumnRow(columnIndex: mergeEnd, rowIndex: 3),
        );
        sheet.setMergedCellStyle(
          CellIndex.indexByColumnRow(columnIndex: mergeStart, rowIndex: 3),
          summaryHeaderStyle,
        );
      }
      mergeStart = mergeEnd + 1;
    }

    sheet.setColumnWidth(0, 10);
    sheet.setColumnWidth(1, 14);
    sheet.setColumnWidth(2, 4);

    for (var rowOffset = 0; rowOffset < buildingWohnungs.length; rowOffset++) {
      final wohnung = buildingWohnungs[rowOffset];
      final rowIndex = rowOffset + 5;
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIndex))
          .value = TextCellValue(
        '',
      );
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIndex))
          .value = TextCellValue(
        wohnung.name,
      );

      for (var index = 0; index < columns.length; index++) {
        final column = columns[index];
        final columnIndex = index + 3;
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(
            columnIndex: columnIndex,
            rowIndex: rowIndex,
          ),
        );
        final task = taskByWohnungAndColumn['${wohnung.id}::${column.key}'];
        if (task == null) {
          cell.value = TextCellValue('');
          cell.cellStyle = missingStyle;
          continue;
        }

        final taskData = task.data();
        final isRegister =
            _normalizeWorkbookKey(taskData['taskGroup']?.toString() ?? '') ==
            'register';
        final completed = taskData['completed'] as bool? ?? false;
        final checklistValue = normalizeChecklistTypeForImport(
          wohnung.checklistType,
        );
        final marker = isRegister
            ? (checklistValue.isEmpty ? 'Register' : checklistValue)
            : '✓';
        cell.value = TextCellValue(marker);
        cell.cellStyle = completed ? completedStyle : pendingStyle;
      }
    }
  }

  final bytes = excel.encode();
  if (bytes == null) {
    return;
  }

  final fileName =
      'dhego_${_slugifyWorkbookValue(project.name).replaceAll('.', '_')}_${exportText(language, 'file_project_export_suffix')}.xlsx';

  if (kIsWeb) {
    final blob = html.Blob(<dynamic>[
      Uint8List.fromList(bytes),
    ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    return;
  }

  await shareExcelFileOnDevice(Uint8List.fromList(bytes), fileName);
}

class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.projectName,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
    required this.registerName,
  });

  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String registerName;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(projectName),
            Text(buildingName),
            Text(apartmentName),
            if (roomName.trim().isNotEmpty) Text(roomName),
            Text(
              registerName.isEmpty
                  ? tr(context, 'register_missing')
                  : '${tr(context, 'register_label')}: $registerName',
            ),
          ],
        ),
      ),
    );
  }
}

class ChecklistItem {
  ChecklistItem({
    required this.titleHr,
    required this.titleDe,
    this.done = false,
  });

  final String titleHr;
  final String titleDe;
  bool done;
}

List<ChecklistItem> buildChecklistItemsForType(String checklistType) {
  final normalizedType = normalizeChecklistTypeForImport(checklistType);

  final medientragerItems = <Map<String, String>>[
    {'hr': 'Lokacija instalacije', 'de': 'Installationsposition'},
    {'hr': 'Pozicioniranje u prostoru', 'de': 'Positionierung im Raum'},
    {'hr': 'Podno pričvršćivanje', 'de': 'Bodenbefestigung'},
    {'hr': 'Pozicioniranje prema vagresu', 'de': 'Ausrichtung nach Waagriss'},
    {'hr': 'Pozicioniranje vertikalno', 'de': 'Vertikale Positionierung'},
    {'hr': 'Pozicioniranje horizontalno', 'de': 'Horizontale Positionierung'},
    {'hr': 'Montažni vinklovi', 'de': 'Montagewinkel'},
    {'hr': 'Schalunzi', 'de': 'Schalungselemente'},
    {
      'hr': 'Spoj cijevi na sljedeći kat',
      'de': 'Rohranschluss zum nächsten Geschoss',
    },
    {'hr': 'Označavanje dubine umetanja', 'de': 'Markierung der Einstecktiefe'},
    {'hr': 'Priključni spojevi', 'de': 'Anschlussverbindungen'},
    {'hr': 'Postavljanje zaštite od požara', 'de': 'Einbau des Brandschutzes'},
    {
      'hr': 'Proširenje stropa + pričvršćivanje',
      'de': 'Deckendurchführung + Befestigung',
    },
    {'hr': 'Izolacija', 'de': 'Dämmung'},
    {'hr': 'Drukanje', 'de': 'Druckprüfung'},
  ];

  final strangItems = <Map<String, String>>[
    {'hr': 'Lokacija instalacije', 'de': 'Installationsposition'},
    {'hr': 'Pozicioniranje u prostoru', 'de': 'Positionierung im Raum'},
    {'hr': 'Podno pričvršćivanje', 'de': 'Bodenbefestigung'},
    {'hr': 'Pozicioniranje prema vagresu', 'de': 'Ausrichtung nach Waagriss'},
    {'hr': 'Pozicioniranje vertikalno', 'de': 'Vertikale Positionierung'},
    {'hr': 'Pozicioniranje horizontalno', 'de': 'Horizontale Positionierung'},
    {'hr': 'Montažni vinklovi', 'de': 'Montagewinkel'},
    {'hr': 'Schalunzi', 'de': 'Schalungselemente'},
    {
      'hr': 'Spoj cijevi na sljedeći kat',
      'de': 'Rohranschluss zum nächsten Geschoss',
    },
    {'hr': 'Označavanje dubine umetanja', 'de': 'Markierung der Einstecktiefe'},
    {'hr': 'Priključni spojevi', 'de': 'Anschlussverbindungen'},
    {'hr': 'Postavljanje zaštite od požara', 'de': 'Einbau des Brandschutzes'},
    {
      'hr': 'Proširenje stropa + pričvršćivanje',
      'de': 'Deckendurchführung + Befestigung',
    },
    {'hr': 'Visina WC elementa', 'de': 'Höhe des WC-Elements'},
    {'hr': 'Visina tuša', 'de': 'Höhe der Dusche'},
    {'hr': 'Pravilan kut', 'de': 'Korrekter Winkel'},
    {'hr': 'Izolacija', 'de': 'Dämmung'},
    {'hr': 'Dukanje', 'de': 'Druckprüfung'},
  ];

  final strangSeitenItems = <Map<String, String>>[
    {'hr': 'Lokacija instalacije', 'de': 'Installationsposition'},
    {'hr': 'Pozicioniranje u prostoru', 'de': 'Positionierung im Raum'},
    {'hr': 'Podno pričvršćivanje', 'de': 'Bodenbefestigung'},
    {'hr': 'Pozicioniranje prema vagresu', 'de': 'Ausrichtung nach Waagriss'},
    {'hr': 'Pozicioniranje vertikalno', 'de': 'Vertikale Positionierung'},
    {'hr': 'Pozicioniranje horizontalno', 'de': 'Horizontale Positionierung'},
    {'hr': 'Montažni vinklovi', 'de': 'Montagewinkel'},
    {'hr': 'Schalunzi', 'de': 'Schalungselemente'},
    {
      'hr': 'Spoj cijevi na sljedeći kat',
      'de': 'Rohranschluss zum nächsten Geschoss',
    },
    {'hr': 'Označavanje dubine umetanja', 'de': 'Markierung der Einstecktiefe'},
    {'hr': 'Priključni spojevi', 'de': 'Anschlussverbindungen'},
    {'hr': 'Postavljanje zaštite od požara', 'de': 'Einbau des Brandschutzes'},
    {
      'hr': 'Proširenje stropa + pričvršćivanje',
      'de': 'Deckendurchführung + Befestigung',
    },
    {'hr': 'Visina WC elementa', 'de': 'Höhe des WC-Elements'},
    {'hr': 'Visina WT elementa', 'de': 'Höhe des WT-Elements'},
    {
      'hr': 'Visina pomičnih komponenti',
      'de': 'Höhe der beweglichen Komponenten',
    },
    {
      'hr': 'Razmak vijaka na WT modulu prema WT veličini',
      'de': 'Schraubenabstand am WT-Modul gemäß WT-Größe',
    },
    {'hr': 'Visina tuša', 'de': 'Höhe der Dusche'},
    {'hr': 'Pravilan kut', 'de': 'Korrekter Winkel'},
    {
      'hr': 'Kutovi u L ili C-oblikovanim rasporedima',
      'de': 'Winkel bei L- oder C-förmigen Anordnungen',
    },
    {'hr': 'Izolacija', 'de': 'Dämmung'},
    {'hr': 'Drukanje', 'de': 'Druckprüfung'},
  ];

  final sourceItems = switch (normalizedType) {
    'Strang' => strangItems,
    'Strang+Seiten' => strangSeitenItems,
    _ => medientragerItems,
  };

  return sourceItems
      .map(
        (item) => ChecklistItem(
          titleHr: item['hr'] ?? '',
          titleDe: item['de'] ?? item['hr'] ?? '',
        ),
      )
      .toList();
}

class PhotoItem {
  PhotoItem({
    required this.titleHr,
    required this.titleDe,
    required this.requiredPhoto,
    this.done = false,
    this.previewBytes,
    this.originalBytesSize,
    this.compressedBytesSize,
  });

  final String titleHr;
  final String titleDe;
  final bool requiredPhoto;
  bool done;
  Uint8List? previewBytes;
  int? originalBytesSize;
  int? compressedBytesSize;

  PhotoItem copy() {
    return PhotoItem(
      titleHr: titleHr,
      titleDe: titleDe,
      requiredPhoto: requiredPhoto,
      done: done,
      previewBytes: previewBytes == null
          ? null
          : Uint8List.fromList(previewBytes!),
      originalBytesSize: originalBytesSize,
      compressedBytesSize: compressedBytesSize,
    );
  }
}

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({
    super.key,
    required this.title,
    required this.hintText,
  });

  final String title;
  final String hintText;

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool didReturnResult = false;
  String pendingNormalizedCode = '';
  String pendingRawCode = '';
  Timer? pendingConfirmTimer;

  @override
  void dispose() {
    pendingConfirmTimer?.cancel();
    controller.dispose();
    super.dispose();
  }

  Future<void> _handleBarcodeDetection(BarcodeCapture capture) async {
    if (didReturnResult) {
      return;
    }

    final rawValue = capture.barcodes
        .map((barcode) => barcode.rawValue?.trim() ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (rawValue.isEmpty) {
      return;
    }

    final normalizedValue = normalizeScanLookupValue(rawValue);
    if (normalizedValue.isEmpty) {
      return;
    }

    if (pendingNormalizedCode != normalizedValue) {
      pendingConfirmTimer?.cancel();
      setState(() {
        pendingNormalizedCode = normalizedValue;
        pendingRawCode = rawValue;
      });
      pendingConfirmTimer = Timer(const Duration(seconds: 2), () async {
        if (!mounted || didReturnResult) {
          return;
        }
        didReturnResult = true;
        await controller.stop();
        if (!mounted) {
          return;
        }
        Navigator.of(context).pop(pendingRawCode);
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: controller,
            onDetect: _handleBarcodeDetection,
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 28,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                pendingRawCode.isEmpty
                    ? widget.hintText
                    : '${widget.hintText}\n${pendingRawCode}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CartLine {
  CartLine({required this.material, this.quantity = 1});

  final MaterialRecord material;
  int quantity;
}

class UserRecord {
  const UserRecord({
    required this.id,
    required this.username,
    required this.fullName,
    required this.email,
    required this.role,
    required this.active,
    required this.allowedProjectIds,
    required this.allowedTaskGroupsByProject,
  });

  final String id;
  final String username;
  final String fullName;
  final String email;
  final String role;
  final bool active;
  final List<String> allowedProjectIds;
  final Map<String, List<String>> allowedTaskGroupsByProject;
}

class AuthLoginData {
  const AuthLoginData({required this.user, required this.email});

  final UserRecord user;
  final String email;
}

class SiteManagerRecord {
  const SiteManagerRecord({
    required this.id,
    required this.name,
    required this.email,
    required this.active,
  });

  final String id;
  final String name;
  final String email;
  final bool active;
}

const String projectTypeConstruction = 'construction';
const String projectTypeProduction = 'production';

String normalizeProjectType(String value) {
  return value.trim().toLowerCase() == projectTypeProduction
      ? projectTypeProduction
      : projectTypeConstruction;
}

bool isProductionProjectType(String value) {
  return normalizeProjectType(value) == projectTypeProduction;
}

class ProjectRecord {
  const ProjectRecord({
    required this.id,
    required this.name,
    required this.projectType,
    required this.managerId,
    required this.managerName,
    required this.managerEmail,
    required this.active,
    required this.workTaskTotalPoints,
    required this.workTaskCompletedPoints,
    required this.workTaskProgressPercent,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String projectType;
  final String managerId;
  final String managerName;
  final String managerEmail;
  final bool active;
  final int workTaskTotalPoints;
  final int workTaskCompletedPoints;
  final int workTaskProgressPercent;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class BuildingRecord {
  const BuildingRecord({
    required this.id,
    required this.projectId,
    required this.name,
    required this.active,
    required this.workTaskTotalPoints,
    required this.workTaskCompletedPoints,
    required this.workTaskProgressPercent,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String name;
  final bool active;
  final int workTaskTotalPoints;
  final int workTaskCompletedPoints;
  final int workTaskProgressPercent;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class WohnungRecord {
  const WohnungRecord({
    required this.id,
    required this.buildingId,
    required this.name,
    required this.active,
    required this.checklistType,
    required this.workTaskTotalPoints,
    required this.workTaskCompletedPoints,
    required this.workTaskProgressPercent,
  });

  final String id;
  final String buildingId;
  final String name;
  final bool active;
  final String checklistType;
  final int workTaskTotalPoints;
  final int workTaskCompletedPoints;
  final int workTaskProgressPercent;
}

class WorkTaskRecord {
  const WorkTaskRecord({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.buildingId,
    required this.buildingName,
    required this.wohnungId,
    required this.apartmentName,
    required this.taskGroup,
    required this.taskType,
    required this.taskLabel,
    required this.pointValue,
    required this.completed,
    required this.completedAt,
    required this.completedBy,
    required this.signature,
    required this.completedViaImport,
    required this.active,
    required this.sortOrder,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String buildingId;
  final String buildingName;
  final String wohnungId;
  final String apartmentName;
  final String taskGroup;
  final String taskType;
  final String taskLabel;
  final int pointValue;
  final bool completed;
  final DateTime? completedAt;
  final String completedBy;
  final Map<String, dynamic>? signature;
  final bool completedViaImport;
  final bool active;
  final int sortOrder;
}

class ExportActivityRecord {
  const ExportActivityRecord({
    required this.id,
    required this.projectName,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
    required this.activityType,
    required this.activityGroup,
    required this.activityLabel,
    required this.signedBy,
    required this.signedAt,
    required this.photoCount,
    required this.photos,
    required this.signature,
  });

  final String id;
  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String activityType;
  final String activityGroup;
  final String activityLabel;
  final String signedBy;
  final DateTime signedAt;
  final int photoCount;
  final List<Map<String, dynamic>> photos;
  final Map<String, dynamic>? signature;
}

class ProjectExportColumn {
  const ProjectExportColumn({
    required this.sourceColumn,
    required this.taskGroup,
    required this.taskType,
  });

  final int sourceColumn;
  final String taskGroup;
  final String taskType;

  String get key => projectExportColumnKey(
    sourceColumn: sourceColumn,
    taskGroup: taskGroup,
    taskType: taskType,
  );
}

class ApartmentDocumentRecord {
  const ApartmentDocumentRecord({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.buildingId,
    required this.buildingName,
    required this.wohnungId,
    required this.apartmentName,
    required this.fileName,
    required this.storagePath,
    required this.downloadUrl,
    required this.uploadedBy,
    required this.uploadedAt,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String buildingId;
  final String buildingName;
  final String wohnungId;
  final String apartmentName;
  final String fileName;
  final String storagePath;
  final String downloadUrl;
  final String uploadedBy;
  final DateTime uploadedAt;
}

class PendingApartmentDocumentSubmission {
  const PendingApartmentDocumentSubmission({
    required this.documentId,
    required this.projectId,
    required this.projectName,
    required this.buildingId,
    required this.buildingName,
    required this.wohnungId,
    required this.apartmentName,
    required this.fileName,
    required this.bytesBase64,
    required this.uploadedBy,
    required this.queuedAt,
  });

  final String documentId;
  final String projectId;
  final String projectName;
  final String buildingId;
  final String buildingName;
  final String wohnungId;
  final String apartmentName;
  final String fileName;
  final String bytesBase64;
  final String uploadedBy;
  final DateTime queuedAt;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'documentId': documentId,
      'projectId': projectId,
      'projectName': projectName,
      'buildingId': buildingId,
      'buildingName': buildingName,
      'wohnungId': wohnungId,
      'apartmentName': apartmentName,
      'fileName': fileName,
      'bytesBase64': bytesBase64,
      'uploadedBy': uploadedBy,
      'queuedAt': queuedAt.toIso8601String(),
    };
  }

  factory PendingApartmentDocumentSubmission.fromMap(Map<String, dynamic> map) {
    return PendingApartmentDocumentSubmission(
      documentId: map['documentId']?.toString() ?? '',
      projectId: map['projectId']?.toString() ?? '',
      projectName: map['projectName']?.toString() ?? '',
      buildingId: map['buildingId']?.toString() ?? '',
      buildingName: map['buildingName']?.toString() ?? '',
      wohnungId: map['wohnungId']?.toString() ?? '',
      apartmentName: map['apartmentName']?.toString() ?? '',
      fileName: map['fileName']?.toString() ?? 'dokument.pdf',
      bytesBase64: map['bytesBase64']?.toString() ?? '',
      uploadedBy: map['uploadedBy']?.toString() ?? 'unknown',
      queuedAt:
          DateTime.tryParse(map['queuedAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class OrderRequestRecord {
  const OrderRequestRecord({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.buildingName,
    required this.managerName,
    required this.managerEmail,
    required this.orderedBy,
    required this.note,
    required this.items,
    required this.status,
    required this.scheduledSlot,
    required this.scheduledAt,
    required this.createdAt,
    required this.sentAt,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String buildingName;
  final String managerName;
  final String managerEmail;
  final String orderedBy;
  final String note;
  final List<Map<String, dynamic>> items;
  final String status;
  final String scheduledSlot;
  final DateTime? scheduledAt;
  final DateTime? createdAt;
  final DateTime? sentAt;
}

class MaterialRecord {
  const MaterialRecord({
    required this.id,
    required this.projectId,
    required this.name,
    required this.active,
    required this.articleNumber,
    required this.scanCode,
    required this.scanAltCode,
    required this.scanName,
    required this.supplier,
    required this.sheetName,
    required this.level1,
    required this.level2,
    required this.level3,
    required this.level4,
  });

  final String id;
  final String projectId;
  final String name;
  final bool active;
  final String articleNumber;
  final String scanCode;
  final String scanAltCode;
  final String scanName;
  final String supplier;
  final String sheetName;
  final String level1;
  final String level2;
  final String level3;
  final String level4;

  String get primaryCategory => level1.trim();

  String get secondaryCategory => level2.trim();

  String get tertiaryCategory => level3.trim();

  String get quaternaryCategory => level4.trim();

  String get supplierLabel => supplier.trim().isEmpty ? '-' : supplier.trim();

  String get articleLabel =>
      articleNumber.trim().isEmpty ? '-' : articleNumber.trim();

  Iterable<String> get scanCandidates sync* {
    final seen = <String>{};
    for (final raw in <String>[
      scanCode,
      scanAltCode,
      articleNumber,
      scanName,
      name,
    ]) {
      final normalized = normalizeScanLookupValue(raw);
      if (normalized.isEmpty || !seen.add(normalized)) {
        continue;
      }
      yield normalized;
    }
  }

  bool matchesScanValue(String scannedValue) {
    return scanMatchScore(scannedValue) > 0;
  }

  int scanMatchScore(String scannedValue) {
    final normalizedScannedValue = normalizeScanLookupValue(scannedValue);
    if (normalizedScannedValue.isEmpty) {
      return 0;
    }
    final scannedDigitsOnly = scannedValue.replaceAll(RegExp(r'\D'), '');

    final exactCandidates = <String>[
      normalizeScanLookupValue(scanCode),
      normalizeScanLookupValue(scanAltCode),
      normalizeScanLookupValue(articleNumber),
      normalizeScanLookupValue(scanName),
      normalizeScanLookupValue(name),
    ].where((value) => value.isNotEmpty).toList();

    for (var index = 0; index < exactCandidates.length; index++) {
      final candidate = exactCandidates[index];
      if (candidate == normalizedScannedValue) {
        return 100 - index;
      }
    }

    final numericCandidates = <String>[scanCode, scanAltCode, articleNumber]
        .map((value) => value.replaceAll(RegExp(r'\D'), ''))
        .where((value) => value.isNotEmpty)
        .toList();

    if (scannedDigitsOnly.length >= 8) {
      for (var index = 0; index < numericCandidates.length; index++) {
        final candidate = numericCandidates[index];
        if (candidate == scannedDigitsOnly) {
          return 95 - index;
        }
      }
    }

    for (var index = 0; index < exactCandidates.length; index++) {
      final candidate = exactCandidates[index];
      final minLength = candidate.length >= 8 ? 8 : 6;
      if (candidate.length < minLength ||
          normalizedScannedValue.length < minLength) {
        continue;
      }
      if (normalizedScannedValue.contains(candidate) ||
          candidate.contains(normalizedScannedValue)) {
        return 70 - index;
      }
    }

    if (scannedDigitsOnly.length >= 8) {
      for (var index = 0; index < numericCandidates.length; index++) {
        final candidate = numericCandidates[index];
        final minLength = candidate.length >= 8 ? 8 : 6;
        if (candidate.length < minLength) {
          continue;
        }
        if (scannedDigitsOnly.contains(candidate) ||
            candidate.contains(scannedDigitsOnly)) {
          return 68 - index;
        }
      }
    }

    final scannedTokens = _scanLookupTokens(scannedValue);
    if (scannedTokens.isEmpty) {
      return 0;
    }

    for (final token in scannedTokens) {
      if (token.length < 6) {
        continue;
      }
      for (var index = 0; index < exactCandidates.length; index++) {
        final candidate = exactCandidates[index];
        if (candidate == token) {
          return 60 - index;
        }
        if (candidate.length >= 8 &&
            (token.contains(candidate) || candidate.contains(token))) {
          return 40 - index;
        }
      }
    }

    return 0;
  }

  String get searchIndex => [
    articleNumber,
    scanCode,
    scanAltCode,
    scanName,
    name,
    supplier,
    sheetName,
    level1,
    level2,
    level3,
    level4,
  ].join(' ').toLowerCase();
}

class RegisterSubmissionRecord {
  const RegisterSubmissionRecord({
    required this.id,
    required this.projectName,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
    required this.registerName,
    required this.signedBy,
    required this.signedAt,
    required this.photoCount,
    required this.photos,
    required this.signature,
  });

  final String id;
  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String registerName;
  final String signedBy;
  final DateTime signedAt;
  final int photoCount;
  final List<Map<String, dynamic>> photos;
  final Map<String, dynamic>? signature;
}

class PendingRegisterSubmission {
  const PendingRegisterSubmission({
    required this.projectName,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
    required this.registerName,
    required this.signedBy,
    required this.signedAt,
    required this.registerKey,
    required this.photos,
    required this.signatureBytesBase64,
  });

  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String registerName;
  final String signedBy;
  final DateTime signedAt;
  final String registerKey;
  final List<Map<String, dynamic>> photos;
  final String? signatureBytesBase64;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'projectName': projectName,
      'buildingName': buildingName,
      'apartmentName': apartmentName,
      'roomName': roomName,
      'registerName': registerName,
      'signedBy': signedBy,
      'signedAt': signedAt.toIso8601String(),
      'registerKey': registerKey,
      'photos': photos,
      'signatureBytesBase64': signatureBytesBase64,
    };
  }

  factory PendingRegisterSubmission.fromMap(Map<String, dynamic> map) {
    return PendingRegisterSubmission(
      projectName: map['projectName']?.toString() ?? '',
      buildingName: map['buildingName']?.toString() ?? '',
      apartmentName: map['apartmentName']?.toString() ?? '',
      roomName: map['roomName']?.toString() ?? '',
      registerName: map['registerName']?.toString() ?? '',
      signedBy: map['signedBy']?.toString() ?? 'unknown',
      signedAt:
          DateTime.tryParse(map['signedAt']?.toString() ?? '') ??
          DateTime.now(),
      registerKey: map['registerKey']?.toString() ?? '',
      photos: (map['photos'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map>()
          .map(
            (photo) =>
                photo.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList(),
      signatureBytesBase64: map['signatureBytesBase64']?.toString(),
    );
  }
}

class DemoUser {
  const DemoUser({
    required this.username,
    required this.password,
    required this.role,
    required this.allowedProjects,
    required this.allowedTaskGroupsByProject,
  });

  final String username;
  final String password;
  final String role;
  final List<String> allowedProjects;
  final Map<String, List<String>> allowedTaskGroupsByProject;
}

enum AdminSortOption {
  nameAsc,
  nameDesc,
  createdNewest,
  createdOldest,
  updatedNewest,
  updatedOldest,
}

DemoUser resolveDemoUser(DemoUser fallbackUser, UserRecord? liveUser) {
  if (liveUser == null) {
    return fallbackUser;
  }

  return DemoUser(
    username: liveUser.username,
    password: fallbackUser.password,
    role: liveUser.role,
    allowedProjects: liveUser.allowedProjectIds,
    allowedTaskGroupsByProject: liveUser.allowedTaskGroupsByProject,
  );
}

DateTime? timestampToDateTime(dynamic value) {
  if (value is Timestamp) {
    return value.toDate();
  }
  if (value is DateTime) {
    return value;
  }
  return null;
}

int readIntValue(dynamic value, {int fallback = 0}) {
  if (value == null) {
    return fallback;
  }

  try {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString()) ?? fallback;
  } catch (_) {
    return int.tryParse(value.toString()) ?? fallback;
  }
}

int calculateTaskProgressPercent({
  required int totalPoints,
  required int completedPoints,
}) {
  if (totalPoints <= 0) {
    return 0;
  }
  return ((completedPoints / totalPoints) * 100).round();
}

Future<void> recalculateWorkTaskProgress({
  required String projectId,
  required String buildingId,
  required String wohnungId,
}) async {
  Future<Map<String, int>> countForField(String field, String value) async {
    final snapshot = await firestore
        .collection('work_tasks')
        .where(field, isEqualTo: value)
        .get();
    final docs = snapshot.docs
        .where((doc) => doc.data()['active'] as bool? ?? true)
        .toList();
    final totalPoints = docs.fold<int>(
      0,
      (sum, doc) => sum + readIntValue(doc.data()['pointValue'], fallback: 1),
    );
    final completedPoints = docs.fold<int>(
      0,
      (sum, doc) =>
          sum +
          ((doc.data()['completed'] as bool? ?? false)
              ? readIntValue(doc.data()['pointValue'], fallback: 1)
              : 0),
    );
    return <String, int>{
      'total': totalPoints,
      'completed': completedPoints,
      'percent': calculateTaskProgressPercent(
        totalPoints: totalPoints,
        completedPoints: completedPoints,
      ),
    };
  }

  final wohnungStats = await countForField('wohnungId', wohnungId);
  final buildingStats = await countForField('buildingId', buildingId);
  final projectStats = await countForField('projectId', projectId);
  final now = Timestamp.now();

  await firestore.collection('wohnungs').doc(wohnungId).set({
    'workTaskTotalPoints': wohnungStats['total'],
    'workTaskCompletedPoints': wohnungStats['completed'],
    'workTaskProgressPercent': wohnungStats['percent'],
    'updatedAt': now,
  }, SetOptions(merge: true));

  await firestore.collection('buildings').doc(buildingId).set({
    'workTaskTotalPoints': buildingStats['total'],
    'workTaskCompletedPoints': buildingStats['completed'],
    'workTaskProgressPercent': buildingStats['percent'],
    'updatedAt': now,
  }, SetOptions(merge: true));

  await firestore.collection('projects').doc(projectId).set({
    'workTaskTotalPoints': projectStats['total'],
    'workTaskCompletedPoints': projectStats['completed'],
    'workTaskProgressPercent': projectStats['percent'],
    'updatedAt': now,
  }, SetOptions(merge: true));
}

Future<bool> completeWorkTask({
  required WorkTaskRecord task,
  required String completedBy,
  Map<String, dynamic>? signature,
}) async {
  final currentDoc = await firestore
      .collection('work_tasks')
      .doc(task.id)
      .get();
  final currentData = currentDoc.data() ?? <String, dynamic>{};
  if ((currentData['completed'] as bool? ?? false) == true) {
    return false;
  }

  await firestore.collection('work_tasks').doc(task.id).set({
    'completed': true,
    'completedAt': Timestamp.now(),
    'completedBy': completedBy,
    'signature': signature,
    'updatedAt': Timestamp.now(),
  }, SetOptions(merge: true));

  await recalculateWorkTaskProgress(
    projectId: task.projectId,
    buildingId: task.buildingId,
    wohnungId: task.wohnungId,
  );

  return true;
}

String adminSortOptionLabel(BuildContext context, AdminSortOption option) {
  switch (option) {
    case AdminSortOption.nameAsc:
      return tr(context, 'sort_name_asc');
    case AdminSortOption.nameDesc:
      return tr(context, 'sort_name_desc');
    case AdminSortOption.createdNewest:
      return tr(context, 'sort_created_newest');
    case AdminSortOption.createdOldest:
      return tr(context, 'sort_created_oldest');
    case AdminSortOption.updatedNewest:
      return tr(context, 'sort_updated_newest');
    case AdminSortOption.updatedOldest:
      return tr(context, 'sort_updated_oldest');
  }
}

void sortProjectRecords(List<ProjectRecord> projects, AdminSortOption option) {
  int compareDate(DateTime? a, DateTime? b) {
    if (a == null && b == null) {
      return 0;
    }
    if (a == null) {
      return 1;
    }
    if (b == null) {
      return -1;
    }
    return a.compareTo(b);
  }

  projects.sort((a, b) {
    switch (option) {
      case AdminSortOption.nameAsc:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case AdminSortOption.nameDesc:
        return b.name.toLowerCase().compareTo(a.name.toLowerCase());
      case AdminSortOption.createdNewest:
        return compareDate(b.createdAt, a.createdAt);
      case AdminSortOption.createdOldest:
        return compareDate(a.createdAt, b.createdAt);
      case AdminSortOption.updatedNewest:
        return compareDate(
          b.updatedAt ?? b.createdAt,
          a.updatedAt ?? a.createdAt,
        );
      case AdminSortOption.updatedOldest:
        return compareDate(
          a.updatedAt ?? a.createdAt,
          b.updatedAt ?? b.createdAt,
        );
    }
  });
}

void sortBuildingRecords(
  List<BuildingRecord> buildings,
  AdminSortOption option,
) {
  int compareDate(DateTime? a, DateTime? b) {
    if (a == null && b == null) {
      return 0;
    }
    if (a == null) {
      return 1;
    }
    if (b == null) {
      return -1;
    }
    return a.compareTo(b);
  }

  buildings.sort((a, b) {
    switch (option) {
      case AdminSortOption.nameAsc:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case AdminSortOption.nameDesc:
        return b.name.toLowerCase().compareTo(a.name.toLowerCase());
      case AdminSortOption.createdNewest:
        return compareDate(b.createdAt, a.createdAt);
      case AdminSortOption.createdOldest:
        return compareDate(a.createdAt, b.createdAt);
      case AdminSortOption.updatedNewest:
        return compareDate(
          b.updatedAt ?? b.createdAt,
          a.updatedAt ?? a.createdAt,
        );
      case AdminSortOption.updatedOldest:
        return compareDate(
          a.updatedAt ?? a.createdAt,
          b.updatedAt ?? b.createdAt,
        );
    }
  });
}

Stream<List<ProjectRecord>> watchProjects(List<String> projectIds) {
  final query = firestore
      .collection('projects')
      .where('active', isEqualTo: true);

  if (projectIds.isEmpty) {
    return query.snapshots().map(_mapProjects);
  }

  return query
      .where(FieldPath.documentId, whereIn: projectIds)
      .snapshots()
      .map(_mapProjects);
}

Stream<List<ProjectRecord>> watchAllProjects() {
  return firestore.collection('projects').snapshots().map(_mapProjects);
}

List<ProjectRecord> _mapProjects(QuerySnapshot<Map<String, dynamic>> snapshot) {
  return snapshot.docs
      .map(
        (doc) => ProjectRecord(
          id: doc.id,
          name: doc.data()['name'] as String? ?? doc.id,
          projectType: normalizeProjectType(
            doc.data()['projectType'] as String? ?? projectTypeConstruction,
          ),
          managerId: doc.data()['managerId'] as String? ?? '',
          managerName: doc.data()['managerName'] as String? ?? '',
          managerEmail: doc.data()['managerEmail'] as String? ?? '',
          active: doc.data()['active'] as bool? ?? true,
          workTaskTotalPoints: readIntValue(doc.data()['workTaskTotalPoints']),
          workTaskCompletedPoints: readIntValue(
            doc.data()['workTaskCompletedPoints'],
          ),
          workTaskProgressPercent: readIntValue(
            doc.data()['workTaskProgressPercent'],
          ),
          createdAt: timestampToDateTime(doc.data()['createdAt']),
          updatedAt: timestampToDateTime(doc.data()['updatedAt']),
        ),
      )
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
}

final RegExp _wohnungNaturalPattern = RegExp(
  r'^(?:we\s*)?0*(\d+)(.*)$',
  caseSensitive: false,
);

int compareWohnungNames(String left, String right) {
  final normalizedLeft = left.trim();
  final normalizedRight = right.trim();
  final leftMatch = _wohnungNaturalPattern.firstMatch(normalizedLeft);
  final rightMatch = _wohnungNaturalPattern.firstMatch(normalizedRight);

  if (leftMatch != null && rightMatch != null) {
    final leftNumber = int.tryParse(leftMatch.group(1) ?? '');
    final rightNumber = int.tryParse(rightMatch.group(1) ?? '');
    if (leftNumber != null && rightNumber != null) {
      final byNumber = leftNumber.compareTo(rightNumber);
      if (byNumber != 0) {
        return byNumber;
      }

      final leftSuffix = (leftMatch.group(2) ?? '').trim().toLowerCase();
      final rightSuffix = (rightMatch.group(2) ?? '').trim().toLowerCase();
      final bySuffix = leftSuffix.compareTo(rightSuffix);
      if (bySuffix != 0) {
        return bySuffix;
      }
    }
  }

  return normalizedLeft.toLowerCase().compareTo(normalizedRight.toLowerCase());
}

Map<String, List<String>> parseAllowedTaskGroupsByProject(dynamic value) {
  if (value is! Map) {
    return <String, List<String>>{};
  }

  final result = <String, List<String>>{};
  for (final entry in value.entries) {
    final projectId = entry.key.toString().trim();
    if (projectId.isEmpty) {
      continue;
    }

    final taskGroups =
        (entry.value as List<dynamic>? ?? <dynamic>[])
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    result[projectId] = taskGroups;
  }
  return result;
}

Map<String, List<String>> cloneAllowedTaskGroupsByProject(
  Map<String, List<String>> source,
) {
  return source.map(
    (key, value) => MapEntry(key, List<String>.from(value)..sort()),
  );
}

bool userCanAccessTaskGroup({
  required DemoUser user,
  required String projectId,
  required String taskGroup,
}) {
  if (user.role == 'admin' || isManagerLikeRole(user.role)) {
    return true;
  }

  final configuredTaskGroups = user.allowedTaskGroupsByProject[projectId];
  if (configuredTaskGroups == null) {
    return true;
  }

  final normalizedTaskGroup = normalizeImportUserKey(taskGroup);
  return configuredTaskGroups.any(
    (group) => normalizeImportUserKey(group) == normalizedTaskGroup,
  );
}

bool userCanCompleteTaskGroup({
  required DemoUser user,
  required String projectId,
  required String taskGroup,
}) {
  return userCanAccessTaskGroup(
    user: user,
    projectId: projectId,
    taskGroup: taskGroup,
  );
}

Future<Map<String, List<String>>> fetchTaskGroupOptionsByProjectIds(
  List<String> projectIds,
) async {
  final normalizedProjectIds =
      projectIds
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  if (normalizedProjectIds.isEmpty) {
    return <String, List<String>>{};
  }

  final grouped = <String, Set<String>>{};
  for (var index = 0; index < normalizedProjectIds.length; index += 10) {
    final chunk = normalizedProjectIds.skip(index).take(10).toList();
    final snapshot = await firestore
        .collection('work_tasks')
        .where('projectId', whereIn: chunk)
        .get();
    for (final doc in snapshot.docs) {
      final projectId = doc.data()['projectId']?.toString().trim() ?? '';
      final taskGroup = doc.data()['taskGroup']?.toString().trim() ?? '';
      if (projectId.isEmpty || taskGroup.isEmpty) {
        continue;
      }
      grouped.putIfAbsent(projectId, () => <String>{}).add(taskGroup);
    }
  }

  return grouped.map(
    (projectId, groups) => MapEntry(
      projectId,
      groups.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
    ),
  );
}

String formatTaskProgressSummary(
  BuildContext context, {
  required int totalPoints,
  required int completedPoints,
  required int progressPercent,
}) {
  if (totalPoints <= 0) {
    return '${tr(context, 'progress_label')}: 0%';
  }

  return '${tr(context, 'progress_label')}: $progressPercent% '
      '($completedPoints/$totalPoints ${tr(context, 'points_label')})';
}

Stream<List<BuildingRecord>> watchBuildings(String projectId) {
  return firestore
      .collection('buildings')
      .where('projectId', isEqualTo: projectId)
      .where('active', isEqualTo: true)
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs
                .map(
                  (doc) => BuildingRecord(
                    id: doc.id,
                    projectId: doc.data()['projectId'] as String? ?? '',
                    name: doc.data()['name'] as String? ?? doc.id,
                    active: doc.data()['active'] as bool? ?? true,
                    workTaskTotalPoints: readIntValue(
                      doc.data()['workTaskTotalPoints'],
                    ),
                    workTaskCompletedPoints: readIntValue(
                      doc.data()['workTaskCompletedPoints'],
                    ),
                    workTaskProgressPercent: readIntValue(
                      doc.data()['workTaskProgressPercent'],
                    ),
                    createdAt: timestampToDateTime(doc.data()['createdAt']),
                    updatedAt: timestampToDateTime(doc.data()['updatedAt']),
                  ),
                )
                .toList()
              ..sort((a, b) => compareWohnungNames(a.name, b.name)),
      );
}

Stream<List<SiteManagerRecord>> watchSiteManagers() {
  return firestore
      .collection('users')
      .where('role', isEqualTo: 'site_manager')
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs
                .map(
                  (doc) => SiteManagerRecord(
                    id: doc.id,
                    name:
                        doc.data()['username'] as String? ??
                        doc.data()['name'] as String? ??
                        doc.id,
                    email: doc.data()['email'] as String? ?? '',
                    active: doc.data()['active'] as bool? ?? true,
                  ),
                )
                .toList()
              ..sort((a, b) => compareWohnungNames(a.name, b.name)),
      );
}

Stream<List<OrderRequestRecord>> watchOrderRequests() {
  return firestore.collection('order_requests').snapshots().map((snapshot) {
    final orders =
        snapshot.docs
            .map(
              (doc) => OrderRequestRecord(
                id: doc.id,
                projectId: doc.data()['projectId'] as String? ?? '',
                projectName: doc.data()['projectName'] as String? ?? '',
                buildingName: doc.data()['buildingName'] as String? ?? '',
                managerName: doc.data()['managerName'] as String? ?? '',
                managerEmail: doc.data()['managerEmail'] as String? ?? '',
                orderedBy: doc.data()['orderedBy'] as String? ?? '',
                note: doc.data()['note'] as String? ?? '',
                items: (doc.data()['items'] as List<dynamic>? ?? <dynamic>[])
                    .whereType<Map>()
                    .map(
                      (item) => item.map(
                        (key, value) => MapEntry(key.toString(), value),
                      ),
                    )
                    .toList(),
                status: doc.data()['status'] as String? ?? 'pending',
                scheduledSlot: doc.data()['scheduledSlot'] as String? ?? '',
                scheduledAt: timestampToDateTime(doc.data()['scheduledAt']),
                createdAt: timestampToDateTime(doc.data()['createdAt']),
                sentAt: timestampToDateTime(doc.data()['sentAt']),
              ),
            )
            .toList()
          ..sort((a, b) {
            final first = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final second =
                a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            return first.compareTo(second);
          });

    return orders;
  });
}

Stream<List<ApartmentDocumentRecord>> watchApartmentDocuments(
  String wohnungId,
) {
  return firestore
      .collection('apartment_documents')
      .where('wohnungId', isEqualTo: wohnungId)
      .snapshots()
      .map((snapshot) {
        final documents =
            snapshot.docs
                .map(
                  (doc) => ApartmentDocumentRecord(
                    id: doc.id,
                    projectId: doc.data()['projectId'] as String? ?? '',
                    projectName: doc.data()['projectName'] as String? ?? '',
                    buildingId: doc.data()['buildingId'] as String? ?? '',
                    buildingName: doc.data()['buildingName'] as String? ?? '',
                    wohnungId: doc.data()['wohnungId'] as String? ?? '',
                    apartmentName: doc.data()['apartmentName'] as String? ?? '',
                    fileName: doc.data()['fileName'] as String? ?? doc.id,
                    storagePath: doc.data()['storagePath'] as String? ?? '',
                    downloadUrl: doc.data()['downloadUrl'] as String? ?? '',
                    uploadedBy: doc.data()['uploadedBy'] as String? ?? '',
                    uploadedAt:
                        timestampToDateTime(doc.data()['uploadedAt']) ??
                        DateTime.fromMillisecondsSinceEpoch(0),
                  ),
                )
                .toList()
              ..sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
        return documents;
      });
}

Stream<List<WohnungRecord>> watchWohnungs(String buildingId) {
  return firestore
      .collection('wohnungs')
      .where('buildingId', isEqualTo: buildingId)
      .where('active', isEqualTo: true)
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs
                .map(
                  (doc) => WohnungRecord(
                    id: doc.id,
                    buildingId: doc.data()['buildingId'] as String? ?? '',
                    name: doc.data()['name'] as String? ?? doc.id,
                    active: doc.data()['active'] as bool? ?? true,
                    checklistType: doc.data()['checklistType'] as String? ?? '',
                    workTaskTotalPoints: readIntValue(
                      doc.data()['workTaskTotalPoints'],
                    ),
                    workTaskCompletedPoints: readIntValue(
                      doc.data()['workTaskCompletedPoints'],
                    ),
                    workTaskProgressPercent: readIntValue(
                      doc.data()['workTaskProgressPercent'],
                    ),
                  ),
                )
                .toList()
              ..sort((a, b) => compareWohnungNames(a.name, b.name)),
      );
}

Stream<List<BuildingRecord>> watchAllBuildings() {
  return firestore
      .collection('buildings')
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs
                .map(
                  (doc) => BuildingRecord(
                    id: doc.id,
                    projectId: doc.data()['projectId'] as String? ?? '',
                    name: doc.data()['name'] as String? ?? doc.id,
                    active: doc.data()['active'] as bool? ?? true,
                    workTaskTotalPoints: readIntValue(
                      doc.data()['workTaskTotalPoints'],
                    ),
                    workTaskCompletedPoints: readIntValue(
                      doc.data()['workTaskCompletedPoints'],
                    ),
                    workTaskProgressPercent: readIntValue(
                      doc.data()['workTaskProgressPercent'],
                    ),
                    createdAt: timestampToDateTime(doc.data()['createdAt']),
                    updatedAt: timestampToDateTime(doc.data()['updatedAt']),
                  ),
                )
                .toList()
              ..sort((a, b) => compareWohnungNames(a.name, b.name)),
      );
}

Stream<List<WohnungRecord>> watchAllWohnungs() {
  return firestore
      .collection('wohnungs')
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs
                .map(
                  (doc) => WohnungRecord(
                    id: doc.id,
                    buildingId: doc.data()['buildingId'] as String? ?? '',
                    name: doc.data()['name'] as String? ?? doc.id,
                    active: doc.data()['active'] as bool? ?? true,
                    checklistType: doc.data()['checklistType'] as String? ?? '',
                    workTaskTotalPoints: readIntValue(
                      doc.data()['workTaskTotalPoints'],
                    ),
                    workTaskCompletedPoints: readIntValue(
                      doc.data()['workTaskCompletedPoints'],
                    ),
                    workTaskProgressPercent: readIntValue(
                      doc.data()['workTaskProgressPercent'],
                    ),
                  ),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name)),
      );
}

Stream<List<WorkTaskRecord>> watchWorkTasksForWohnung(String wohnungId) {
  return firestore
      .collection('work_tasks')
      .where('wohnungId', isEqualTo: wohnungId)
      .snapshots()
      .map((snapshot) {
        final tasks = snapshot.docs
            .where((doc) => doc.data()['active'] as bool? ?? true)
            .map(
              (doc) => WorkTaskRecord(
                id: doc.id,
                projectId: doc.data()['projectId'] as String? ?? '',
                projectName: doc.data()['projectName'] as String? ?? '',
                buildingId: doc.data()['buildingId'] as String? ?? '',
                buildingName: doc.data()['buildingName'] as String? ?? '',
                wohnungId: doc.data()['wohnungId'] as String? ?? '',
                apartmentName: doc.data()['apartmentName'] as String? ?? '',
                taskGroup: doc.data()['taskGroup'] as String? ?? '',
                taskType: doc.data()['taskType'] as String? ?? '',
                taskLabel: doc.data()['taskLabel'] as String? ?? doc.id,
                pointValue: readIntValue(doc.data()['pointValue'], fallback: 1),
                completed: doc.data()['completed'] as bool? ?? false,
                completedAt: timestampToDateTime(doc.data()['completedAt']),
                completedBy: doc.data()['completedBy'] as String? ?? '',
                signature: (doc.data()['signature'] as Map<dynamic, dynamic>?)
                    ?.map((key, value) => MapEntry(key.toString(), value)),
                completedViaImport:
                    doc.data()['completedViaImport'] as bool? ?? false,
                active: doc.data()['active'] as bool? ?? true,
                sortOrder: readIntValue(doc.data()['sortOrder']),
              ),
            )
            .toList();

        tasks.sort((a, b) {
          final byOrder = a.sortOrder.compareTo(b.sortOrder);
          if (byOrder != 0) {
            return byOrder;
          }
          final byGroup = a.taskGroup.toLowerCase().compareTo(
            b.taskGroup.toLowerCase(),
          );
          if (byGroup != 0) {
            return byGroup;
          }
          return a.taskLabel.toLowerCase().compareTo(b.taskLabel.toLowerCase());
        });

        return tasks;
      });
}

Stream<List<WorkTaskRecord>> watchWorkTasksForBuilding(String buildingId) {
  return firestore
      .collection('work_tasks')
      .where('buildingId', isEqualTo: buildingId)
      .snapshots()
      .map((snapshot) {
        final tasks = snapshot.docs
            .where((doc) => doc.data()['active'] as bool? ?? true)
            .map(
              (doc) => WorkTaskRecord(
                id: doc.id,
                projectId: doc.data()['projectId'] as String? ?? '',
                projectName: doc.data()['projectName'] as String? ?? '',
                buildingId: doc.data()['buildingId'] as String? ?? '',
                buildingName: doc.data()['buildingName'] as String? ?? '',
                wohnungId: doc.data()['wohnungId'] as String? ?? '',
                apartmentName: doc.data()['apartmentName'] as String? ?? '',
                taskGroup: doc.data()['taskGroup'] as String? ?? '',
                taskType: doc.data()['taskType'] as String? ?? '',
                taskLabel: doc.data()['taskLabel'] as String? ?? doc.id,
                pointValue: readIntValue(doc.data()['pointValue'], fallback: 1),
                completed: doc.data()['completed'] as bool? ?? false,
                completedAt: timestampToDateTime(doc.data()['completedAt']),
                completedBy: doc.data()['completedBy'] as String? ?? '',
                signature: (doc.data()['signature'] as Map<dynamic, dynamic>?)
                    ?.map((key, value) => MapEntry(key.toString(), value)),
                completedViaImport:
                    doc.data()['completedViaImport'] as bool? ?? false,
                active: doc.data()['active'] as bool? ?? true,
                sortOrder: readIntValue(doc.data()['sortOrder']),
              ),
            )
            .toList();

        tasks.sort((a, b) {
          final byOrder = a.sortOrder.compareTo(b.sortOrder);
          if (byOrder != 0) {
            return byOrder;
          }
          final byGroup = a.taskGroup.toLowerCase().compareTo(
            b.taskGroup.toLowerCase(),
          );
          if (byGroup != 0) {
            return byGroup;
          }
          return compareWohnungNames(a.apartmentName, b.apartmentName);
        });

        return tasks;
      });
}

Stream<List<String>> watchMaterials() {
  return watchActiveMaterialRecords().map(
    (materials) => materials.map((item) => item.name).toList(),
  );
}

Stream<List<MaterialRecord>> watchActiveMaterialRecords() {
  return firestore
      .collection('materials')
      .snapshots()
      .map(
        (snapshot) => _mapMaterials(
          snapshot,
        ).where((material) => material.active).toList(),
      );
}

Stream<List<MaterialRecord>> watchActiveProjectMaterialRecords(
  String projectId,
) {
  return firestore
      .collection('project_materials')
      .where('projectId', isEqualTo: projectId)
      .snapshots()
      .map(
        (snapshot) => _mapMaterials(
          snapshot,
        ).where((material) => material.active).toList(),
      );
}

Stream<List<MaterialRecord>> watchAllMaterials() {
  return firestore.collection('materials').snapshots().map(_mapMaterials);
}

List<MaterialRecord> _mapMaterials(
  QuerySnapshot<Map<String, dynamic>> snapshot,
) {
  final materials = snapshot.docs
      .map(
        (doc) => MaterialRecord(
          id: doc.id,
          projectId: doc.data()['projectId'] as String? ?? '',
          name: doc.data()['name'] as String? ?? doc.id,
          active: doc.data()['active'] as bool? ?? true,
          articleNumber: doc.data()['articleNumber'] as String? ?? '',
          scanCode: doc.data()['scanCode'] as String? ?? '',
          scanAltCode: doc.data()['scanAltCode'] as String? ?? '',
          scanName: doc.data()['scanName'] as String? ?? '',
          supplier: doc.data()['supplier'] as String? ?? '',
          sheetName:
              doc.data()['sheetName'] as String? ??
              doc.data()['categorySheet'] as String? ??
              '',
          level1:
              doc.data()['level1'] as String? ??
              doc.data()['orangeCategory'] as String? ??
              '',
          level2:
              doc.data()['level2'] as String? ??
              doc.data()['greenCategory'] as String? ??
              '',
          level3:
              doc.data()['level3'] as String? ??
              doc.data()['blueCategory'] as String? ??
              '',
          level4:
              doc.data()['level4'] as String? ??
              doc.data()['purpleCategory'] as String? ??
              '',
        ),
      )
      .toList();

  materials.sort((a, b) {
    final bySheet = a.sheetName.toLowerCase().compareTo(
      b.sheetName.toLowerCase(),
    );
    if (bySheet != 0) {
      return bySheet;
    }

    final byLevel1 = a.level1.toLowerCase().compareTo(b.level1.toLowerCase());
    if (byLevel1 != 0) {
      return byLevel1;
    }

    final byLevel2 = a.level2.toLowerCase().compareTo(b.level2.toLowerCase());
    if (byLevel2 != 0) {
      return byLevel2;
    }

    final byLevel3 = a.level3.toLowerCase().compareTo(b.level3.toLowerCase());
    if (byLevel3 != 0) {
      return byLevel3;
    }

    final byLevel4 = a.level4.toLowerCase().compareTo(b.level4.toLowerCase());
    if (byLevel4 != 0) {
      return byLevel4;
    }

    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  return materials;
}

Stream<List<RegisterSubmissionRecord>> watchRegisterSubmissions() {
  return firestore
      .collection('register_submissions')
      .orderBy('signedAt', descending: true)
      .snapshots()
      .map(
        (snapshot) => snapshot.docs
            .map(
              (doc) => RegisterSubmissionRecord(
                id: doc.id,
                projectName: doc.data()['projectName'] as String? ?? '',
                buildingName: doc.data()['buildingName'] as String? ?? '',
                apartmentName: doc.data()['apartmentName'] as String? ?? '',
                roomName: doc.data()['roomName'] as String? ?? '',
                registerName: doc.data()['registerName'] as String? ?? '',
                signedBy: doc.data()['signedBy'] as String? ?? '',
                signedAt:
                    (doc.data()['signedAt'] as Timestamp?)?.toDate() ??
                    DateTime.fromMillisecondsSinceEpoch(0),
                photoCount: readIntValue(doc.data()['photoCount']),
                photos: (doc.data()['photos'] as List<dynamic>? ?? <dynamic>[])
                    .whereType<Map<dynamic, dynamic>>()
                    .map(
                      (photo) => photo.map(
                        (key, value) => MapEntry(key.toString(), value),
                      ),
                    )
                    .toList(),
                signature: (doc.data()['signature'] as Map<dynamic, dynamic>?)
                    ?.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .toList(),
      );
}

Stream<List<WorkTaskRecord>> watchCompletedWorkTasks() {
  return firestore.collection('work_tasks').snapshots().map((snapshot) {
    final tasks = snapshot.docs
        .where((doc) {
          final data = doc.data();
          return (data['active'] as bool? ?? true) &&
              (data['completed'] as bool? ?? false);
        })
        .map(
          (doc) => WorkTaskRecord(
            id: doc.id,
            projectId: doc.data()['projectId'] as String? ?? '',
            projectName: doc.data()['projectName'] as String? ?? '',
            buildingId: doc.data()['buildingId'] as String? ?? '',
            buildingName: doc.data()['buildingName'] as String? ?? '',
            wohnungId: doc.data()['wohnungId'] as String? ?? '',
            apartmentName: doc.data()['apartmentName'] as String? ?? '',
            taskGroup: doc.data()['taskGroup'] as String? ?? '',
            taskType: doc.data()['taskType'] as String? ?? '',
            taskLabel: doc.data()['taskLabel'] as String? ?? doc.id,
            pointValue: readIntValue(doc.data()['pointValue'], fallback: 1),
            completed: doc.data()['completed'] as bool? ?? false,
            completedAt: timestampToDateTime(doc.data()['completedAt']),
            completedBy: doc.data()['completedBy'] as String? ?? '',
            signature: (doc.data()['signature'] as Map<dynamic, dynamic>?)?.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
            completedViaImport:
                doc.data()['completedViaImport'] as bool? ?? false,
            active: doc.data()['active'] as bool? ?? true,
            sortOrder: readIntValue(doc.data()['sortOrder']),
          ),
        )
        .toList();

    tasks.sort((a, b) {
      final leftDate = a.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final rightDate = b.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return rightDate.compareTo(leftDate);
    });
    return tasks;
  });
}

Stream<List<UserRecord>> watchUsers() {
  return firestore
      .collection('users')
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs
                .map(
                  (doc) => UserRecord(
                    id: doc.id,
                    username: doc.data()['username'] as String? ?? doc.id,
                    fullName:
                        doc.data()['fullName'] as String? ??
                        doc.data()['username'] as String? ??
                        doc.id,
                    email: doc.data()['email'] as String? ?? '',
                    role: doc.data()['role'] as String? ?? 'worker',
                    active: doc.data()['active'] as bool? ?? true,
                    allowedProjectIds:
                        (doc.data()['allowedProjectIds'] as List<dynamic>? ??
                                <dynamic>[])
                            .map((item) => item.toString())
                            .toList(),
                    allowedTaskGroupsByProject: parseAllowedTaskGroupsByProject(
                      doc.data()['allowedTaskGroupsByProject'],
                    ),
                  ),
                )
                .toList()
              ..sort((a, b) => a.username.compareTo(b.username)),
      );
}

Stream<UserRecord?> watchUserByUsername(String username) {
  return firestore
      .collection('users')
      .where('username', isEqualTo: username)
      .limit(1)
      .snapshots()
      .map((snapshot) {
        if (snapshot.docs.isEmpty) {
          return null;
        }

        final doc = snapshot.docs.first;
        return UserRecord(
          id: doc.id,
          username: doc.data()['username'] as String? ?? doc.id,
          fullName:
              doc.data()['fullName'] as String? ??
              doc.data()['username'] as String? ??
              doc.id,
          email: doc.data()['email'] as String? ?? '',
          role: doc.data()['role'] as String? ?? 'worker',
          active: doc.data()['active'] as bool? ?? true,
          allowedProjectIds:
              (doc.data()['allowedProjectIds'] as List<dynamic>? ?? <dynamic>[])
                  .map((item) => item.toString())
                  .toList(),
          allowedTaskGroupsByProject: parseAllowedTaskGroupsByProject(
            doc.data()['allowedTaskGroupsByProject'],
          ),
        );
      });
}

Future<AuthLoginData?> fetchAuthLoginData(String identifier) async {
  final normalizedIdentifier = identifier.trim();
  final normalizedLookup = normalizedIdentifier.toLowerCase();
  if (normalizedIdentifier.isEmpty) {
    return null;
  }

  AuthLoginData? buildLoginDataFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    if (!doc.exists) {
      return null;
    }
    final data = doc.data();
    final email = data?['email'] as String? ?? '';
    if (email.isEmpty) {
      return null;
    }

    return AuthLoginData(
      email: email,
      user: UserRecord(
        id: doc.id,
        username: data?['username'] as String? ?? doc.id,
        fullName:
            data?['fullName'] as String? ??
            data?['username'] as String? ??
            doc.id,
        email: email,
        role: data?['role'] as String? ?? 'worker',
        active: data?['active'] as bool? ?? true,
        allowedProjectIds:
            (data?['allowedProjectIds'] as List<dynamic>? ?? <dynamic>[])
                .map((item) => item.toString())
                .toList(),
        allowedTaskGroupsByProject: parseAllowedTaskGroupsByProject(
          data?['allowedTaskGroupsByProject'],
        ),
      ),
    );
  }

  if (!normalizedLookup.contains('@')) {
    final generatedDocId = generateUserDocumentId(normalizedIdentifier);
    final directDoc = await firestore
        .collection('users')
        .doc(generatedDocId)
        .get();
    final directLoginData = buildLoginDataFromDoc(directDoc);
    if (directLoginData != null) {
      return directLoginData;
    }
  }

  QuerySnapshot<Map<String, dynamic>> snapshot;
  if (normalizedLookup.contains('@')) {
    snapshot = await firestore
        .collection('users')
        .where('email', isEqualTo: normalizedLookup)
        .limit(1)
        .get();
  } else {
    snapshot = await firestore
        .collection('users')
        .where('username', isEqualTo: normalizedLookup)
        .limit(1)
        .get();
  }

  if (snapshot.docs.isEmpty) {
    return null;
  }

  final doc = snapshot.docs.first;
  return buildLoginDataFromDoc(doc);
}

Future<String?> createFirebaseUserAccount({
  required String id,
  required String username,
  required String fullName,
  required String email,
  required String password,
  required String role,
  required bool active,
  required List<String> allowedProjectIds,
  required Map<String, List<String>> allowedTaskGroupsByProject,
}) async {
  try {
    if (kIsWeb) {
      return createOrUpdateUserOverHttp(
        endpoint:
            'https://europe-west1-dhego-fb024.cloudfunctions.net/createUserAccountHttp',
        payload: <String, dynamic>{
          'id': id,
          'username': username,
          'fullName': fullName,
          'email': email.trim().toLowerCase(),
          'password': password,
          'role': role,
          'active': active,
          'allowedProjectIds': allowedProjectIds,
          'allowedTaskGroupsByProject': allowedTaskGroupsByProject,
        },
        fallbackMessage: 'Nije moguće dodati novog korisnika.',
      );
    }

    final callable = firebaseFunctions.httpsCallable('createUserAccount');
    final result = await callable.call(<String, dynamic>{
      'id': id,
      'username': username,
      'fullName': fullName,
      'email': email.trim().toLowerCase(),
      'password': password,
      'role': role,
      'active': active,
      'allowedProjectIds': allowedProjectIds,
      'allowedTaskGroupsByProject': allowedTaskGroupsByProject,
    });
    final data = result.data;
    if (data is Map && data['success'] == false) {
      return data['message']?.toString() ??
          'Nije moguće dodati novog korisnika.';
    }
    return null;
  } on FirebaseFunctionsException catch (error) {
    return _friendlyUserAccountErrorMessage(
      error,
      fallbackMessage: 'Nije moguće dodati novog korisnika.',
    );
  } catch (_) {
    return 'Nije moguće dodati novog korisnika.';
  }
}

Future<String?> updateFirebaseUserAccount({
  required String id,
  required String username,
  required String fullName,
  required String email,
  required String role,
  required bool active,
  required List<String> allowedProjectIds,
  required Map<String, List<String>> allowedTaskGroupsByProject,
}) async {
  try {
    if (kIsWeb) {
      return createOrUpdateUserOverHttp(
        endpoint:
            'https://europe-west1-dhego-fb024.cloudfunctions.net/updateUserAccountHttp',
        payload: <String, dynamic>{
          'id': id,
          'username': username,
          'fullName': fullName,
          'email': email.trim().toLowerCase(),
          'role': role,
          'active': active,
          'allowedProjectIds': allowedProjectIds,
          'allowedTaskGroupsByProject': allowedTaskGroupsByProject,
        },
        fallbackMessage: 'Nije moguće ažurirati korisnika.',
      );
    }

    final callable = firebaseFunctions.httpsCallable('updateUserAccount');
    final result = await callable.call(<String, dynamic>{
      'id': id,
      'username': username,
      'fullName': fullName,
      'email': email.trim().toLowerCase(),
      'role': role,
      'active': active,
      'allowedProjectIds': allowedProjectIds,
      'allowedTaskGroupsByProject': allowedTaskGroupsByProject,
    });
    final data = result.data;
    if (data is Map && data['success'] == false) {
      return data['message']?.toString() ?? 'Nije moguće ažurirati korisnika.';
    }
    return null;
  } on FirebaseFunctionsException catch (error) {
    return _friendlyUserAccountErrorMessage(
      error,
      fallbackMessage: 'Nije moguće ažurirati korisnika.',
    );
  } catch (_) {
    return 'Nije moguće ažurirati korisnika.';
  }
}

String _friendlyUserAccountErrorMessage(
  FirebaseFunctionsException error, {
  required String fallbackMessage,
}) {
  if (error.message?.trim().isNotEmpty ?? false) {
    return error.message!.trim();
  }

  switch (error.code) {
    case 'already-exists':
      return 'Već postoji korisnik s tim podacima.';
    case 'permission-denied':
      return 'Nemaš dopuštenje za ovu promjenu.';
    case 'invalid-argument':
      return 'Podaci nisu ispravno uneseni.';
    case 'not-found':
      return 'Funkcija za korisnike nije dostupna. Provjeri deploy.';
    case 'unauthenticated':
      return 'Potrebna je prijava za ovu radnju.';
    default:
      return fallbackMessage;
  }
}

Future<String?> createOrUpdateUserOverHttp({
  required String endpoint,
  required Map<String, dynamic> payload,
  required String fallbackMessage,
}) async {
  try {
    final token = await firebaseAuth.currentUser?.getIdToken();
    if (token == null || token.isEmpty) {
      return 'Potrebna je prijava za ovu radnju.';
    }

    final response = await http.post(
      Uri.parse(endpoint),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(payload),
    );

    final rawBody = response.body.trim();
    if (rawBody.isEmpty) {
      return fallbackMessage;
    }

    final decoded = jsonDecode(rawBody);
    if (decoded is Map) {
      final success = decoded['success'];
      if (success == false) {
        return decoded['message']?.toString() ?? fallbackMessage;
      }
      return null;
    }

    return fallbackMessage;
  } catch (_) {
    return fallbackMessage;
  }
}

Future<int> syncFirebaseUsersFromAuth() async {
  if (kIsWeb) {
    final token = await firebaseAuth.currentUser?.getIdToken();
    if (token == null || token.isEmpty) {
      throw FirebaseFunctionsException(
        code: 'unauthenticated',
        message: 'Potrebna je prijava za ovu radnju.',
      );
    }

    final response = await http.post(
      Uri.parse(
        'https://europe-west1-dhego-fb024.cloudfunctions.net/syncAuthUsersToFirestoreHttp',
      ),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final rawBody = response.body.trim();
    if (rawBody.isEmpty) {
      return 0;
    }

    final decoded = jsonDecode(rawBody);
    if (decoded is Map) {
      if (decoded['success'] == false) {
        throw FirebaseFunctionsException(
          code: decoded['errorCode']?.toString() ?? 'internal',
          message:
              decoded['message']?.toString() ??
              'Nije moguće sinkronizirati korisnike.',
        );
      }

      return int.tryParse(decoded['syncedCount']?.toString() ?? '') ?? 0;
    }

    return 0;
  }

  final callable = firebaseFunctions.httpsCallable('syncAuthUsersToFirestore');
  final result = await callable.call();
  final data = result.data;
  if (data is Map) {
    final count = data['syncedCount'];
    if (count is int) {
      return count;
    }
    return int.tryParse(count?.toString() ?? '') ?? 0;
  }
  return 0;
}

Future<int> dispatchPendingOrdersNowOverHttp() async {
  final token = await firebaseAuth.currentUser?.getIdToken();
  if (token == null || token.isEmpty) {
    throw FirebaseFunctionsException(
      code: 'unauthenticated',
      message: 'Potrebna je prijava za ovu radnju.',
    );
  }

  final response = await http.post(
    Uri.parse(
      'https://europe-west1-dhego-fb024.cloudfunctions.net/dispatchPendingOrdersNowHttp',
    ),
    headers: <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    },
  );

  final rawBody = response.body.trim();
  if (rawBody.isEmpty) {
    return 0;
  }

  final decoded = jsonDecode(rawBody);
  if (decoded is Map) {
    if (decoded['success'] == false) {
      throw FirebaseFunctionsException(
        code: decoded['errorCode']?.toString() ?? 'internal',
        message:
            decoded['message']?.toString() ??
            'Narudžbe nije moguće odmah poslati.',
      );
    }

    return int.tryParse(decoded['sentOrderCount']?.toString() ?? '') ?? 0;
  }

  return 0;
}

Future<void> showProjectDialog(
  BuildContext context, {
  ProjectRecord? existingProject,
}) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  var active = existingProject?.active ?? true;
  var selectedProjectType = normalizeProjectType(
    existingProject?.projectType ?? projectTypeConstruction,
  );
  final users = await watchUsers().first;
  final siteManagers = <String, UserRecord>{
    for (final user in users)
      if (user.role == 'site_manager' && user.active) user.id: user,
  }.values.toList()..sort((a, b) => a.fullName.compareTo(b.fullName));
  final workerSelections = <String, bool>{};
  String? selectedManagerId = existingProject?.managerId.isNotEmpty == true
      ? existingProject!.managerId
      : null;

  if (selectedManagerId != null &&
      !siteManagers.any((manager) => manager.id == selectedManagerId)) {
    selectedManagerId = null;
  }

  if (existingProject != null) {
    idController.text = existingProject.id;
    nameController.text = existingProject.name;
  }

  for (final user in users.where((user) => user.role == 'worker')) {
    workerSelections[user.id] =
        existingProject != null &&
        user.allowedProjectIds.contains(existingProject.id);
  }

  await showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              existingProject == null
                  ? tr(context, 'add_project')
                  : '${tr(context, 'edit')} ${existingProject.name}',
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dialogField(
                      idController,
                      tr(context, 'document_id'),
                      enabled: existingProject == null,
                    ),
                    const SizedBox(height: 12),
                    _dialogField(nameController, tr(context, 'name')),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedProjectType,
                      decoration: InputDecoration(
                        labelText: tr(context, 'project_type'),
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        DropdownMenuItem<String>(
                          value: projectTypeConstruction,
                          child: Text(tr(context, 'project_type_construction')),
                        ),
                        DropdownMenuItem<String>(
                          value: projectTypeProduction,
                          child: Text(tr(context, 'project_type_production')),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          selectedProjectType = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedManagerId,
                      decoration: InputDecoration(
                        labelText: tr(context, 'select_site_manager'),
                        border: const OutlineInputBorder(),
                      ),
                      items: siteManagers
                          .map(
                            (manager) => DropdownMenuItem<String>(
                              value: manager.id,
                              child: Text(manager.fullName),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => selectedManagerId = value),
                    ),
                    CheckboxListTile(
                      value: active,
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr(context, 'active_label')),
                      onChanged: (value) =>
                          setState(() => active = value ?? true),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        tr(context, 'assigned_workers'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Column(
                          children: users
                              .where((user) => user.role == 'worker')
                              .map(
                                (user) => CheckboxListTile(
                                  value: workerSelections[user.id] ?? false,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(user.username),
                                  onChanged: (value) {
                                    setState(() {
                                      workerSelections[user.id] =
                                          value ?? false;
                                    });
                                  },
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  final projectId = idController.text.trim();
                  final now = Timestamp.now();
                  UserRecord? selectedManager;
                  for (final manager in siteManagers) {
                    if (manager.id == selectedManagerId) {
                      selectedManager = manager;
                      break;
                    }
                  }
                  await firestore.collection('projects').doc(projectId).set({
                    'name': nameController.text.trim(),
                    'projectType': normalizeProjectType(selectedProjectType),
                    'managerId': selectedManager?.id ?? '',
                    'managerName': selectedManager?.fullName ?? '',
                    'managerEmail': selectedManager?.email ?? '',
                    'active': active,
                    'workTaskTotalPoints':
                        existingProject?.workTaskTotalPoints ?? 0,
                    'workTaskCompletedPoints':
                        existingProject?.workTaskCompletedPoints ?? 0,
                    'workTaskProgressPercent':
                        existingProject?.workTaskProgressPercent ?? 0,
                    'createdAt': existingProject?.createdAt != null
                        ? Timestamp.fromDate(existingProject!.createdAt!)
                        : now,
                    'updatedAt': now,
                  });
                  final selectedWorkerIds = workerSelections.entries
                      .where((entry) => entry.value)
                      .map((entry) => entry.key)
                      .toSet();

                  for (final user in users.where(
                    (user) =>
                        user.role == 'worker' || user.role == 'site_manager',
                  )) {
                    final updatedProjects = <String>{...user.allowedProjectIds};

                    if (selectedWorkerIds.contains(user.id) ||
                        (user.role == 'site_manager' &&
                            user.id == selectedManagerId)) {
                      updatedProjects.add(projectId);
                    } else {
                      updatedProjects.remove(projectId);
                    }

                    await firestore.collection('users').doc(user.id).set({
                      'username': user.username,
                      'fullName': user.fullName,
                      'role': user.role,
                      'active': user.active,
                      'allowedProjectIds': updatedProjects.toList()..sort(),
                    }, SetOptions(merge: true));
                  }
                  if (context.mounted) {
                    Navigator.of(context).pop();
                    showSavedSnackBar(context);
                  }
                },
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showProjectUserAssignmentsDialog(
  BuildContext context, {
  required ProjectRecord project,
}) async {
  final allUsers = await watchUsers().first;
  final assignableUsers =
      allUsers
          .where(
            (user) =>
                user.active &&
                (user.role == 'worker' || user.role == 'obermonteur'),
          )
          .toList()
        ..sort((a, b) => a.fullName.compareTo(b.fullName));
  final selections = <String, bool>{
    for (final user in assignableUsers)
      user.id: user.allowedProjectIds.contains(project.id),
  };

  await showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              '${tr(context, 'assign_users_to_project')} - ${project.name}',
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'active_workers'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (assignableUsers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(tr(context, 'no_active_workers')),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        child: SingleChildScrollView(
                          child: Column(
                            children: assignableUsers
                                .map(
                                  (user) => CheckboxListTile(
                                    value: selections[user.id] ?? false,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(user.fullName),
                                    subtitle: Text(
                                      '${user.username} · ${formatUserRoleLabel(user.role)}',
                                    ),
                                    onChanged: (value) {
                                      setState(() {
                                        selections[user.id] = value ?? false;
                                      });
                                    },
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  for (final user in assignableUsers) {
                    final updatedProjects = <String>{...user.allowedProjectIds};
                    if (selections[user.id] ?? false) {
                      updatedProjects.add(project.id);
                    } else {
                      updatedProjects.remove(project.id);
                    }

                    await firestore.collection('users').doc(user.id).set({
                      'username': user.username,
                      'fullName': user.fullName,
                      'email': user.email,
                      'role': user.role,
                      'active': user.active,
                      'allowedProjectIds': updatedProjects.toList()..sort(),
                    }, SetOptions(merge: true));
                  }

                  if (context.mounted) {
                    Navigator.of(context).pop();
                    showSavedSnackBar(context);
                  }
                },
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showBuildingDialog(
  BuildContext context, {
  BuildingRecord? existingBuilding,
  String? preselectedProjectId,
  List<String>? allowedProjectIds,
}) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  String? selectedProjectId =
      existingBuilding?.projectId ?? preselectedProjectId;
  var active = existingBuilding?.active ?? true;
  final projects = (await watchAllProjects().first)
      .where(
        (project) =>
            allowedProjectIds == null || allowedProjectIds.contains(project.id),
      )
      .toList();

  if (existingBuilding != null) {
    idController.text = existingBuilding.id;
    nameController.text = existingBuilding.name;
  }

  await showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              existingBuilding == null
                  ? tr(context, 'add_building')
                  : '${tr(context, 'edit')} ${existingBuilding.name}',
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dialogField(
                      idController,
                      tr(context, 'document_id'),
                      enabled: existingBuilding == null,
                    ),
                    const SizedBox(height: 12),
                    _dialogField(nameController, tr(context, 'name')),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedProjectId,
                      decoration: InputDecoration(
                        labelText: tr(context, 'select_project'),
                        border: const OutlineInputBorder(),
                      ),
                      items: projects
                          .map(
                            (project) => DropdownMenuItem<String>(
                              value: project.id,
                              child: Text(project.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => selectedProjectId = value),
                    ),
                    CheckboxListTile(
                      value: active,
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr(context, 'active_label')),
                      onChanged: (value) =>
                          setState(() => active = value ?? true),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: selectedProjectId == null
                    ? null
                    : () async {
                        final now = Timestamp.now();
                        await firestore
                            .collection('buildings')
                            .doc(idController.text.trim())
                            .set({
                              'name': nameController.text.trim(),
                              'projectId': selectedProjectId,
                              'active': active,
                              'workTaskTotalPoints':
                                  existingBuilding?.workTaskTotalPoints ?? 0,
                              'workTaskCompletedPoints':
                                  existingBuilding?.workTaskCompletedPoints ??
                                  0,
                              'workTaskProgressPercent':
                                  existingBuilding?.workTaskProgressPercent ??
                                  0,
                              'createdAt': existingBuilding?.createdAt != null
                                  ? Timestamp.fromDate(
                                      existingBuilding!.createdAt!,
                                    )
                                  : now,
                              'updatedAt': now,
                            });
                        if (context.mounted) {
                          Navigator.of(context).pop();
                          showSavedSnackBar(context);
                        }
                      },
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showWohnungDialog(
  BuildContext context, {
  WohnungRecord? existingWohnung,
  String? preselectedBuildingId,
  List<String>? allowedProjectIds,
}) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  String? selectedBuildingId =
      existingWohnung?.buildingId ?? preselectedBuildingId;
  var active = existingWohnung?.active ?? true;
  final buildings = (await watchAllBuildings().first)
      .where(
        (building) =>
            allowedProjectIds == null ||
            allowedProjectIds.contains(building.projectId),
      )
      .toList();

  if (existingWohnung != null) {
    idController.text = existingWohnung.id;
    nameController.text = existingWohnung.name;
  }

  await showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              existingWohnung == null
                  ? tr(context, 'add_wohnung')
                  : '${tr(context, 'edit')} ${existingWohnung.name}',
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dialogField(
                      idController,
                      tr(context, 'document_id'),
                      enabled: existingWohnung == null,
                    ),
                    const SizedBox(height: 12),
                    _dialogField(nameController, tr(context, 'name')),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedBuildingId,
                      decoration: InputDecoration(
                        labelText: tr(context, 'select_building_admin'),
                        border: const OutlineInputBorder(),
                      ),
                      items: buildings
                          .map(
                            (building) => DropdownMenuItem<String>(
                              value: building.id,
                              child: Text(building.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => selectedBuildingId = value),
                    ),
                    CheckboxListTile(
                      value: active,
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr(context, 'active_label')),
                      onChanged: (value) =>
                          setState(() => active = value ?? true),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: selectedBuildingId == null
                    ? null
                    : () async {
                        await firestore
                            .collection('wohnungs')
                            .doc(idController.text.trim())
                            .set({
                              'name': nameController.text.trim(),
                              'buildingId': selectedBuildingId,
                              'active': active,
                            });
                        if (context.mounted) {
                          Navigator.of(context).pop();
                          showSavedSnackBar(context);
                        }
                      },
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showMaterialDialog(
  BuildContext context, {
  MaterialRecord? existingMaterial,
}) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  var active = existingMaterial?.active ?? true;

  if (existingMaterial != null) {
    idController.text = existingMaterial.id;
    nameController.text = existingMaterial.name;
  }

  await showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              existingMaterial == null
                  ? tr(context, 'add_material')
                  : '${tr(context, 'edit')} ${existingMaterial.name}',
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dialogField(
                      idController,
                      tr(context, 'document_id'),
                      enabled: existingMaterial == null,
                    ),
                    const SizedBox(height: 12),
                    _dialogField(nameController, tr(context, 'name')),
                    CheckboxListTile(
                      value: active,
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr(context, 'active_label')),
                      onChanged: (value) =>
                          setState(() => active = value ?? true),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  await firestore
                      .collection('materials')
                      .doc(idController.text.trim())
                      .set({
                        'name': nameController.text.trim(),
                        'active': active,
                      }, SetOptions(merge: true));
                  if (context.mounted) {
                    Navigator.of(context).pop();
                    showSavedSnackBar(context);
                  }
                },
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showUserDialog(
  BuildContext context, {
  UserRecord? existingUser,
}) async {
  final idController = TextEditingController();
  final usernameController = TextEditingController();
  final emailController = TextEditingController();
  final allowedProjectsController = TextEditingController();
  var selectedRole = existingUser?.role ?? 'worker';
  var active = existingUser?.active ?? true;

  if (existingUser != null) {
    idController.text = existingUser.id;
    usernameController.text = existingUser.username;
    emailController.text = existingUser.email;
    allowedProjectsController.text = existingUser.allowedProjectIds.join(', ');
  }

  await showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              existingUser == null
                  ? tr(context, 'add_user')
                  : '${tr(context, 'edit')} ${existingUser.username}',
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _dialogField(
                    idController,
                    tr(context, 'document_id'),
                    enabled: existingUser == null,
                  ),
                  const SizedBox(height: 12),
                  _dialogField(
                    usernameController,
                    tr(context, 'username_label'),
                    onChanged: existingUser == null
                        ? (value) {
                            idController.text = generateUserDocumentId(value);
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _dialogField(emailController, tr(context, 'email')),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: InputDecoration(
                      labelText: tr(context, 'role_label'),
                      border: const OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'worker', child: Text('radnik')),
                      DropdownMenuItem(
                        value: 'site_manager',
                        child: Text('voditelj gradilišta'),
                      ),
                      DropdownMenuItem(
                        value: 'obermonteur',
                        child: Text('nadmonter'),
                      ),
                      DropdownMenuItem(value: 'admin', child: Text('admin')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          selectedRole = value;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  _dialogField(
                    allowedProjectsController,
                    tr(context, 'allowed_projects'),
                  ),
                  CheckboxListTile(
                    value: active,
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, 'active_label')),
                    onChanged: (value) =>
                        setState(() => active = value ?? true),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  final allowedProjects = allowedProjectsController.text
                      .split(',')
                      .map((value) => value.trim())
                      .where((value) => value.isNotEmpty)
                      .toList();

                  await firestore
                      .collection('users')
                      .doc(idController.text.trim())
                      .set({
                        'username': usernameController.text.trim(),
                        'email': emailController.text.trim(),
                        'role': selectedRole,
                        'active': active,
                        'allowedProjectIds': allowedProjects,
                      });
                  if (context.mounted) {
                    Navigator.of(context).pop();
                    showSavedSnackBar(context);
                  }
                },
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showUserDialogV2(
  BuildContext context, {
  UserRecord? existingUser,
  bool allowRoleSelection = true,
  String? forcedRole,
  List<String>? restrictProjectIds,
  List<String>? allowedRoles,
}) async {
  final idController = TextEditingController();
  final usernameController = TextEditingController();
  final fullNameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  var selectedRole = existingUser?.role ?? 'worker';
  var active = existingUser?.active ?? true;
  final projects = (await watchAllProjects().first)
      .where(
        (project) =>
            restrictProjectIds == null ||
            restrictProjectIds.contains(project.id),
      )
      .toList();
  final taskGroupOptionsByProject = await fetchTaskGroupOptionsByProjectIds(
    projects.map((project) => project.id).toList(),
  );
  final projectSelections = <String, bool>{};
  final selectedTaskGroupsByProject = <String, Set<String>>{};
  if (!allowRoleSelection && forcedRole != null) {
    selectedRole = forcedRole;
  }

  final selectableRoles =
      allowedRoles ??
      const <String>['worker', 'site_manager', 'obermonteur', 'admin'];

  if (existingUser != null) {
    idController.text = existingUser.id;
    usernameController.text = existingUser.username;
    fullNameController.text = existingUser.fullName;
    emailController.text = existingUser.email;
  }

  for (final project in projects) {
    projectSelections[project.id] =
        existingUser?.allowedProjectIds.contains(project.id) ?? false;
    selectedTaskGroupsByProject[project.id] = {
      ...(existingUser?.allowedTaskGroupsByProject[project.id] ?? <String>[]),
    };
  }

  await showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              existingUser == null
                  ? tr(context, 'add_user')
                  : '${tr(context, 'edit')} ${existingUser.username}',
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dialogField(
                      usernameController,
                      tr(context, 'username_label'),
                      onChanged: existingUser == null
                          ? (value) {
                              idController.text = generateUserDocumentId(value);
                            }
                          : null,
                    ),
                    const SizedBox(height: 12),
                    _dialogField(
                      fullNameController,
                      tr(context, 'full_name_label'),
                    ),
                    const SizedBox(height: 12),
                    _dialogField(emailController, tr(context, 'email')),
                    const SizedBox(height: 12),
                    if (existingUser == null) ...[
                      _dialogField(
                        passwordController,
                        tr(context, 'initial_password'),
                        obscureText: true,
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          tr(context, 'password_min_length_hint'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (allowRoleSelection)
                      DropdownButtonFormField<String>(
                        initialValue: selectedRole,
                        decoration: InputDecoration(
                          labelText: tr(context, 'role_label'),
                          border: const OutlineInputBorder(),
                        ),
                        items: selectableRoles
                            .map(
                              (role) => DropdownMenuItem(
                                value: role,
                                child: Text(formatUserRoleLabel(role)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              selectedRole = value;
                            });
                          }
                        },
                      )
                    else
                      _dialogField(
                        TextEditingController(
                          text: formatUserRoleLabel(forcedRole ?? selectedRole),
                        ),
                        tr(context, 'role_label'),
                        enabled: false,
                      ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        tr(context, 'assigned_projects'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Column(
                          children: projects
                              .map(
                                (project) => CheckboxListTile(
                                  value: projectSelections[project.id] ?? false,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(project.name),
                                  onChanged: (value) {
                                    setState(() {
                                      projectSelections[project.id] =
                                          value ?? false;
                                    });
                                  },
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        tr(context, 'project_task_roles_label'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...projects
                        .where(
                          (project) => projectSelections[project.id] ?? false,
                        )
                        .map((project) {
                          final availableTaskGroups =
                              taskGroupOptionsByProject[project.id] ??
                              const <String>[];
                          final selectedTaskGroups =
                              selectedTaskGroupsByProject[project.id] ??
                              <String>{};

                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    project.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 8),
                                  if (availableTaskGroups.isEmpty)
                                    Text(
                                      tr(context, 'no_task_roles_available'),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    )
                                  else
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: availableTaskGroups
                                          .map(
                                            (taskGroup) => FilterChip(
                                              label: Text(taskGroup),
                                              selected: selectedTaskGroups
                                                  .contains(taskGroup),
                                              onSelected: (selected) {
                                                setState(() {
                                                  final updated =
                                                      selectedTaskGroupsByProject[project
                                                          .id] ??
                                                      <String>{};
                                                  if (selected) {
                                                    updated.add(taskGroup);
                                                  } else {
                                                    updated.remove(taskGroup);
                                                  }
                                                  selectedTaskGroupsByProject[project
                                                          .id] =
                                                      updated;
                                                });
                                              },
                                            ),
                                          )
                                          .toList(),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }),
                    CheckboxListTile(
                      value: active,
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr(context, 'active_label')),
                      onChanged: (value) =>
                          setState(() => active = value ?? true),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  final id = idController.text.trim();
                  final username = usernameController.text.trim();
                  final fullName = fullNameController.text.trim();
                  final email = emailController.text.trim().toLowerCase();
                  final password = passwordController.text;
                  final allowedProjectIds =
                      projectSelections.entries
                          .where((entry) => entry.value)
                          .map((entry) => entry.key)
                          .toList()
                        ..sort();
                  final allowedTaskGroupsByProject = <String, List<String>>{};
                  for (final projectId in allowedProjectIds) {
                    final selectedTaskGroups =
                        (selectedTaskGroupsByProject[projectId] ?? <String>{})
                            .where((item) => item.trim().isNotEmpty)
                            .toList()
                          ..sort(
                            (a, b) =>
                                a.toLowerCase().compareTo(b.toLowerCase()),
                          );
                    if (taskGroupOptionsByProject.containsKey(projectId) ||
                        existingUser?.allowedTaskGroupsByProject.containsKey(
                              projectId,
                            ) ==
                            true) {
                      allowedTaskGroupsByProject[projectId] =
                          selectedTaskGroups;
                    }
                  }

                  if (id.isEmpty ||
                      username.isEmpty ||
                      fullName.isEmpty ||
                      email.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr(context, 'user_create_error'))),
                    );
                    return;
                  }

                  if (existingUser == null && password.trim().length < 6) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(tr(context, 'password_min_length_hint')),
                      ),
                    );
                    return;
                  }

                  final allUsers = await watchUsers().first;
                  final duplicateId =
                      existingUser == null &&
                      allUsers.any(
                        (user) =>
                            user.id.trim().toLowerCase() == id.toLowerCase(),
                      );
                  if (duplicateId) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Već postoji korisnik s tim ID-em.'),
                        ),
                      );
                    }
                    return;
                  }

                  final duplicateEmail = allUsers.any(
                    (user) =>
                        user.email.trim().toLowerCase() == email &&
                        user.id != existingUser?.id,
                  );
                  if (duplicateEmail) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Već postoji korisnik s tim e-mailom.'),
                        ),
                      );
                    }
                    return;
                  }

                  try {
                    if (existingUser == null) {
                      final errorMessage = await createFirebaseUserAccount(
                        id: id,
                        username: username,
                        fullName: fullName,
                        email: email,
                        password: password,
                        role: selectedRole,
                        active: active,
                        allowedProjectIds: allowedProjectIds,
                        allowedTaskGroupsByProject: allowedTaskGroupsByProject,
                      );
                      if (errorMessage != null) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text(errorMessage)));
                        }
                        return;
                      }
                    } else {
                      final errorMessage = await updateFirebaseUserAccount(
                        id: id,
                        username: username,
                        fullName: fullName,
                        email: email,
                        role: selectedRole,
                        active: active,
                        allowedProjectIds: allowedProjectIds,
                        allowedTaskGroupsByProject: allowedTaskGroupsByProject,
                      );
                      if (errorMessage != null) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text(errorMessage)));
                        }
                        return;
                      }
                    }

                    if (context.mounted) {
                      Navigator.of(context).pop();
                      showSavedSnackBar(context);
                    }
                  } on FirebaseFunctionsException catch (error) {
                    if (context.mounted) {
                      final message = error.code == 'not-found'
                          ? tr(context, 'user_create_deploy_hint')
                          : (error.message?.isNotEmpty ?? false)
                          ? error.message!
                          : '${tr(context, 'user_create_error')} (${error.code})';
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(message)));
                    }
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(tr(context, 'user_create_error')),
                        ),
                      );
                    }
                  }
                },
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      );
    },
  );
}

class StructureImportSummary {
  const StructureImportSummary({
    required this.projects,
    required this.buildings,
    required this.wohnungs,
    required this.tasks,
    required this.skippedEntries,
    required this.projectName,
  });

  final int projects;
  final int buildings;
  final int wohnungs;
  final int tasks;
  final int skippedEntries;
  final String projectName;
}

enum _StructureImportMode { createNew, syncExisting }

Future<void> showStructureImportDialog(
  BuildContext context,
  DemoUser currentUser,
) async {
  final allProjects = await watchAllProjects().first;
  final availableProjects =
      allProjects
          .where(
            (project) =>
                currentUser.role == 'admin' ||
                currentUser.allowedProjects.contains(project.id),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  DropzoneViewController? dropzoneController;
  var isDragging = false;
  var isImporting = false;
  _WorkbookImportDraft? importDraft;
  String? loadedFileName;
  var importMode = _StructureImportMode.createNew;
  String? selectedProjectId;
  var selectedProjectType = projectTypeConstruction;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> loadImportedFile({
            required String fileName,
            required Uint8List bytes,
          }) async {
            final parsedDraft = parseStructureImportBytes(fileName, bytes);
            if (parsedDraft == null) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(tr(context, 'file_import_not_supported')),
                  ),
                );
              }
              return;
            }

            setState(() {
              importDraft = parsedDraft;
              loadedFileName = fileName;
            });
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                SnackBar(content: Text(tr(context, 'file_loaded'))),
              );
            }
          }

          Future<void> handleDroppedFile(dynamic file) async {
            setState(() => isDragging = false);
            final currentDropzoneController = dropzoneController;
            if (currentDropzoneController == null || file == null) {
              return;
            }

            try {
              final fileName = await currentDropzoneController.getFilename(
                file,
              );
              final bytes = await currentDropzoneController.getFileData(file);
              await loadImportedFile(fileName: fileName, bytes: bytes);
            } catch (_) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(tr(context, 'file_import_not_supported')),
                  ),
                );
              }
            }
          }

          return AlertDialog(
            scrollable: true,
            title: Text(tr(context, 'import_data')),
            content: SizedBox(
              width: 700,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, 'import_structure_hint'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<_StructureImportMode>(
                    value: importMode,
                    decoration: InputDecoration(
                      labelText: tr(context, 'import_mode_label'),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: _StructureImportMode.createNew,
                        child: Text(tr(context, 'import_mode_new_project')),
                      ),
                      DropdownMenuItem(
                        value: _StructureImportMode.syncExisting,
                        child: Text(tr(context, 'import_mode_sync_project')),
                      ),
                    ],
                    onChanged: isImporting
                        ? null
                        : (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              importMode = value;
                              if (importMode !=
                                  _StructureImportMode.syncExisting) {
                                selectedProjectId = null;
                                selectedProjectType = projectTypeConstruction;
                              }
                            });
                          },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: selectedProjectType,
                    decoration: InputDecoration(
                      labelText: tr(context, 'project_type'),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem<String>(
                        value: projectTypeConstruction,
                        child: Text(tr(context, 'project_type_construction')),
                      ),
                      DropdownMenuItem<String>(
                        value: projectTypeProduction,
                        child: Text(tr(context, 'project_type_production')),
                      ),
                    ],
                    onChanged: isImporting
                        ? null
                        : (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() => selectedProjectType = value);
                          },
                  ),
                  if (importMode == _StructureImportMode.syncExisting) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value:
                          availableProjects.any(
                            (project) => project.id == selectedProjectId,
                          )
                          ? selectedProjectId
                          : null,
                      decoration: InputDecoration(
                        labelText: tr(context, 'select_existing_project'),
                        border: const OutlineInputBorder(),
                      ),
                      items: availableProjects
                          .map(
                            (project) => DropdownMenuItem<String>(
                              value: project.id,
                              child: Text(project.name),
                            ),
                          )
                          .toList(),
                      onChanged: isImporting
                          ? null
                          : (value) {
                              ProjectRecord? selectedProject;
                              for (final project in availableProjects) {
                                if (project.id == value) {
                                  selectedProject = project;
                                  break;
                                }
                              }
                              setState(() {
                                selectedProjectId = value;
                                if (selectedProject != null) {
                                  selectedProjectType =
                                      selectedProject!.projectType;
                                }
                              });
                            },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr(context, 'import_sync_hint'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final selectedFile = await pickStructureImportFile();
                      if (selectedFile == null) {
                        return;
                      }
                      await loadImportedFile(
                        fileName: selectedFile.fileName,
                        bytes: selectedFile.bytes,
                      );
                    },
                    icon: const Icon(Icons.upload_file_outlined),
                    label: Text(tr(context, 'upload_file')),
                  ),
                  if (kIsWeb) ...[
                    const SizedBox(height: 12),
                    Container(
                      height: 110,
                      decoration: BoxDecoration(
                        color: isDragging
                            ? Colors.teal.withValues(alpha: 0.08)
                            : Colors.grey.shade50,
                        border: Border.all(
                          color: isDragging
                              ? Colors.teal
                              : Colors.grey.shade400,
                          width: 1.5,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Stack(
                        children: [
                          DropzoneView(
                            operation: DragOperation.copy,
                            cursor: CursorType.grab,
                            onCreated: (ctrl) => dropzoneController = ctrl,
                            onHover: () => setState(() => isDragging = true),
                            onLeave: () => setState(() => isDragging = false),
                            onDropFile: (file) async {
                              await handleDroppedFile(file);
                            },
                            onDropFiles: (files) async {
                              if (files == null || files.isEmpty) {
                                setState(() => isDragging = false);
                                return;
                              }
                              await handleDroppedFile(files.first);
                            },
                          ),
                          IgnorePointer(
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.file_upload_outlined,
                                    color: isDragging
                                        ? Colors.teal
                                        : Colors.grey,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    tr(context, 'drop_file_here'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (importDraft != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(context, 'import_preview'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${tr(context, 'selected_file')}: ${loadedFileName ?? '-'}',
                          ),
                          Text(
                            '${tr(context, 'project_label')}: ${importMode == _StructureImportMode.syncExisting && selectedProjectId != null ? availableProjects.firstWhere((project) => project.id == selectedProjectId).name : importDraft!.projectName}',
                          ),
                          Text(
                            '${tr(context, 'buildings_tab')}: ${importDraft!.buildingNames.length}',
                          ),
                          Text(
                            '${tr(context, 'apartments_label')}: ${importDraft!.wohnungen.length}',
                          ),
                          Text(
                            '${tr(context, 'work_tasks_label')}: ${importDraft!.tasks.length}',
                          ),
                          if (importDraft!.skipped.isNotEmpty)
                            Text(
                              '${tr(context, 'skipped_entries')}: ${importDraft!.skipped.length}',
                              style: TextStyle(color: Colors.orange.shade800),
                            ),
                          if (importDraft!.skipped.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            ...importDraft!.skipped
                                .take(5)
                                .map(
                                  (entry) => Text(
                                    '• $entry',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton.icon(
                onPressed:
                    importDraft == null ||
                        isImporting ||
                        (importMode == _StructureImportMode.syncExisting &&
                            selectedProjectId == null)
                    ? null
                    : () async {
                        setState(() => isImporting = true);
                        StructureImportSummary summary;
                        try {
                          summary = await importStructureData(
                            draft: importDraft!,
                            currentUser: currentUser,
                            synchronizeExisting:
                                importMode == _StructureImportMode.syncExisting,
                            selectedProjectId: selectedProjectId,
                            selectedProjectType: selectedProjectType,
                          );
                        } catch (error) {
                          setState(() => isImporting = false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())),
                            );
                          }
                          return;
                        }

                        setState(() => isImporting = false);
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                        if (!context.mounted) {
                          return;
                        }

                        final message =
                            StringBuffer(tr(context, 'import_success'))..write(
                              ' (${summary.projectName}, ${summary.buildings} ${tr(context, 'buildings_tab').toLowerCase()}, ${summary.wohnungs} ${tr(context, 'apartments_label').toLowerCase()}, ${summary.tasks} ${tr(context, 'work_tasks_label').toLowerCase()})',
                            );
                        if (summary.skippedEntries > 0) {
                          message.write(
                            '\n${tr(context, 'skipped_entries')}: ${summary.skippedEntries}',
                          );
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(message.toString())),
                        );
                      },
                icon: const Icon(Icons.file_upload_outlined),
                label: Text(tr(context, 'import')),
              ),
            ],
          );
        },
      );
    },
  );
}

class _ProjectMaterialImportDraft {
  const _ProjectMaterialImportDraft({
    required this.materials,
    required this.sheetNames,
  });

  final List<Map<String, dynamic>> materials;
  final Set<String> sheetNames;
}

Future<void> showProjectMaterialImportDialog(
  BuildContext context, {
  required DemoUser currentUser,
  required ProjectRecord project,
}) async {
  final canImport =
      currentUser.role == 'admin' ||
      (isManagerLikeRole(currentUser.role) &&
          currentUser.allowedProjects.contains(project.id));
  if (!canImport) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'import_permission_denied'))),
    );
    return;
  }

  DropzoneViewController? dropzoneController;
  var isDragging = false;
  var isImporting = false;
  _ProjectMaterialImportDraft? importDraft;
  String? loadedFileName;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> loadImportedFile({
            required String fileName,
            required Uint8List bytes,
          }) async {
            final parsedDraft = parseProjectMaterialImportBytes(
              fileName,
              bytes,
            );
            if (parsedDraft == null) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      tr(context, 'project_material_import_not_supported'),
                    ),
                  ),
                );
              }
              return;
            }

            setState(() {
              importDraft = parsedDraft;
              loadedFileName = fileName;
            });
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                SnackBar(content: Text(tr(context, 'file_loaded'))),
              );
            }
          }

          Future<void> handleDroppedFile(dynamic file) async {
            setState(() => isDragging = false);
            final currentDropzoneController = dropzoneController;
            if (currentDropzoneController == null || file == null) {
              return;
            }

            try {
              final fileName = await currentDropzoneController.getFilename(
                file,
              );
              final bytes = await currentDropzoneController.getFileData(file);
              await loadImportedFile(fileName: fileName, bytes: bytes);
            } catch (_) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      tr(context, 'project_material_import_not_supported'),
                    ),
                  ),
                );
              }
            }
          }

          return AlertDialog(
            scrollable: true,
            title: Text(tr(context, 'project_material_import_title')),
            content: SizedBox(
              width: 700,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, 'project_material_import_hint'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${tr(context, 'project_label')}: ${project.name}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final selectedFile = await pickStructureImportFile();
                      if (selectedFile == null) {
                        return;
                      }
                      await loadImportedFile(
                        fileName: selectedFile.fileName,
                        bytes: selectedFile.bytes,
                      );
                    },
                    icon: const Icon(Icons.upload_file_outlined),
                    label: Text(tr(context, 'upload_file')),
                  ),
                  if (kIsWeb) ...[
                    const SizedBox(height: 12),
                    Container(
                      height: 110,
                      decoration: BoxDecoration(
                        color: isDragging
                            ? Colors.teal.withValues(alpha: 0.08)
                            : Colors.grey.shade50,
                        border: Border.all(
                          color: isDragging
                              ? Colors.teal
                              : Colors.grey.shade400,
                          width: 1.5,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Stack(
                        children: [
                          DropzoneView(
                            operation: DragOperation.copy,
                            cursor: CursorType.grab,
                            onCreated: (ctrl) => dropzoneController = ctrl,
                            onHover: () => setState(() => isDragging = true),
                            onLeave: () => setState(() => isDragging = false),
                            onDropFile: (file) async {
                              await handleDroppedFile(file);
                            },
                            onDropFiles: (files) async {
                              if (files == null || files.isEmpty) {
                                setState(() => isDragging = false);
                                return;
                              }
                              await handleDroppedFile(files.first);
                            },
                          ),
                          IgnorePointer(
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.file_upload_outlined,
                                    color: isDragging
                                        ? Colors.teal
                                        : Colors.grey,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    tr(context, 'drop_file_here'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (importDraft != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(context, 'import_preview'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${tr(context, 'selected_file')}: ${loadedFileName ?? '-'}',
                          ),
                          Text(
                            '${tr(context, 'materials_tab')}: ${importDraft!.materials.length}',
                          ),
                          Text(
                            '${tr(context, 'categories_label')}: ${importDraft!.sheetNames.length}',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tr(
                              context,
                              'project_material_import_replace_warning',
                            ),
                            style: TextStyle(color: Colors.orange.shade800),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton.icon(
                onPressed: importDraft == null || isImporting
                    ? null
                    : () async {
                        setState(() => isImporting = true);
                        try {
                          final importedCount = await importProjectMaterials(
                            project: project,
                            draft: importDraft!,
                          );
                          setState(() => isImporting = false);
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  tr(context, 'project_material_import_success')
                                      .replaceFirst(
                                        '{count}',
                                        importedCount.toString(),
                                      )
                                      .replaceFirst('{project}', project.name),
                                ),
                              ),
                            );
                          }
                        } catch (error) {
                          setState(() => isImporting = false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())),
                            );
                          }
                        }
                      },
                icon: const Icon(Icons.file_upload_outlined),
                label: Text(tr(context, 'import')),
              ),
            ],
          );
        },
      );
    },
  );
}

class _ImportFilePayload {
  const _ImportFilePayload({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;
}

Future<_ImportFilePayload?> pickStructureImportFile() async {
  final uploadInput = html.FileUploadInputElement()
    ..accept = '.xlsx'
    ..multiple = false
    ..style.display = 'none';
  html.document.body?.append(uploadInput);
  uploadInput.click();
  await uploadInput.onChange.first;
  final file = uploadInput.files?.first;
  uploadInput.remove();
  if (file == null) {
    return null;
  }

  final fileName = file.name.toLowerCase();
  final reader = html.FileReader();
  reader.readAsDataUrl(file);
  await reader.onLoad.first;
  final result = reader.result?.toString();
  if (result == null || !result.contains(',')) {
    return null;
  }

  final bytes = base64Decode(result.split(',').last);
  return _ImportFilePayload(fileName: fileName, bytes: bytes);
}

Future<_ImportFilePayload?> pickPdfDocumentFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
    allowMultiple: false,
    withData: true,
  );
  if (result == null || result.files.isEmpty) {
    return null;
  }

  final file = result.files.single;
  final bytes =
      file.bytes ??
      (file.path == null ? null : await XFile(file.path!).readAsBytes());
  if (bytes == null || bytes.isEmpty) {
    return null;
  }

  return _ImportFilePayload(
    fileName: sanitizeSharedDocumentFileName(file.name),
    bytes: bytes,
  );
}

Future<Uint8List?> pickImageBytesForWeb() async {
  final uploadInput = html.FileUploadInputElement()
    ..accept = 'image/*'
    ..multiple = false
    ..style.display = 'none';
  html.document.body?.append(uploadInput);
  uploadInput.click();
  await uploadInput.onChange.first;
  final file = uploadInput.files?.first;
  uploadInput.remove();
  if (file == null) {
    return null;
  }

  final reader = html.FileReader();
  reader.readAsDataUrl(file);
  await reader.onLoad.first;
  final result = reader.result?.toString();
  if (result == null || !result.contains(',')) {
    return null;
  }

  return Uint8List.fromList(base64Decode(result.split(',').last));
}

_WorkbookImportDraft? parseStructureImportBytes(
  String fileName,
  Uint8List bytes,
) {
  final normalizedName = fileName.toLowerCase();

  if (normalizedName.endsWith('.xlsx')) {
    try {
      final excel = Excel.decodeBytes(bytes);
      return buildWorkbookImportDraft(fileName, excel);
    } catch (_) {
      return null;
    }
  }

  return null;
}

_ProjectMaterialImportDraft? parseProjectMaterialImportBytes(
  String fileName,
  Uint8List bytes,
) {
  final normalizedName = fileName.toLowerCase();
  if (!normalizedName.endsWith('.xlsx')) {
    return null;
  }

  try {
    final excel = Excel.decodeBytes(bytes);
    final materials = <Map<String, dynamic>>[];
    final sheetNames = <String>{};

    for (final sheetName in excel.tables.keys) {
      final table = excel.tables[sheetName];
      if (table == null) {
        continue;
      }

      final state = _ProjectMaterialCategoryState();
      for (final row in table.rows) {
        if (row.isEmpty) {
          continue;
        }

        final columnA = _projectMaterialCellText(row, 0);
        final columnB = _projectMaterialCellText(row, 1);
        final supplier = _projectMaterialCellText(row, 2);

        if (_looksLikeProjectMaterialHeader(columnA, columnB, supplier)) {
          continue;
        }

        if (columnA.isEmpty && columnB.isEmpty && supplier.isEmpty) {
          continue;
        }

        if (_isProjectMaterialCategoryRow(columnA, columnB, supplier)) {
          final categoryValue = columnB.trim().isNotEmpty
              ? columnB.trim()
              : columnA.trim();
          final fillHex =
              _projectMaterialNormalizedFillHex(row, 1) ??
              _projectMaterialNormalizedFillHex(row, 0);
          state.applyCategory(categoryValue, fillHex);
          continue;
        }

        final articleNumber = columnA.trim();
        final name = columnB.trim();
        if (articleNumber.isEmpty || name.isEmpty) {
          continue;
        }

        state.markItem();
        sheetNames.add(sheetName.trim());
        materials.add(<String, dynamic>{
          'id': _buildProjectMaterialId(
            sheetName: sheetName,
            articleNumber: articleNumber,
            name: name,
          ),
          'name': name,
          'active': true,
          'articleNumber': articleNumber,
          'supplier': supplier.trim(),
          'sheetName': sheetName.trim(),
          'categorySheet': sheetName.trim(),
          'level1': state.level1,
          'level2': state.level2,
          'level3': state.level3,
          'level4': state.level4,
          'orangeCategory': state.level1,
          'greenCategory': state.level2,
          'blueCategory': state.level3,
          'purpleCategory': state.level4,
        });
      }
    }

    if (materials.isEmpty) {
      return null;
    }

    return _ProjectMaterialImportDraft(
      materials: materials,
      sheetNames: sheetNames,
    );
  } catch (_) {
    return null;
  }
}

Future<int> importProjectMaterials({
  required ProjectRecord project,
  required _ProjectMaterialImportDraft draft,
}) async {
  final existingSnapshot = await firestore
      .collection('project_materials')
      .where('projectId', isEqualTo: project.id)
      .get();

  for (var index = 0; index < existingSnapshot.docs.length; index += 400) {
    final chunk = existingSnapshot.docs.skip(index).take(400);
    final batch = firestore.batch();
    for (final doc in chunk) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }

  final now = Timestamp.now();
  for (var index = 0; index < draft.materials.length; index += 400) {
    final chunk = draft.materials.skip(index).take(400);
    final batch = firestore.batch();
    for (final material in chunk) {
      final materialId = material['id'] as String? ?? '';
      final docRef = firestore
          .collection('project_materials')
          .doc('${project.id}.$materialId');
      batch.set(docRef, <String, dynamic>{
        ...material,
        'projectId': project.id,
        'projectName': project.name,
        'createdAt': now,
        'updatedAt': now,
      });
    }
    await batch.commit();
  }

  return draft.materials.length;
}

void downloadStructureImportTemplate(AppLanguage language) {
  final excel = Excel.createExcel();
  final sheet = excel['Import'];
  final optionsSheet = excel['Opcije'];
  final isGerman = language == AppLanguage.de;
  optionsSheet.appendRow([
    TextCellValue(isGerman ? 'Checklisten-Typ' : 'Tip checkliste'),
  ]);
  optionsSheet.appendRow([TextCellValue('Medientrager')]);
  optionsSheet.appendRow([TextCellValue('Strang')]);
  optionsSheet.appendRow([TextCellValue('Strang+Seiten')]);

  sheet.appendRow([
    TextCellValue(
      isGerman
          ? 'Upute: U stupcu Checklisten-Typ koristite samo vrijednosti iz lista "Opcije".'
          : 'Upute: U stupcu Tip checkliste koristite samo vrijednosti iz lista "Opcije".',
    ),
  ]);
  sheet.appendRow([
    TextCellValue('Projekt'),
    TextCellValue(isGerman ? 'Gebäude' : 'Zgrada'),
    TextCellValue(isGerman ? 'Wohnung' : 'Stan'),
    TextCellValue(isGerman ? 'Mitarbeiter' : 'Radnici'),
    TextCellValue(isGerman ? 'Checklisten-Typ' : 'Tip checkliste'),
  ]);
  sheet.appendRow([
    TextCellValue('Projekt 1'),
    TextCellValue('Z1'),
    TextCellValue(isGerman ? 'WE 1' : 'WE 1'),
    TextCellValue('marko;ivan'),
    TextCellValue('Medientrager'),
  ]);
  sheet.appendRow([
    TextCellValue('Projekt 1'),
    TextCellValue('Z1'),
    TextCellValue(isGerman ? 'WE 2' : 'WE 2'),
    TextCellValue('marko'),
    TextCellValue('Strang'),
  ]);
  sheet.appendRow([
    TextCellValue('Projekt 1'),
    TextCellValue('Z2'),
    TextCellValue(isGerman ? 'WE 3' : 'WE 3'),
    TextCellValue('ivan;ana'),
    TextCellValue('Strang+Seiten'),
  ]);

  final bytes = excel.encode();
  if (bytes == null) {
    return;
  }

  final blob = html.Blob(<dynamic>[
    Uint8List.fromList(bytes),
  ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute(
      'download',
      isGerman ? 'dhego_import_vorlage.xlsx' : 'dhego_import_spranca.xlsx',
    )
    ..click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
}

String _projectMaterialCellText(List<Data?> row, int index) {
  if (index >= row.length) {
    return '';
  }

  final cell = row[index];
  final value = cell?.value;
  if (value == null) {
    return '';
  }

  return switch (value) {
    TextCellValue() => value.toString().trim(),
    IntCellValue() => value.value.toString(),
    DoubleCellValue() => value.value.toString(),
    BoolCellValue() => value.value ? 'true' : 'false',
    FormulaCellValue() => value.formula.trim(),
    DateCellValue() => value.asDateTimeLocal().toIso8601String(),
    DateTimeCellValue() => value.asDateTimeLocal().toIso8601String(),
    TimeCellValue() => value.asDuration().toString(),
  };
}

String? _projectMaterialNormalizedFillHex(List<Data?> row, int index) {
  if (index >= row.length) {
    return null;
  }

  final cell = row[index];
  final colorHex = cell?.cellStyle?.backgroundColor.colorHex ?? '';
  final normalized = colorHex.toUpperCase().replaceAll('#', '').trim();
  if (normalized.isEmpty || normalized == 'NONE') {
    return null;
  }

  return normalized;
}

bool _looksLikeProjectMaterialHeader(
  String articleNumber,
  String categoryValue,
  String supplier,
) {
  return articleNumber.toLowerCase() == 'artikelnummer' &&
      categoryValue.toLowerCase() == 'kategorie' &&
      supplier.toLowerCase() == 'lieferant';
}

bool _isProjectMaterialCategoryRow(
  String columnA,
  String columnB,
  String supplier,
) {
  if (supplier.trim().isNotEmpty) {
    return false;
  }

  final hasA = columnA.trim().isNotEmpty;
  final hasB = columnB.trim().isNotEmpty;

  if (hasA && !hasB) {
    return true;
  }

  if (!hasA && hasB) {
    return true;
  }

  return false;
}

String _buildProjectMaterialId({
  required String sheetName,
  required String articleNumber,
  required String name,
}) {
  final articleSlug = _slugifyProjectMaterialValue(articleNumber);
  if (articleSlug.isNotEmpty) {
    return '${_slugifyProjectMaterialValue(sheetName)}.$articleSlug';
  }

  return '${_slugifyProjectMaterialValue(sheetName)}.${_slugifyProjectMaterialValue(name)}';
}

String _slugifyProjectMaterialValue(String value) {
  final lower = value
      .toLowerCase()
      .trim()
      .replaceAll('\u0161', 's')
      .replaceAll('\u0111', 'd')
      .replaceAll('\u010d', 'c')
      .replaceAll('\u0107', 'c')
      .replaceAll('\u017e', 'z')
      .replaceAll('\u00e4', 'a')
      .replaceAll('\u00f6', 'o')
      .replaceAll('\u00fc', 'u')
      .replaceAll('\u00df', 'ss');

  final buffer = StringBuffer();
  var previousWasSeparator = false;

  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    if (RegExp(r'[a-z0-9]').hasMatch(char)) {
      buffer.write(char);
      previousWasSeparator = false;
      continue;
    }

    if (!previousWasSeparator && buffer.isNotEmpty) {
      buffer.write('.');
      previousWasSeparator = true;
    }
  }

  return buffer.toString().replaceAll(RegExp(r'\.+$'), '');
}

class _ProjectMaterialCategoryState {
  String level1 = '';
  String level2 = '';
  String level3 = '';
  String level4 = '';
  int _lastCategoryDepth = 0;
  bool _sawItemSinceLastCategory = false;

  void applyCategory(String rawValue, String? fillHex) {
    final value = rawValue.trim();
    if (value.isEmpty) {
      return;
    }

    final explicitDepth = _depthFromFill(fillHex);
    final targetDepth = explicitDepth > 0 ? explicitDepth : _implicitDepth();
    _setCategoryAtDepth(targetDepth, value);
    _lastCategoryDepth = targetDepth;
    _sawItemSinceLastCategory = false;
  }

  void markItem() {
    _sawItemSinceLastCategory = true;
  }

  int _implicitDepth() {
    if (_lastCategoryDepth == 0) {
      return _firstEmptyDepth();
    }

    if (_sawItemSinceLastCategory) {
      return _lastCategoryDepth.clamp(1, 4);
    }

    return (_lastCategoryDepth + 1).clamp(1, 4);
  }

  int _firstEmptyDepth() {
    if (level1.isEmpty) {
      return 1;
    }
    if (level2.isEmpty) {
      return 2;
    }
    if (level3.isEmpty) {
      return 3;
    }
    return 4;
  }

  void _setCategoryAtDepth(int depth, String value) {
    switch (depth) {
      case 1:
        level1 = value;
        level2 = '';
        level3 = '';
        level4 = '';
        return;
      case 2:
        level2 = value;
        level3 = '';
        level4 = '';
        return;
      case 3:
        level3 = value;
        level4 = '';
        return;
      default:
        level4 = value;
        return;
    }
  }

  int _depthFromFill(String? fillHex) {
    final fill = (fillHex ?? '').toUpperCase();
    if (fill.endsWith('FFC000')) {
      return 1;
    }
    if (fill.endsWith('92D050')) {
      return 2;
    }
    if (fill.endsWith('00B0F0') || fill.endsWith('5B9BD5')) {
      return 3;
    }
    if (fill.endsWith('7030A0') || fill.endsWith('8E44AD')) {
      return 4;
    }
    return 0;
  }
}

Future<StructureImportSummary> importStructureData({
  required _WorkbookImportDraft draft,
  required DemoUser currentUser,
  bool synchronizeExisting = false,
  String? selectedProjectId,
  String selectedProjectType = projectTypeConstruction,
}) async {
  final projects = await watchAllProjects().first;
  final buildings = await watchAllBuildings().first;
  final wohnungs = await watchAllWohnungs().first;
  final referenceData = _WorkbookReferenceData(
    projects: projects,
    buildings: buildings,
    wohnungs: wohnungs,
  );
  final projectRef = synchronizeExisting
      ? referenceData.findProjectById(selectedProjectId ?? '') ??
            (throw Exception(
              localizedStrings['import_project_required']?[languageNotifier
                      .value] ??
                  'Potrebno je odabrati projekt za usklađivanje.',
            ))
      : referenceData.findOrCreateProject(draft.projectName);
  final importingUser = await watchUserByUsername(currentUser.username).first;
  final importerId = importingUser?.id ?? currentUser.username.trim();
  final importerName = importingUser?.fullName.trim().isNotEmpty == true
      ? importingUser!.fullName.trim()
      : currentUser.username.trim();
  final importerEmail = importingUser?.email.trim() ?? '';

  if (currentUser.role != 'admin' &&
      !currentUser.allowedProjects.contains(projectRef.id) &&
      projectRef.createdAt != null) {
    throw Exception(
      localizedStrings['import_permission_denied']?[languageNotifier.value] ??
          'Import je dozvoljen samo za dodijeljene projekte.',
    );
  }

  final importData = buildWorkbookImportData(
    draft: draft,
    referenceData: referenceData,
    projectRef: projectRef,
  );
  final existingTaskSnapshot = await firestore
      .collection('work_tasks')
      .where('projectId', isEqualTo: projectRef.id)
      .get();
  final existingTasksById = <String, Map<String, dynamic>>{
    for (final doc in existingTaskSnapshot.docs) doc.id: doc.data(),
  };

  final now = Timestamp.now();
  WriteBatch batch = firestore.batch();
  var pendingWrites = 0;

  Future<void> queueSet(
    DocumentReference<Map<String, dynamic>> reference,
    Map<String, dynamic> data,
  ) async {
    batch.set(reference, data, SetOptions(merge: true));
    pendingWrites++;
    if (pendingWrites >= 400) {
      await batch.commit();
      batch = firestore.batch();
      pendingWrites = 0;
    }
  }

  await queueSet(
    firestore.collection('projects').doc(projectRef.id),
    <String, dynamic>{
      'name': projectRef.name,
      'projectType': normalizeProjectType(selectedProjectType),
      'managerId': importerId,
      'managerName': importerName,
      'managerEmail': importerEmail,
      'active': true,
      'updatedAt': now,
      'createdAt': projectRef.createdAt ?? now,
    },
  );

  if (isManagerLikeRole(currentUser.role) && importerId.isNotEmpty) {
    final updatedAllowedProjects = <String>{
      ...currentUser.allowedProjects,
      projectRef.id,
    }.toList()..sort();
    await queueSet(
      firestore.collection('users').doc(importerId),
      <String, dynamic>{'allowedProjectIds': updatedAllowedProjects},
    );
  }

  for (final building in importData.buildings.values) {
    await queueSet(
      firestore.collection('buildings').doc(building.id),
      <String, dynamic>{
        'projectId': building.projectId,
        'name': building.name,
        'active': true,
        'updatedAt': now,
        'createdAt': building.createdAt ?? now,
      },
    );
  }

  for (final wohnung in importData.wohnungs.values) {
    await queueSet(
      firestore.collection('wohnungs').doc(wohnung.id),
      <String, dynamic>{
        'buildingId': wohnung.buildingId,
        'name': wohnung.name,
        'active': true,
        'checklistType': wohnung.checklistType,
        'updatedAt': now,
      },
    );
  }

  if (synchronizeExisting) {
    final importedBuildingIds = importData.buildings.keys.toSet();
    final importedWohnungIds = importData.wohnungs.keys.toSet();
    for (final existingWohnung in wohnungs) {
      if (!importedBuildingIds.contains(existingWohnung.buildingId)) {
        continue;
      }
      if (importedWohnungIds.contains(existingWohnung.id)) {
        continue;
      }
      await queueSet(
        firestore.collection('wohnungs').doc(existingWohnung.id),
        <String, dynamic>{'active': false, 'updatedAt': now},
      );
    }
  }

  final importedTaskIds = importData.tasks.map((task) => task.id).toSet();
  if (synchronizeExisting) {
    for (final existingDoc in existingTaskSnapshot.docs) {
      if (importedTaskIds.contains(existingDoc.id)) {
        continue;
      }
      await queueSet(existingDoc.reference, <String, dynamic>{
        'active': false,
        'updatedAt': now,
      });
    }
  }

  final wohnungTotals = <String, int>{};
  final wohnungCompleted = <String, int>{};
  final buildingTotals = <String, int>{};
  final buildingCompleted = <String, int>{};
  var projectTotal = 0;
  var projectCompleted = 0;

  for (final task in importData.tasks) {
    final existingTask = existingTasksById[task.id] ?? <String, dynamic>{};
    final existingCompleted = existingTask['completed'] as bool? ?? false;
    final importedCompleted = task.importedCompleted;
    final completed = importedCompleted ?? existingCompleted;
    final preserveExistingProof = existingCompleted && completed;
    final completedAt = preserveExistingProof
        ? existingTask['completedAt']
        : null;
    final completedBy = preserveExistingProof
        ? existingTask['completedBy']?.toString() ?? ''
        : '';
    final signature = preserveExistingProof
        ? (existingTask['signature'] as Map<String, dynamic>? ??
              (existingTask['signature'] is Map
                  ? Map<String, dynamic>.from(existingTask['signature'] as Map)
                  : null))
        : null;
    final completedViaImport =
        completed && !preserveExistingProof && importedCompleted == true;

    await queueSet(
      firestore.collection('work_tasks').doc(task.id),
      <String, dynamic>{
        'projectId': task.projectId,
        'projectName': task.projectName,
        'buildingId': task.buildingId,
        'buildingName': task.buildingName,
        'wohnungId': task.wohnungId,
        'apartmentName': task.apartmentName,
        'rawApartment': task.rawApartment,
        'sheetName': task.sheetName,
        'taskGroup': task.taskGroup,
        'taskType': task.taskType,
        'taskLabel': task.taskLabel,
        'pointValue': 1,
        'completed': completed,
        'completedAt': completedAt,
        'completedBy': completedBy,
        'signature': signature,
        'completedViaImport': completedViaImport,
        'active': true,
        'sortOrder': task.sortOrder,
        'sourceRow': task.sourceRow,
        'sourceColumn': task.sourceColumn,
        'importedAt': now,
      },
    );

    wohnungTotals[task.wohnungId] = (wohnungTotals[task.wohnungId] ?? 0) + 1;
    buildingTotals[task.buildingId] =
        (buildingTotals[task.buildingId] ?? 0) + 1;
    projectTotal++;
    if (completed) {
      wohnungCompleted[task.wohnungId] =
          (wohnungCompleted[task.wohnungId] ?? 0) + 1;
      buildingCompleted[task.buildingId] =
          (buildingCompleted[task.buildingId] ?? 0) + 1;
      projectCompleted++;
    }
  }

  for (final wohnung in importData.wohnungs.values) {
    final total = wohnungTotals[wohnung.id] ?? 0;
    final completed = wohnungCompleted[wohnung.id] ?? 0;
    await queueSet(
      firestore.collection('wohnungs').doc(wohnung.id),
      <String, dynamic>{
        'workTaskTotalPoints': total,
        'workTaskCompletedPoints': completed,
        'workTaskProgressPercent': total == 0
            ? 0
            : ((completed / total) * 100).round(),
      },
    );
  }

  for (final building in importData.buildings.values) {
    final total = buildingTotals[building.id] ?? 0;
    final completed = buildingCompleted[building.id] ?? 0;
    await queueSet(
      firestore.collection('buildings').doc(building.id),
      <String, dynamic>{
        'workTaskTotalPoints': total,
        'workTaskCompletedPoints': completed,
        'workTaskProgressPercent': total == 0
            ? 0
            : ((completed / total) * 100).round(),
      },
    );
  }

  await queueSet(
    firestore.collection('projects').doc(projectRef.id),
    <String, dynamic>{
      'workTaskTotalPoints': projectTotal,
      'workTaskCompletedPoints': projectCompleted,
      'workTaskProgressPercent': projectTotal == 0
          ? 0
          : ((projectCompleted / projectTotal) * 100).round(),
    },
  );

  if (pendingWrites > 0) {
    await batch.commit();
  }

  return StructureImportSummary(
    projects: 1,
    buildings: importData.buildings.length,
    wohnungs: importData.wohnungs.length,
    tasks: importData.tasks.length,
    skippedEntries: draft.skipped.length,
    projectName: projectRef.name,
  );
}

class _WorkbookImportDraft {
  const _WorkbookImportDraft({
    required this.projectName,
    required this.buildingNames,
    required this.wohnungen,
    required this.tasks,
    required this.skipped,
  });

  final String projectName;
  final Set<String> buildingNames;
  final Set<String> wohnungen;
  final List<_WorkbookTaskDraft> tasks;
  final List<String> skipped;
}

class _WorkbookTaskDraft {
  const _WorkbookTaskDraft({
    required this.sheetName,
    required this.buildingName,
    required this.apartmentName,
    required this.rawApartment,
    required this.taskGroup,
    required this.taskType,
    required this.taskLabel,
    required this.checklistType,
    required this.importedCompleted,
    required this.sortOrder,
    required this.sourceRow,
    required this.sourceColumn,
  });

  final String sheetName;
  final String buildingName;
  final String apartmentName;
  final String rawApartment;
  final String taskGroup;
  final String taskType;
  final String taskLabel;
  final String checklistType;
  final bool? importedCompleted;
  final int sortOrder;
  final int sourceRow;
  final int sourceColumn;
}

class _WorkbookImportData {
  const _WorkbookImportData({
    required this.buildings,
    required this.wohnungs,
    required this.tasks,
  });

  final Map<String, _WorkbookBuildingRef> buildings;
  final Map<String, _WorkbookWohnungRef> wohnungs;
  final List<_ResolvedWorkbookTask> tasks;
}

class _ResolvedWorkbookTask {
  const _ResolvedWorkbookTask({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.buildingId,
    required this.buildingName,
    required this.wohnungId,
    required this.apartmentName,
    required this.rawApartment,
    required this.sheetName,
    required this.taskGroup,
    required this.taskType,
    required this.taskLabel,
    required this.importedCompleted,
    required this.sortOrder,
    required this.sourceRow,
    required this.sourceColumn,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String buildingId;
  final String buildingName;
  final String wohnungId;
  final String apartmentName;
  final String rawApartment;
  final String sheetName;
  final String taskGroup;
  final String taskType;
  final String taskLabel;
  final bool? importedCompleted;
  final int sortOrder;
  final int sourceRow;
  final int sourceColumn;
}

class _WorkbookReferenceData {
  const _WorkbookReferenceData({
    required this.projects,
    required this.buildings,
    required this.wohnungs,
  });

  final List<ProjectRecord> projects;
  final List<BuildingRecord> buildings;
  final List<WohnungRecord> wohnungs;

  _WorkbookProjectRef? findProjectById(String projectId) {
    for (final project in projects) {
      if (project.id != projectId) {
        continue;
      }
      return _WorkbookProjectRef(
        id: project.id,
        name: project.name,
        managerId: project.managerId,
        managerName: project.managerName,
        managerEmail: project.managerEmail,
        createdAt: project.createdAt,
      );
    }
    return null;
  }

  _WorkbookProjectRef findOrCreateProject(String projectName) {
    final normalizedName = _normalizeWorkbookKey(projectName);
    for (final project in projects) {
      if (_normalizeWorkbookKey(project.name) == normalizedName ||
          _normalizeWorkbookKey(project.id) == normalizedName) {
        return _WorkbookProjectRef(
          id: project.id,
          name: project.name,
          managerId: project.managerId,
          managerName: project.managerName,
          managerEmail: project.managerEmail,
          createdAt: project.createdAt,
        );
      }
    }

    return _WorkbookProjectRef(
      id: _slugifyWorkbookValue(projectName),
      name: projectName,
      managerId: '',
      managerName: '',
      managerEmail: '',
      createdAt: null,
    );
  }

  _WorkbookBuildingRef findOrCreateBuilding({
    required _WorkbookProjectRef project,
    required String sheetName,
    required String titleCell,
  }) {
    final displayName = titleCell.trim().isNotEmpty
        ? titleCell.trim()
        : _displayWorkbookBuildingName(sheetName, projectName: project.name);
    final normalizedSheet = _normalizeWorkbookKey(sheetName);
    final normalizedTitle = _normalizeWorkbookKey(titleCell);
    final sheetSuffix = _normalizeWorkbookKey(
      sheetName.replaceFirst(
        RegExp(r'^geb[aä]ude[_\s-]*', caseSensitive: false),
        '',
      ),
    );
    final titleSuffix = _lastWorkbookTokenKey(titleCell);

    for (final building in buildings) {
      if (building.projectId != project.id) {
        continue;
      }
      final keys = <String>{_normalizeWorkbookKey(building.name)};
      if (building.name.contains(' ')) {
        keys.add(_lastWorkbookTokenKey(building.name));
      }
      if (keys.contains(normalizedSheet) ||
          keys.contains(normalizedTitle) ||
          (sheetSuffix.isNotEmpty && keys.contains(sheetSuffix)) ||
          (titleSuffix.isNotEmpty && keys.contains(titleSuffix))) {
        return _WorkbookBuildingRef(
          id: building.id,
          name: displayName,
          projectId: building.projectId,
          createdAt: building.createdAt,
        );
      }
    }

    for (final building in buildings) {
      if (building.projectId != project.id) {
        continue;
      }
      final key = _normalizeWorkbookKey(building.name);
      if ((sheetSuffix.isNotEmpty && key.endsWith(sheetSuffix)) ||
          (titleSuffix.isNotEmpty && key.endsWith(titleSuffix))) {
        return _WorkbookBuildingRef(
          id: building.id,
          name: displayName,
          projectId: building.projectId,
          createdAt: building.createdAt,
        );
      }
    }

    return _WorkbookBuildingRef(
      id: '${project.id}_${_slugifyWorkbookValue(displayName)}',
      name: displayName,
      projectId: project.id,
      createdAt: null,
    );
  }

  _WorkbookWohnungRef findOrCreateWohnung({
    required String buildingId,
    required String apartmentName,
    required String rawApartment,
  }) {
    final candidates = wohnungs.where(
      (wohnung) => wohnung.buildingId == buildingId,
    );
    final normalized = _normalizeWorkbookKey(apartmentName);
    final numeric = _apartmentNumericWorkbookKey(apartmentName);
    final rawNumeric = _apartmentNumericWorkbookKey(rawApartment);

    for (final wohnung in candidates) {
      if (_normalizeWorkbookKey(wohnung.name) == normalized) {
        return _WorkbookWohnungRef(
          id: wohnung.id,
          name: wohnung.name,
          buildingId: wohnung.buildingId,
          checklistType: wohnung.checklistType,
        );
      }
    }

    for (final wohnung in candidates) {
      final candidateNumeric = _apartmentNumericWorkbookKey(wohnung.name);
      if (candidateNumeric == numeric || candidateNumeric == rawNumeric) {
        return _WorkbookWohnungRef(
          id: wohnung.id,
          name: wohnung.name,
          buildingId: wohnung.buildingId,
          checklistType: wohnung.checklistType,
        );
      }
    }

    return _WorkbookWohnungRef(
      id: '${buildingId}_${_slugifyWorkbookValue(apartmentName)}',
      name: apartmentName,
      buildingId: buildingId,
      checklistType: '',
    );
  }
}

class _WorkbookProjectRef {
  const _WorkbookProjectRef({
    required this.id,
    required this.name,
    required this.managerId,
    required this.managerName,
    required this.managerEmail,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String managerId;
  final String managerName;
  final String managerEmail;
  final DateTime? createdAt;
}

class _WorkbookBuildingRef {
  const _WorkbookBuildingRef({
    required this.id,
    required this.name,
    required this.projectId,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String projectId;
  final DateTime? createdAt;
}

class _WorkbookWohnungRef {
  const _WorkbookWohnungRef({
    required this.id,
    required this.name,
    required this.buildingId,
    required this.checklistType,
  });

  final String id;
  final String name;
  final String buildingId;
  final String checklistType;

  _WorkbookWohnungRef withChecklistType(String nextChecklistType) {
    return _WorkbookWohnungRef(
      id: id,
      name: name,
      buildingId: buildingId,
      checklistType: nextChecklistType,
    );
  }
}

class _WorkbookTaskHeader {
  const _WorkbookTaskHeader({this.group = '', this.type = ''});

  final String group;
  final String type;
}

_WorkbookImportDraft? buildWorkbookImportDraft(String fileName, Excel excel) {
  final tasks = <_WorkbookTaskDraft>[];
  final skipped = <String>[];
  final buildingNames = <String>{};
  final wohnungs = <String>{};
  final projectName = _deriveWorkbookProjectName(fileName);
  final singleSheet = excel.tables.keys.length <= 1;

  for (final sheetName in excel.tables.keys) {
    final table = excel.tables[sheetName];
    if (table == null || table.maxRows < 6) {
      continue;
    }

    final buildingName = _displayWorkbookBuildingName(
      sheetName,
      projectName: projectName,
      singleSheet: singleSheet,
    );
    buildingNames.add(buildingName);
    final processHeaders = _extractWorkbookTaskHeaders(table.rows);

    for (var rowIndex = 5; rowIndex < table.maxRows; rowIndex++) {
      final row = table.rows[rowIndex];
      final rawApartment = _workbookCellTextAt(row, 1);
      if (rawApartment.isEmpty) {
        continue;
      }

      final apartmentName = _formatWorkbookApartmentName(rawApartment);
      wohnungs.add('$buildingName::$apartmentName');

      for (var columnIndex = 3; columnIndex < row.length; columnIndex++) {
        final value = _workbookCellTextAt(row, columnIndex);
        final importedCompleted = _workbookTaskCompletionStateAt(
          row,
          columnIndex,
        );
        final header =
            processHeaders[columnIndex] ?? const _WorkbookTaskHeader();
        final taskGroup = header.group.trim();
        final taskType = header.type.trim();
        if (taskGroup.isEmpty && taskType.isEmpty) {
          continue;
        }

        final normalizedTaskGroup = _normalizeWorkbookKey(taskGroup);
        var checklistType = '';
        if (normalizedTaskGroup == 'register') {
          checklistType = normalizeChecklistTypeForImport(value);
          if (checklistType.isEmpty) {
            if (value.trim().isNotEmpty) {
              skipped.add(
                'Sheet "$sheetName" row ${rowIndex + 1} col ${columnIndex + 1}: invalid checklist type "$value" for Register.',
              );
            }
            continue;
          }
        } else if (!_isWorkbookTaskMarker(value)) {
          continue;
        }

        final taskLabel = taskType.isEmpty || taskType == taskGroup
            ? taskGroup
            : '$taskGroup / $taskType';
        tasks.add(
          _WorkbookTaskDraft(
            sheetName: sheetName,
            buildingName: buildingName,
            apartmentName: apartmentName,
            rawApartment: rawApartment.trim(),
            taskGroup: taskGroup,
            taskType: taskType,
            taskLabel: taskLabel,
            checklistType: checklistType,
            importedCompleted: importedCompleted,
            sortOrder: columnIndex - 2,
            sourceRow: rowIndex + 1,
            sourceColumn: columnIndex + 1,
          ),
        );
      }
    }
  }

  if (tasks.isEmpty && buildingNames.isEmpty) {
    return null;
  }

  return _WorkbookImportDraft(
    projectName: projectName,
    buildingNames: buildingNames,
    wohnungen: wohnungs,
    tasks: tasks,
    skipped: skipped,
  );
}

_WorkbookImportData buildWorkbookImportData({
  required _WorkbookImportDraft draft,
  required _WorkbookReferenceData referenceData,
  required _WorkbookProjectRef projectRef,
}) {
  final buildings = <String, _WorkbookBuildingRef>{};
  final wohnungs = <String, _WorkbookWohnungRef>{};
  final tasks = <_ResolvedWorkbookTask>[];

  for (final task in draft.tasks) {
    final buildingRef = referenceData.findOrCreateBuilding(
      project: projectRef,
      sheetName: task.sheetName,
      titleCell: task.buildingName,
    );
    buildings[buildingRef.id] = buildingRef;

    var wohnungRef = referenceData.findOrCreateWohnung(
      buildingId: buildingRef.id,
      apartmentName: task.apartmentName,
      rawApartment: task.rawApartment,
    );
    if (task.checklistType.isNotEmpty &&
        wohnungRef.checklistType != task.checklistType) {
      wohnungRef = wohnungRef.withChecklistType(task.checklistType);
    }
    wohnungs[wohnungRef.id] = wohnungRef;

    tasks.add(
      _ResolvedWorkbookTask(
        id: _buildResolvedWorkbookTaskId(
          buildingId: buildingRef.id,
          wohnungId: wohnungRef.id,
          taskGroup: task.taskGroup,
          taskType: task.taskType,
        ),
        projectId: projectRef.id,
        projectName: projectRef.name,
        buildingId: buildingRef.id,
        buildingName: buildingRef.name,
        wohnungId: wohnungRef.id,
        apartmentName: wohnungRef.name,
        rawApartment: task.rawApartment,
        sheetName: task.sheetName,
        taskGroup: task.taskGroup,
        taskType: task.taskType,
        taskLabel: task.taskLabel,
        importedCompleted: task.importedCompleted,
        sortOrder: task.sortOrder,
        sourceRow: task.sourceRow,
        sourceColumn: task.sourceColumn,
      ),
    );
  }

  final existingTaskIds = tasks.map((task) => task.id).toSet();
  for (final wohnungRef in wohnungs.values) {
    final buildingRef = buildings[wohnungRef.buildingId];
    if (buildingRef == null) {
      continue;
    }
    final druckprobeTaskId = _buildResolvedWorkbookTaskId(
      buildingId: buildingRef.id,
      wohnungId: wohnungRef.id,
      taskGroup: 'Druckprobe',
      taskType: '',
    );
    if (existingTaskIds.contains(druckprobeTaskId)) {
      continue;
    }
    tasks.add(
      _ResolvedWorkbookTask(
        id: druckprobeTaskId,
        projectId: projectRef.id,
        projectName: projectRef.name,
        buildingId: buildingRef.id,
        buildingName: buildingRef.name,
        wohnungId: wohnungRef.id,
        apartmentName: wohnungRef.name,
        rawApartment: wohnungRef.name,
        sheetName: buildingRef.name,
        taskGroup: 'Druckprobe',
        taskType: '',
        taskLabel: 'Druckprobe',
        importedCompleted: null,
        sortOrder: 999,
        sourceRow: 0,
        sourceColumn: 999,
      ),
    );
    existingTaskIds.add(druckprobeTaskId);
  }

  return _WorkbookImportData(
    buildings: buildings,
    wohnungs: wohnungs,
    tasks: tasks,
  );
}

Map<int, _WorkbookTaskHeader> _extractWorkbookTaskHeaders(
  List<List<Data?>> rows,
) {
  final headers = <int, _WorkbookTaskHeader>{};
  if (rows.length < 5) {
    return headers;
  }

  final row4 = rows[3];
  final row5 = rows[4];
  String currentGroup = '';
  final maxColumns = row4.length > row5.length ? row4.length : row5.length;
  for (var columnIndex = 3; columnIndex < maxColumns; columnIndex++) {
    final groupText = _workbookCellTextAt(row4, columnIndex);
    final typeText = _workbookCellTextAt(row5, columnIndex);
    if (groupText.isNotEmpty) {
      currentGroup = groupText;
    }
    if (currentGroup.isEmpty && typeText.isEmpty) {
      continue;
    }
    headers[columnIndex] = _WorkbookTaskHeader(
      group: currentGroup,
      type: typeText,
    );
  }
  return headers;
}

String _workbookCellTextAt(List<Data?> row, int index) {
  if (index >= row.length) {
    return '';
  }
  return _workbookCellText(row[index]);
}

bool? _workbookTaskCompletionStateAt(List<Data?> row, int index) {
  if (index >= row.length) {
    return null;
  }
  return _workbookTaskCompletionState(row[index]);
}

bool? _workbookTaskCompletionState(Data? cell) {
  final colorHex = cell?.cellStyle?.backgroundColor.colorHex ?? '';
  final normalized = colorHex.toUpperCase().replaceAll('#', '').trim();
  if (normalized.isEmpty || normalized == 'NONE') {
    return null;
  }
  if (normalized.endsWith('FFDCEDC8') || normalized.endsWith('DCEDC8')) {
    return true;
  }
  if (normalized.endsWith('FFFFCDD2') || normalized.endsWith('FFCDD2')) {
    return false;
  }
  return null;
}

String _workbookCellText(Data? cell) {
  final value = cell?.value;
  if (value == null) {
    return '';
  }

  return switch (value) {
    TextCellValue() => _repairWorkbookImportedText(
      value.toString().replaceAll('\n', ' ').trim(),
    ),
    IntCellValue() => value.value.toString(),
    DoubleCellValue() => value.value.toString(),
    BoolCellValue() => value.value ? 'true' : 'false',
    FormulaCellValue() => _repairWorkbookImportedText(value.formula.trim()),
    DateCellValue() => value.asDateTimeLocal().toIso8601String(),
    DateTimeCellValue() => value.asDateTimeLocal().toIso8601String(),
    TimeCellValue() => value.asDuration().toString(),
  };
}

String _repairWorkbookImportedText(String text) {
  if (!text.contains('Ãƒ') &&
      !text.contains('Ã‚') &&
      !text.contains('Â¤') &&
      !text.contains('Â¼') &&
      !text.contains('Â¶')) {
    return text;
  }

  try {
    return utf8.decode(latin1.encode(text));
  } catch (_) {
    return text;
  }
}

bool _isWorkbookTaskMarker(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized == 'true' ||
      normalized == '1' ||
      normalized == 'x' ||
      normalized == '✓' ||
      normalized == '✔' ||
      normalized == 'ja' ||
      normalized == 'yes' ||
      normalized == 'wahr' ||
      normalized == 'unterschrift';
}

String _formatWorkbookApartmentName(String rawApartment) {
  final cleaned = rawApartment.trim();
  final withoutPrefix = cleaned.replaceFirst(
    RegExp(r'^(we|wohnung)\s*', caseSensitive: false),
    '',
  );
  return 'WE${withoutPrefix.toUpperCase()}';
}

String _deriveWorkbookProjectName(String workbookFileName) {
  final fileName = workbookFileName.split('/').last.split('\\').last;
  final withoutExtension = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
  final trimmed = withoutExtension
      .replaceFirst(
        RegExp(r'^arbeitsabl[aä]ufe[_\s-]*', caseSensitive: false),
        '',
      )
      .replaceAll('_', ' ')
      .trim();
  final goldMatch = RegExp(r'^([A-Za-z]+)\s*(\d)\s*(\d)$').firstMatch(trimmed);
  if (goldMatch != null) {
    return '${goldMatch.group(1)} ${goldMatch.group(2)}-${goldMatch.group(3)}';
  }
  return trimmed.isEmpty ? 'Projekt iz radnih zadataka' : trimmed;
}

String _displayWorkbookBuildingName(
  String sheetName, {
  String? projectName,
  bool singleSheet = false,
}) {
  final stripped = sheetName
      .replaceFirst(RegExp(r'^geb[aä]ude[_\s-]*', caseSensitive: false), '')
      .trim();
  if (singleSheet && (projectName?.trim().isNotEmpty ?? false)) {
    return projectName!.trim();
  }
  if (stripped.isEmpty) {
    return sheetName.trim();
  }

  final projectPrefix = projectName?.trim() ?? '';
  if (projectPrefix.isNotEmpty) {
    final escapedProjectPrefix = RegExp.escape(projectPrefix);
    final withoutProjectPrefix = stripped
        .replaceFirst(
          RegExp('^$escapedProjectPrefix[_\\s-]*', caseSensitive: false),
          '',
        )
        .trim();
    if (withoutProjectPrefix.isNotEmpty) {
      return withoutProjectPrefix;
    }
  }

  return stripped;
}

String _buildResolvedWorkbookTaskId({
  required String buildingId,
  required String wohnungId,
  required String taskGroup,
  required String taskType,
}) {
  final groupSlug = _slugifyWorkbookValue(taskGroup);
  final typeSlug = _slugifyWorkbookValue(
    taskType.isEmpty ? taskGroup : taskType,
  );
  return '$buildingId.$wohnungId.$groupSlug.$typeSlug';
}

String projectExportColumnKey({
  required int sourceColumn,
  required String taskGroup,
  required String taskType,
}) {
  return '$sourceColumn|${_normalizeWorkbookKey(taskGroup)}|${_normalizeWorkbookKey(taskType)}';
}

List<ProjectExportColumn> buildProjectExportColumns(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> taskDocs,
) {
  final columnsByKey = <String, ProjectExportColumn>{};
  for (final doc in taskDocs) {
    final data = doc.data();
    final sourceColumn = readIntValue(
      data['sourceColumn'],
      fallback: readIntValue(data['sortOrder']) + 3,
    );
    final taskGroup = data['taskGroup']?.toString().trim() ?? '';
    final taskType = data['taskType']?.toString().trim() ?? '';
    final column = ProjectExportColumn(
      sourceColumn: sourceColumn,
      taskGroup: taskGroup,
      taskType: taskType,
    );
    columnsByKey[column.key] = column;
  }

  final columns = columnsByKey.values.toList()
    ..sort((a, b) {
      final bySource = a.sourceColumn.compareTo(b.sourceColumn);
      if (bySource != 0) {
        return bySource;
      }
      final byGroup = a.taskGroup.toLowerCase().compareTo(
        b.taskGroup.toLowerCase(),
      );
      if (byGroup != 0) {
        return byGroup;
      }
      return a.taskType.toLowerCase().compareTo(b.taskType.toLowerCase());
    });
  return columns;
}

int compareWohnungRecordsForExport(WohnungRecord a, WohnungRecord b) {
  final aNumeric = int.tryParse(_apartmentNumericWorkbookKey(a.name));
  final bNumeric = int.tryParse(_apartmentNumericWorkbookKey(b.name));
  if (aNumeric != null && bNumeric != null && aNumeric != bNumeric) {
    return aNumeric.compareTo(bNumeric);
  }
  if (aNumeric != null && bNumeric == null) {
    return -1;
  }
  if (aNumeric == null && bNumeric != null) {
    return 1;
  }
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

String buildProjectExportSheetName(
  String rawName, {
  required Set<String> existingNames,
}) {
  final cleaned = rawName
      .replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  final base = cleaned.isEmpty ? 'Zgrada' : cleaned;
  var candidate = base.length > 31 ? base.substring(0, 31) : base;
  var suffix = 2;
  while (existingNames.contains(candidate)) {
    final suffixText = ' ($suffix)';
    final maxBaseLength = 31 - suffixText.length;
    final shortenedBase = base.length > maxBaseLength
        ? base.substring(0, maxBaseLength)
        : base;
    candidate = '$shortenedBase$suffixText';
    suffix++;
  }
  return candidate;
}

String _normalizeWorkbookKey(String value) {
  return _slugifyWorkbookValue(value).replaceAll('.', '');
}

String _lastWorkbookTokenKey(String value) {
  final normalized = _normalizeWorkbookKey(value);
  if (normalized.isEmpty) {
    return '';
  }
  final tokens = _slugifyWorkbookValue(
    value,
  ).split('.').where((token) => token.trim().isNotEmpty).toList();
  return tokens.isEmpty ? normalized : tokens.last;
}

String _apartmentNumericWorkbookKey(String value) {
  final match = RegExp(r'(\d+)').firstMatch(value);
  return match?.group(1) ?? _normalizeWorkbookKey(value);
}

String _slugifyWorkbookValue(String value) {
  final lower = value
      .toLowerCase()
      .trim()
      .replaceAll('\u0161', 's')
      .replaceAll('\u0111', 'd')
      .replaceAll('\u010d', 'c')
      .replaceAll('\u0107', 'c')
      .replaceAll('\u017e', 'z')
      .replaceAll('\u00e4', 'a')
      .replaceAll('\u00f6', 'o')
      .replaceAll('\u00fc', 'u')
      .replaceAll('\u00df', 'ss');

  final buffer = StringBuffer();
  var previousWasSeparator = false;
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    if (RegExp(r'[a-z0-9]').hasMatch(char)) {
      buffer.write(char);
      previousWasSeparator = false;
      continue;
    }
    if (!previousWasSeparator && buffer.isNotEmpty) {
      buffer.write('.');
      previousWasSeparator = true;
    }
  }

  return buffer.toString().replaceAll(RegExp(r'\.+$'), '');
}

bool isStructureImportHeaderRow({
  required String projectName,
  required String buildingName,
  required String wohnungName,
  required String workersRaw,
  required String checklistTypeRaw,
}) {
  final first = projectName.trim().toLowerCase();
  final second = buildingName.trim().toLowerCase();
  final third = wohnungName.trim().toLowerCase();
  final fourth = workersRaw.trim().toLowerCase();
  final fifth = checklistTypeRaw.trim().toLowerCase();

  final projectHeader = first == 'projekt' || first == 'project';
  final buildingHeader = second == 'zgrada' || second == 'gebäude';
  final wohnungHeader =
      third == 'stan' || third == 'wohnung' || third == 'apartment';
  final workersHeader =
      fourth.isEmpty || fourth == 'radnici' || fourth == 'mitarbeiter';
  final checklistHeader =
      fifth.isEmpty ||
      fifth == 'tip checkliste' ||
      fifth == 'checklisten-typ' ||
      fifth == 'checklist type';

  return projectHeader &&
      buildingHeader &&
      wohnungHeader &&
      workersHeader &&
      checklistHeader;
}

Widget _dialogField(
  TextEditingController controller,
  String label, {
  bool enabled = true,
  bool obscureText = false,
  ValueChanged<String>? onChanged,
}) {
  return TextField(
    controller: controller,
    enabled: enabled,
    obscureText: obscureText,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  );
}

String generateUserDocumentId(String username) {
  return username
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '.')
      .replaceAll(RegExp(r'[^\w\.-]'), '')
      .replaceAll(RegExp(r'\.+'), '.')
      .replaceAll(RegExp(r'^\.|\.$'), '');
}

String generateImportDocumentId(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'[^\w-]'), '')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}

String sanitizeSharedDocumentFileName(String value) {
  final cleaned = value
      .trim()
      .replaceAll(RegExp(r'[^\w\s\.-]'), '_')
      .replaceAll(RegExp(r'\s+'), '_');
  return cleaned.isEmpty ? 'dokument.pdf' : cleaned;
}

Future<void> attachPendingSharedDocumentsForWohnung(
  BuildContext context, {
  required DemoUser user,
  required ProjectRecord project,
  required BuildingRecord building,
  required WohnungRecord wohnung,
  required List<SharedPdfPayload> pendingFiles,
}) async {
  if (pendingFiles.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr(context, 'no_shared_pdfs'))));
    return;
  }

  final shouldSave =
      await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text(tr(context, 'save_shared_documents')),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'save_shared_documents_message')),
                    const SizedBox(height: 12),
                    ...pendingFiles.map((file) => Text('• ${file.fileName}')),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      ) ??
      false;

  if (!shouldSave) {
    return;
  }

  final processedFiles = <SharedPdfPayload>[];
  var savedImmediatelyCount = 0;
  var queuedOfflineCount = 0;
  for (var index = 0; index < pendingFiles.length; index++) {
    final file = pendingFiles[index];
    final bytes = await XFile(file.path).readAsBytes();
    if (bytes.isEmpty) {
      continue;
    }

    final timestamp = DateTime.now();
    final documentId =
        '${wohnung.id}_${timestamp.microsecondsSinceEpoch}_$index';
    final sanitizedFileName = sanitizeSharedDocumentFileName(file.fileName);
    final submission = PendingApartmentDocumentSubmission(
      documentId: documentId,
      projectId: project.id,
      projectName: project.name,
      buildingId: building.id,
      buildingName: building.name,
      wohnungId: wohnung.id,
      apartmentName: wohnung.name,
      fileName: sanitizedFileName,
      bytesBase64: base64Encode(bytes),
      uploadedBy: user.username,
      queuedAt: timestamp,
    );

    try {
      await uploadPendingApartmentDocumentSubmission(submission);
      savedImmediatelyCount += 1;
    } catch (_) {
      await enqueuePendingApartmentDocumentSubmission(submission);
      queuedOfflineCount += 1;
    }

    processedFiles.add(file);
  }

  removePendingSharedPdfs(processedFiles);
  if (context.mounted) {
    final messageKey = queuedOfflineCount == 0
        ? 'documents_saved_success'
        : savedImmediatelyCount == 0
        ? 'documents_saved_offline'
        : 'documents_saved_partial';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr(context, messageKey))));
  }
}

Future<void> savePickedPdfForWohnung(
  BuildContext context, {
  required DemoUser user,
  required ProjectRecord project,
  required BuildingRecord building,
  required WohnungRecord wohnung,
}) async {
  final selectedFile = await pickPdfDocumentFile();
  if (selectedFile == null) {
    return;
  }

  final timestamp = DateTime.now();
  final documentId = '${wohnung.id}_${timestamp.microsecondsSinceEpoch}_manual';
  final submission = PendingApartmentDocumentSubmission(
    documentId: documentId,
    projectId: project.id,
    projectName: project.name,
    buildingId: building.id,
    buildingName: building.name,
    wohnungId: wohnung.id,
    apartmentName: wohnung.name,
    fileName: selectedFile.fileName,
    bytesBase64: base64Encode(selectedFile.bytes),
    uploadedBy: user.username,
    queuedAt: timestamp,
  );

  try {
    await uploadPendingApartmentDocumentSubmission(submission);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'documents_saved_success'))),
      );
    }
  } catch (_) {
    await enqueuePendingApartmentDocumentSubmission(submission);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'documents_saved_offline'))),
      );
    }
  }
}

Future<void> showSharedPdfAssignmentDialog(
  BuildContext context, {
  required DemoUser user,
  required List<SharedPdfPayload> pendingFiles,
}) async {
  if (pendingFiles.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr(context, 'no_shared_pdfs'))));
    return;
  }

  final projects =
      ((user.role == 'admin'
              ? await watchAllProjects().first
              : await watchProjects(user.allowedProjects).first))
          .where((project) => project.active)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final buildings = await watchAllBuildings().first;
  final wohnungs = await watchAllWohnungs().first;

  String? selectedProjectId = projects.isNotEmpty ? projects.first.id : null;
  String? selectedBuildingId;
  String? selectedWohnungId;

  List<BuildingRecord> visibleBuildings() =>
      buildings
          .where(
            (building) =>
                building.active &&
                selectedProjectId != null &&
                building.projectId == selectedProjectId,
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  List<WohnungRecord> visibleWohnungs() =>
      wohnungs
          .where(
            (wohnung) =>
                wohnung.active &&
                selectedBuildingId != null &&
                wohnung.buildingId == selectedBuildingId,
          )
          .toList()
        ..sort((a, b) => compareWohnungNames(a.name, b.name));

  final initialBuildings = visibleBuildings();
  if (initialBuildings.isNotEmpty) {
    selectedBuildingId = initialBuildings.first.id;
    final initialWohnungs = visibleWohnungs();
    if (initialWohnungs.isNotEmpty) {
      selectedWohnungId = initialWohnungs.first.id;
    }
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          final currentBuildings = visibleBuildings();
          if (selectedBuildingId == null ||
              !currentBuildings.any(
                (building) => building.id == selectedBuildingId,
              )) {
            selectedBuildingId = currentBuildings.isEmpty
                ? null
                : currentBuildings.first.id;
          }

          final currentWohnungs = visibleWohnungs();
          if (selectedWohnungId == null ||
              !currentWohnungs.any(
                (wohnung) => wohnung.id == selectedWohnungId,
              )) {
            selectedWohnungId = currentWohnungs.isEmpty
                ? null
                : currentWohnungs.first.id;
          }

          return AlertDialog(
            title: Text(tr(context, 'save_shared_documents')),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'save_shared_documents_message')),
                    const SizedBox(height: 12),
                    ...pendingFiles.map((file) => Text('• ${file.fileName}')),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: selectedProjectId,
                      decoration: InputDecoration(
                        labelText: tr(context, 'select_project'),
                        border: const OutlineInputBorder(),
                      ),
                      items: projects
                          .map(
                            (project) => DropdownMenuItem<String>(
                              value: project.id,
                              child: Text(project.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setState(() {
                          selectedProjectId = value;
                          final nextBuildings = visibleBuildings();
                          selectedBuildingId = nextBuildings.isEmpty
                              ? null
                              : nextBuildings.first.id;
                          final nextWohnungs = visibleWohnungs();
                          selectedWohnungId = nextWohnungs.isEmpty
                              ? null
                              : nextWohnungs.first.id;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedBuildingId,
                      decoration: InputDecoration(
                        labelText: tr(context, 'select_building_admin'),
                        border: const OutlineInputBorder(),
                      ),
                      items: currentBuildings
                          .map(
                            (building) => DropdownMenuItem<String>(
                              value: building.id,
                              child: Text(building.name),
                            ),
                          )
                          .toList(),
                      onChanged: currentBuildings.isEmpty
                          ? null
                          : (value) {
                              setState(() {
                                selectedBuildingId = value;
                                final nextWohnungs = visibleWohnungs();
                                selectedWohnungId = nextWohnungs.isEmpty
                                    ? null
                                    : nextWohnungs.first.id;
                              });
                            },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedWohnungId,
                      decoration: InputDecoration(
                        labelText: tr(context, 'select_apartment'),
                        border: const OutlineInputBorder(),
                      ),
                      items: currentWohnungs
                          .map(
                            (wohnung) => DropdownMenuItem<String>(
                              value: wohnung.id,
                              child: Text(wohnung.name),
                            ),
                          )
                          .toList(),
                      onChanged: currentWohnungs.isEmpty
                          ? null
                          : (value) =>
                                setState(() => selectedWohnungId = value),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed:
                    selectedProjectId == null ||
                        selectedBuildingId == null ||
                        selectedWohnungId == null
                    ? null
                    : () async {
                        Navigator.of(context).pop();
                        final project = projects.firstWhere(
                          (entry) => entry.id == selectedProjectId,
                        );
                        final building = currentBuildings.firstWhere(
                          (entry) => entry.id == selectedBuildingId,
                        );
                        final wohnung = currentWohnungs.firstWhere(
                          (entry) => entry.id == selectedWohnungId,
                        );
                        await attachPendingSharedDocumentsForWohnung(
                          context,
                          user: user,
                          project: project,
                          building: building,
                          wohnung: wohnung,
                          pendingFiles: pendingFiles,
                        );
                      },
                child: Text(tr(context, 'save')),
              ),
            ],
          );
        },
      );
    },
  );
}

String normalizeImportUserKey(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '.')
      .replaceAll(RegExp(r'[^\w\.-@]'), '')
      .replaceAll(RegExp(r'\.+'), '.')
      .replaceAll(RegExp(r'^\.|\.$'), '');
}

Set<String> splitImportUserTokens(String value) {
  final normalized = normalizeImportUserKey(value);
  return normalized
      .split(RegExp(r'[._\-@]+'))
      .map((token) => token.trim())
      .where((token) => token.isNotEmpty)
      .toSet();
}

void showSavedSnackBar(BuildContext context) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(tr(context, 'saved_successfully'))));
}

String formatUserRoleLabel(String role) {
  switch (role) {
    case 'worker':
      return 'radnik';
    case 'site_manager':
      return 'voditelj gradilišta';
    case 'obermonteur':
      return 'nadmonter';
    case 'admin':
      return 'admin';
    default:
      return role;
  }
}

bool isManagerLikeRole(String role) {
  return role == 'site_manager' || role == 'obermonteur';
}

String formatDateTime(DateTime dateTime) {
  final day = dateTime.day.toString().padLeft(2, '0');
  final month = dateTime.month.toString().padLeft(2, '0');
  final year = dateTime.year.toString();
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');

  return '$day.$month.$year $hour:$minute';
}

String normalizeActivityFilterValue(String value) {
  return value.trim().toLowerCase();
}

String normalizeScanLookupValue(String value) {
  return value
      .toLowerCase()
      .trim()
      .replaceAll('\u00e4', 'a')
      .replaceAll('\u00f6', 'o')
      .replaceAll('\u00fc', 'u')
      .replaceAll('\u00df', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
}

List<String> _scanLookupTokens(String value) {
  return value
      .toLowerCase()
      .replaceAll('\u00e4', 'a')
      .replaceAll('\u00f6', 'o')
      .replaceAll('\u00fc', 'u')
      .replaceAll('\u00df', 'ss')
      .split(RegExp(r'[^a-z0-9]+'))
      .map((token) => token.trim())
      .where((token) => token.isNotEmpty)
      .toList();
}

String formatDate(DateTime dateTime) {
  final day = dateTime.day.toString().padLeft(2, '0');
  final month = dateTime.month.toString().padLeft(2, '0');
  final year = dateTime.year.toString();

  return '$day.$month.$year';
}

String formatTime(DateTime dateTime) {
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');

  return '$hour:$minute';
}

String formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }

  final kilobytes = bytes / 1024;
  if (kilobytes < 1024) {
    return '${kilobytes.toStringAsFixed(0)} KB';
  }

  final megabytes = kilobytes / 1024;
  return '${megabytes.toStringAsFixed(2)} MB';
}

String slugifyForStorage(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\-]+', unicode: true), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}

String normalizeChecklistTypeForImport(String rawValue) {
  final normalized = rawValue
      .trim()
      .toLowerCase()
      .replaceAll(' ', '')
      .replaceAll('-', '')
      .replaceAll('_', '');

  if (normalized == 'medientrager') {
    return 'Medientrager';
  }
  if (normalized == 'strang') {
    return 'Strang';
  }
  if (normalized == 'strang+seiten' || normalized == 'strangseiten') {
    return 'Strang+Seiten';
  }

  return '';
}
