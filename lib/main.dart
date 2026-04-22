import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';
import 'dart:convert';

import 'core/app_globals.dart';
import 'core/localization.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await loadSavedLanguage();
  syncPendingRegisters();
  runApp(const DHEgoApp());
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
  }

  Future<void> login() async {
    final username = usernameController.text.trim();
    final password = passwordController.text;

    try {
      AuthLoginData? authLogin;

      if (username.contains('@')) {
        await firebaseAuth.signInWithEmailAndPassword(
          email: username,
          password: password,
        );
        authLogin = await fetchAuthLoginData(username);
      } else {
        authLogin = await fetchAuthLoginData(username);
        if (authLogin == null) {
          throw FirebaseAuthException(code: 'user-not-found');
        }

        await firebaseAuth.signInWithEmailAndPassword(
          email: authLogin.email,
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
      currentSessionUsername = authLogin.user.username;
      final resolvedLogin = authLogin;

      if (!mounted) {
        return;
      }

      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => HomeSelectionScreen(
            user: DemoUser(
              username: resolvedLogin.user.username,
              password: '',
              role: resolvedLogin.user.role,
              allowedProjects: resolvedLogin.user.allowedProjectIds,
            ),
          ),
        ),
      );
      return;
    } on FirebaseAuthException {
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

    try {
      final authLogin = await fetchAuthLoginData(identifier);
      final email = identifier.contains('@') ? identifier : authLogin?.email;

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
        child: Padding(
          padding: const EdgeInsets.all(24),
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
              const Spacer(),
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: LanguageButton(
                      flag: '🇩🇪',
                      label: 'DE',
                      selected: language == AppLanguage.de,
                      onTap: () => setAppLanguage(AppLanguage.de),
                    ),
                  ),
                ],
              ),
            ],
          ),
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
    return StreamBuilder<UserRecord?>(
      stream: watchUserByUsername(user.username),
      builder: (context, snapshot) {
        final currentUser = resolveDemoUser(user, snapshot.data);
        final isAdmin = currentUser.role == 'admin';

        return Scaffold(
          appBar: AppBar(
            title: Text('${tr(context, 'welcome')}, ${currentUser.username}'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isAdmin) ...[
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
                            builder: (context) => const AdminDashboardScreen(),
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
                    subtitle: Text(tr(context, 'project_selection_subtitle')),
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
            stream: watchProjects(currentUser.allowedProjects),
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
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'admin_panel'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          AdminProjectsSectionV2(),
          SizedBox(height: 16),
          AdminBuildingsSection(),
          SizedBox(height: 16),
          AdminMaterialsSection(),
          SizedBox(height: 16),
          AdminUsersSectionV2(),
          SizedBox(height: 16),
          AdminRegisterExportsSection(),
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
  const AdminBuildingsSection({super.key});

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
    return AdminSectionCard(
      title: tr(context, 'buildings_tab'),
      addLabel: tr(context, 'add_building'),
      onAdd: () => showBuildingDialog(context),
      onImport: () => showStructureImportDialog(context),
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
              return StreamBuilder<List<WohnungRecord>>(
                stream: watchAllWohnungs(),
                builder: (context, wohnungSnapshot) {
                  final wohnungs = wohnungSnapshot.data ?? <WohnungRecord>[];
                  return StreamBuilder<List<BuildingRecord>>(
                    stream: watchAllBuildings(),
                    builder: (context, snapshot) {
                      final buildings = (snapshot.data ?? <BuildingRecord>[])
                          .where((building) {
                            String? projectName;
                            String? managerName;
                            for (final project in projects) {
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
                          for (final project in projects) {
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
                                ..sort((a, b) => a.name.compareTo(b.name));

                          return ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: const EdgeInsets.only(bottom: 8),
                            title: Text(building.name),
                            subtitle: Text(
                              '${tr(context, 'project_label')}: ${projectName ?? building.projectId}'
                              '\n${tr(context, 'manager')}: ${managerName?.isEmpty ?? true ? '-' : managerName}'
                              '\nWohnungs: ${buildingWohnungs.length}'
                              '${building.active ? '' : '\n${tr(context, 'inactive')}'}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
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
                                    building.active ? 'deactivate' : 'activate',
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => showWohnungDialog(
                                    context,
                                    preselectedBuildingId: building.id,
                                  ),
                                  icon: const Icon(Icons.add_home_outlined),
                                  tooltip: tr(context, 'add_wohnung'),
                                ),
                                IconButton(
                                  onPressed: () => showBuildingDialog(
                                    context,
                                    existingBuilding: building,
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
                                    trailing: IconButton(
                                      onPressed: () => showWohnungDialog(
                                        context,
                                        existingWohnung: wohnung,
                                      ),
                                      icon: const Icon(Icons.edit_outlined),
                                      tooltip: tr(context, 'edit'),
                                    ),
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
      addLabel: tr(context, 'add_material'),
      onAdd: () => showMaterialDialog(context),
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
                      material.active
                          ? tr(context, 'active_label')
                          : tr(context, 'inactive'),
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
    required this.addLabel,
    required this.onAdd,
    required this.child,
    this.onImport,
  });

  final String title;
  final String addLabel;
  final VoidCallback onAdd;
  final Widget child;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        title: Text(title, style: Theme.of(context).textTheme.titleLarge),
        trailing: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (onImport != null)
              OutlinedButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.file_upload_outlined),
                label: Text(tr(context, 'import')),
              ),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: Text(addLabel),
            ),
          ],
        ),
        children: [child],
      ),
    );
  }
}

class AdminProjectsSectionV2 extends StatefulWidget {
  const AdminProjectsSectionV2({super.key});

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
    return AdminSectionCard(
      title: tr(context, 'projects_tab'),
      addLabel: tr(context, 'add_project'),
      onAdd: () => showProjectDialog(context),
      onImport: () => showStructureImportDialog(context),
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
                      final assignedSiteManagers =
                          users
                              .where(
                                (user) =>
                                    user.role == 'site_manager' &&
                                    user.allowedProjectIds.contains(project.id),
                              )
                              .map((user) => user.username)
                              .toList()
                            ..sort();

                      final subtitleLines = <String>[
                        '${tr(context, 'manager')}: ${project.managerName.isEmpty ? '-' : project.managerName}',
                        'Voditelji gradilišta: ${assignedSiteManagers.isEmpty ? '-' : assignedSiteManagers.join(', ')}',
                        '${tr(context, 'assigned_workers')}: ${assignedWorkers.isEmpty ? '-' : assignedWorkers.join(', ')}',
                        if (!project.active) tr(context, 'inactive'),
                      ];

                      return ListTile(
                        title: Text(project.name),
                        subtitle: Text(subtitleLines.join('\n')),
                        isThreeLine: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
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
                            IconButton(
                              onPressed: () => showBuildingDialog(
                                context,
                                preselectedProjectId: project.id,
                              ),
                              icon: const Icon(Icons.add_business_outlined),
                              tooltip: tr(context, 'add_building'),
                            ),
                            IconButton(
                              onPressed: () => showProjectDialog(
                                context,
                                existingProject: project,
                              ),
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: tr(context, 'edit'),
                            ),
                          ],
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
  const AdminUsersSectionV2({super.key});

  @override
  State<AdminUsersSectionV2> createState() => _AdminUsersSectionV2State();
}

class _AdminUsersSectionV2State extends State<AdminUsersSectionV2> {
  final TextEditingController searchController = TextEditingController();
  String query = '';
  String? selectedRoleFilter;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdminSectionCard(
      title: tr(context, 'users_tab'),
      addLabel: tr(context, 'add_user'),
      onAdd: () => showUserDialogV2(context),
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
                value: 'admin',
                child: Text(tr(context, 'role_admin')),
              ),
            ],
            onChanged: (value) => setState(() => selectedRoleFilter = value),
          ),
          const SizedBox(height: 12),
          StreamBuilder<List<ProjectRecord>>(
            stream: watchAllProjects(),
            builder: (context, projectSnapshot) {
              final projects = projectSnapshot.data ?? <ProjectRecord>[];
              return StreamBuilder<List<UserRecord>>(
                stream: watchUsers(),
                builder: (context, userSnapshot) {
                  final users = (userSnapshot.data ?? <UserRecord>[])
                      .where(
                        (user) {
                          final roleMatches =
                              selectedRoleFilter == null ||
                              user.role == selectedRoleFilter;
                          final searchMatches =
                              query.isEmpty ||
                              user.username.toLowerCase().contains(query) ||
                              user.email.toLowerCase().contains(query) ||
                              formatUserRoleLabel(
                                user.role,
                              ).toLowerCase().contains(query);
                          return roleMatches && searchMatches;
                        },
                      )
                      .toList();
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
                        title: Text(user.username),
                        subtitle: Text(
                          '${tr(context, 'role_label')}: ${formatUserRoleLabel(user.role)}\n'
                          '${user.email.isEmpty ? '-' : user.email}'
                          '${user.active ? '' : '\n${tr(context, 'inactive')}'}',
                        ),
                        trailing: IconButton(
                          onPressed: () =>
                              showUserDialogV2(context, existingUser: user),
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

class AdminRegisterExportsSection extends StatefulWidget {
  const AdminRegisterExportsSection({super.key});

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
    return AdminSectionCard(
      title: tr(context, 'register_exports_tab'),
      addLabel: tr(context, 'download_excel'),
      onAdd: () async {
        final submissions = await watchRegisterSubmissions().first;
        final filteredSubmissions = applySubmissionFilters(submissions);
        await downloadRegisterExportExcel(filteredSubmissions);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'excel_download_ready'))),
          );
        }
      },
      child: StreamBuilder<List<ProjectRecord>>(
        stream: watchAllProjects(),
        builder: (context, projectSnapshot) {
          final projects = projectSnapshot.data ?? <ProjectRecord>[];
          return StreamBuilder<List<RegisterSubmissionRecord>>(
            stream: watchRegisterSubmissions(),
            builder: (context, snapshot) {
              final submissions = snapshot.data ?? <RegisterSubmissionRecord>[];
              final filteredSubmissions = applySubmissionFilters(submissions);
              final availableBuildings =
                  submissions
                      .where(
                        (submission) =>
                            selectedProjectName == null ||
                            submission.projectName == selectedProjectName,
                      )
                      .map((submission) => submission.buildingName)
                      .toSet()
                      .toList()
                    ..sort();
              final availableWorkers =
                  submissions
                      .where(
                        (submission) =>
                            (selectedProjectName == null ||
                                submission.projectName ==
                                    selectedProjectName) &&
                            (selectedBuildingName == null ||
                                submission.buildingName ==
                                    selectedBuildingName),
                      )
                      .map((submission) => submission.signedBy)
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
                  ...filteredSubmissions.map(
                    (submission) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${submission.projectName} / ${submission.buildingName} / ${submission.apartmentName}',
                      ),
                      subtitle: Text(
                        '${tr(context, 'signature_time')}: ${formatDateTime(submission.signedAt)}'
                        '\n${tr(context, 'signed_by')}: ${submission.signedBy}',
                      ),
                      trailing: submission.photoCount > 0
                          ? TextButton(
                              onPressed: () => showPhotoGallery(
                                context,
                                photos: submission.photos,
                              ),
                              child: Text(
                                '${tr(context, 'view_photos')} (${submission.photoCount})',
                              ),
                            )
                          : null,
                      isThreeLine: true,
                    ),
                  ),
                  if (filteredSubmissions.isEmpty)
                    ListTile(title: Text(tr(context, 'no_data'))),
                ],
              );
            },
          );
        },
      ),
    );
  }

  List<RegisterSubmissionRecord> applySubmissionFilters(
    List<RegisterSubmissionRecord> submissions,
  ) {
    return submissions.where((submission) {
      final projectMatches =
          selectedProjectName == null ||
          submission.projectName == selectedProjectName;
      final buildingMatches =
          selectedBuildingName == null ||
          submission.buildingName == selectedBuildingName;
      final workerMatches =
          selectedSignedBy == null || submission.signedBy == selectedSignedBy;
      final date = DateTime(
        submission.signedAt.year,
        submission.signedAt.month,
        submission.signedAt.day,
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

  Future<Uint8List?> loadBytes() async {
    final path = photo['path']?.toString() ?? '';
    if (path.isNotEmpty) {
      try {
        return await firebaseStorage.ref(path).getData();
      } catch (_) {}
    }

    final storedUrl = photo['downloadUrl']?.toString() ?? '';
    if (storedUrl.isNotEmpty) {
      try {
        final ref = firebaseStorage.refFromURL(storedUrl);
        return await ref.getData();
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
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
  String? selectedBuilding;
  bool attemptedOrderSubmit = false;

  late final List<OrderLine> orderLines = <OrderLine>[OrderLine()];

  @override
  void dispose() {
    for (final line in orderLines) {
      line.dispose();
    }
    noteController.dispose();
    super.dispose();
  }

  Future<String?> pickMaterial(
    BuildContext context,
    List<String> materials,
  ) async {
    final sortedMaterials = [...materials]..sort(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    final searchController = TextEditingController();
    String query = '';

    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filteredMaterials = sortedMaterials
                .where(
                  (item) =>
                      query.isEmpty ||
                      item.toLowerCase().contains(query.toLowerCase()),
                )
                .toList();

            return AlertDialog(
              title: Text(tr(context, 'item_label')),
              content: SizedBox(
                width: 420,
                height: 420,
                child: Column(
                  children: [
                    TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        labelText: tr(context, 'search'),
                        prefixIcon: const Icon(Icons.search),
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setDialogState(() {
                          query = value.trim();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filteredMaterials.isEmpty
                          ? Center(child: Text(tr(context, 'no_data')))
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: filteredMaterials.length,
                              separatorBuilder: (context, index) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final item = filteredMaterials[index];
                                return ListTile(
                                  title: Text(item),
                                  onTap: () =>
                                      Navigator.of(dialogContext).pop(item),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );

    searchController.dispose();
    return selected;
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

    final validLines = orderLines
        .where(
          (line) =>
              line.itemName != null &&
              line.quantityController.text.trim().isNotEmpty,
        )
        .toList();

    if (validLines.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(context, 'add_item_error'))));
      return;
    }

    final body = StringBuffer()
      ..writeln(tr(context, 'email_greeting'))
      ..writeln()
      ..writeln('${tr(context, 'email_intro')} ${widget.project.name}.')
      ..writeln()
      ..writeln('${tr(context, 'ordered_by')}: ${widget.user.username}')
      ..writeln('${tr(context, 'building')}: $selectedBuilding')
      ..writeln('${tr(context, 'manager')}: ${widget.project.managerName}')
      ..writeln()
      ..writeln('${tr(context, 'requested_material')}:');

    for (final line in validLines) {
      body.writeln(
        '- ${line.itemName}: ${line.quantityController.text.trim()}',
      );
    }

    if (noteController.text.trim().isNotEmpty) {
      body
        ..writeln()
        ..writeln('${tr(context, 'note')}:')
        ..writeln(noteController.text.trim());
    }

    final subject =
        '${widget.user.username} - ${widget.project.name} - $selectedBuilding';
    final emailUri = Uri.parse(
      'mailto:${widget.project.managerEmail}'
      '?subject=${Uri.encodeComponent(subject).replaceAll('+', '%20')}'
      '&body=${Uri.encodeComponent(body.toString()).replaceAll('+', '%20')}',
    );

    final launched = await launchUrl(emailUri);
    if (!mounted) {
      return;
    }

    if (!launched) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(context, 'mail_open_error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.project.name)),
      body: StreamBuilder<List<String>>(
        stream: watchMaterials(),
        builder: (context, materialsSnapshot) {
          final availableItems = materialsSnapshot.data ?? <String>[];

          return Padding(
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
                          widget.project.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${tr(context, 'manager')}: ${widget.project.managerName}',
                        ),
                        Text(
                          '${tr(context, 'email')}: ${widget.project.managerEmail}',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                StreamBuilder<List<BuildingRecord>>(
                  stream: watchBuildings(widget.project.id),
                  builder: (context, snapshot) {
                    final buildings = snapshot.data ?? <BuildingRecord>[];
                    return DropdownButtonFormField<String>(
                      value: selectedBuilding,
                      decoration: InputDecoration(
                        labelText: '${tr(context, 'choose_building')} *',
                        border: const OutlineInputBorder(),
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
                ),
                const SizedBox(height: 12),
                Text(
                  tr(context, 'add_order_items'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    itemCount: orderLines.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final line = orderLines[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              InkWell(
                                onTap: () async {
                                  final selectedMaterial = await pickMaterial(
                                    context,
                                    availableItems,
                                  );
                                  if (selectedMaterial == null || !mounted) {
                                    return;
                                  }
                                  setState(() {
                                    line.itemName = selectedMaterial;
                                  });
                                },
                                child: InputDecorator(
                                  decoration: InputDecoration(
                                    labelText:
                                        '${tr(context, 'item_label')} ${index + 1}',
                                    border: const OutlineInputBorder(),
                                    suffixIcon: const Icon(Icons.search),
                                  ),
                                  child: Text(
                                    line.itemName ?? tr(context, 'search'),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: line.quantityController,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: tr(context, 'quantity'),
                                  border: const OutlineInputBorder(),
                                ),
                              ),
                              if (orderLines.length > 1) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: () {
                                      setState(() {
                                        line.dispose();
                                        orderLines.removeAt(index);
                                      });
                                    },
                                    child: Text(tr(context, 'remove_item')),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() {
                        orderLines.add(OrderLine());
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: Text(tr(context, 'add_more_item')),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: noteController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: tr(context, 'note'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed:
                        selectedBuilding == null || selectedBuilding!.isEmpty
                        ? null
                        : sendOrderEmail,
                    child: Text(tr(context, 'send_order')),
                  ),
                ),
              ],
            ),
          );
        },
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
            stream: watchProjects(currentUser.allowedProjects),
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
                      subtitle: Text(tr(context, 'choose_project')),
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
                    '${tr(context, 'user_label')}: ${user.username}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => ApartmentListScreen(
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

class ApartmentListScreen extends StatelessWidget {
  const ApartmentListScreen({
    super.key,
    required this.project,
    required this.building,
  });

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
                  subtitle: Text(tr(context, 'choose_apartment')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => RegisterEntryScreen(
                          projectName: project.name,
                          buildingName: building.name,
                          apartmentName: wohnung.name,
                          roomName: '',
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

class RegisterEntryScreen extends StatefulWidget {
  const RegisterEntryScreen({
    super.key,
    required this.projectName,
    required this.buildingName,
    required this.apartmentName,
    required this.roomName,
  });

  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;

  @override
  State<RegisterEntryScreen> createState() => _RegisterEntryScreenState();
}

class _RegisterEntryScreenState extends State<RegisterEntryScreen> {
  final TextEditingController registerController = TextEditingController();

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

    final registerAlreadySent =
        submittedRegisterKeys.contains(registerKey) ||
        (await firestore
                .collection('register_submissions')
                .where('registerKey', isEqualTo: registerKey)
                .limit(1)
                .get())
            .docs
            .isNotEmpty;

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
          buildingName: widget.buildingName,
          apartmentName: widget.apartmentName,
          roomName: widget.roomName,
          registerName: registerName,
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
  State<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<ChecklistScreen> {
  final List<ChecklistItem> items = <ChecklistItem>[
    ChecklistItem(titleHr: 'Pregled ulaza', titleDe: 'Eingangskontrolle'),
    ChecklistItem(titleHr: 'Provjera brojila', titleDe: 'Zahlerprufung'),
    ChecklistItem(
      titleHr: 'Fotografiranje stanja',
      titleDe: 'Fotodokumentation',
    ),
    ChecklistItem(
      titleHr: 'Zatvaranje registra',
      titleDe: 'Register schliessen',
    ),
  ];

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
            SizedBox(
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
                      builder: (context) => PhotoDocumentationScreen(
                        projectName: widget.projectName,
                        buildingName: widget.buildingName,
                        apartmentName: widget.apartmentName,
                        roomName: widget.roomName,
                        registerName: widget.registerName,
                      ),
                    ),
                  );
                },
                child: Text(tr(context, 'go_to_signature')),
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
  });

  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String registerName;

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

    final compressedBytes = await FlutterImageCompress.compressWithList(
      originalBytes,
      quality: 75,
      minWidth: 1600,
      minHeight: 1600,
      format: CompressFormat.jpeg,
    );

    final finalBytes = compressedBytes.isEmpty
        ? originalBytes
        : compressedBytes;

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
                              : tr(context, 'mark'),
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
            SizedBox(
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
                      ),
                    ),
                  );
                },
                child: Text(tr(context, 'continue_signature')),
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
  });

  final String projectName;
  final String buildingName;
  final String apartmentName;
  final String roomName;
  final String registerName;
  final List<PhotoItem> photoItems;

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
              onPressed: () {
                Navigator.of(context).pop();
                var popsRemaining = 3;
                while (popsRemaining > 0 && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                  popsRemaining -= 1;
                }
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
    setState(() {
      isSubmitting = true;
    });

    try {
      final uploadedPhotos = await uploadRegisterPhotos(
        registerKey: registerKey,
        signedAt: signedAt,
        photoItems: widget.photoItems,
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
      });
    } on FirebaseException catch (error) {
      final pendingSubmission = PendingRegisterSubmission(
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
      );
      await enqueuePendingRegisterSubmission(pendingSubmission);
      await showRegisterCompletionDialog(
        signedAt: signedAt,
        offlineSaved: true,
      );
      return;
    } catch (_) {
      final pendingSubmission = PendingRegisterSubmission(
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
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.teal, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: GestureDetector(
                    key: signaturePadKey,
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
                    onPressed: isSubmitting ? null : finishRegister,
                    child: Text(tr(context, 'close_register')),
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

List<PendingRegisterSubmission> parsePendingRegisterSubmissions(String rawJson) {
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

Future<void> savePendingRegisterSubmissions(
  List<PendingRegisterSubmission> submissions,
) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    pendingRegisterSubmissionsKey,
    jsonEncode(submissions.map((entry) => entry.toMap()).toList()),
  );
}

Future<void> enqueuePendingRegisterSubmission(
  PendingRegisterSubmission submission,
) async {
  final submissions = await loadPendingRegisterSubmissions();
  submissions.removeWhere((entry) => entry.registerKey == submission.registerKey);
  submissions.add(submission);
  await savePendingRegisterSubmissions(submissions);
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

void ensurePendingRegisterSyncStarted() {
  pendingRegisterSyncTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
    syncPendingRegisters();
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

String _escapeCsvValue(String value) {
  final escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}

Future<void> downloadRegisterExportExcel(
  List<RegisterSubmissionRecord> submissions,
) async {
  final excel = Excel.createExcel();
  final sheet = excel['Potpisi'];

  sheet.appendRow(<CellValue>[
    TextCellValue('Projekt'),
    TextCellValue('Zgrada'),
    TextCellValue('Stan'),
    TextCellValue('Prostorija'),
    TextCellValue('Registar'),
    TextCellValue('Potpisao'),
    TextCellValue('Datum potpisa'),
    TextCellValue('Vrijeme potpisa'),
    TextCellValue('Broj fotografija'),
    TextCellValue('Fotografija registra'),
    TextCellValue('Dodatna fotografija'),
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

  final blob = html.Blob(<dynamic>[
    Uint8List.fromList(bytes),
  ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', 'dhego_potpisi.xlsx')
    ..click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
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

class OrderLine {
  OrderLine({this.itemName}) : quantityController = TextEditingController();

  String? itemName;
  final TextEditingController quantityController;

  void dispose() {
    quantityController.dispose();
  }
}

class UserRecord {
  const UserRecord({
    required this.id,
    required this.username,
    required this.email,
    required this.role,
    required this.active,
    required this.allowedProjectIds,
  });

  final String id;
  final String username;
  final String email;
  final String role;
  final bool active;
  final List<String> allowedProjectIds;
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

class ProjectRecord {
  const ProjectRecord({
    required this.id,
    required this.name,
    required this.managerId,
    required this.managerName,
    required this.managerEmail,
    required this.active,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String managerId;
  final String managerName;
  final String managerEmail;
  final bool active;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class BuildingRecord {
  const BuildingRecord({
    required this.id,
    required this.projectId,
    required this.name,
    required this.active,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String name;
  final bool active;
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
  });

  final String id;
  final String buildingId;
  final String name;
  final bool active;
  final String checklistType;
}

class MaterialRecord {
  const MaterialRecord({
    required this.id,
    required this.name,
    required this.active,
  });

  final String id;
  final String name;
  final bool active;
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
          DateTime.tryParse(map['signedAt']?.toString() ?? '') ?? DateTime.now(),
      registerKey: map['registerKey']?.toString() ?? '',
      photos: (map['photos'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map>()
          .map(
            (photo) => photo.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          )
          .toList(),
    );
  }
}

class DemoUser {
  const DemoUser({
    required this.username,
    required this.password,
    required this.role,
    required this.allowedProjects,
  });

  final String username;
  final String password;
  final String role;
  final List<String> allowedProjects;
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
        return compareDate(b.updatedAt ?? b.createdAt, a.updatedAt ?? a.createdAt);
      case AdminSortOption.updatedOldest:
        return compareDate(a.updatedAt ?? a.createdAt, b.updatedAt ?? b.createdAt);
    }
  });
}

void sortBuildingRecords(List<BuildingRecord> buildings, AdminSortOption option) {
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
        return compareDate(b.updatedAt ?? b.createdAt, a.updatedAt ?? a.createdAt);
      case AdminSortOption.updatedOldest:
        return compareDate(a.updatedAt ?? a.createdAt, b.updatedAt ?? b.createdAt);
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
          managerId: doc.data()['managerId'] as String? ?? '',
          managerName: doc.data()['managerName'] as String? ?? '',
          managerEmail: doc.data()['managerEmail'] as String? ?? '',
          active: doc.data()['active'] as bool? ?? true,
          createdAt: timestampToDateTime(doc.data()['createdAt']),
          updatedAt: timestampToDateTime(doc.data()['updatedAt']),
        ),
      )
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
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
                    createdAt: timestampToDateTime(doc.data()['createdAt']),
                    updatedAt: timestampToDateTime(doc.data()['updatedAt']),
                  ),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name)),
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
              ..sort((a, b) => a.name.compareTo(b.name)),
      );
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
                  ),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name)),
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
                    createdAt: timestampToDateTime(doc.data()['createdAt']),
                    updatedAt: timestampToDateTime(doc.data()['updatedAt']),
                  ),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name)),
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
                  ),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name)),
      );
}

Stream<List<String>> watchMaterials() {
  return firestore
      .collection('materials')
      .where('active', isEqualTo: true)
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs
                .map((doc) => doc.data()['name'] as String? ?? doc.id)
                .toList()
              ..sort(),
      );
}

Stream<List<MaterialRecord>> watchAllMaterials() {
  return firestore
      .collection('materials')
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs
                .map(
                  (doc) => MaterialRecord(
                    id: doc.id,
                    name: doc.data()['name'] as String? ?? doc.id,
                    active: doc.data()['active'] as bool? ?? true,
                  ),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name)),
      );
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
                photoCount: doc.data()['photoCount'] as int? ?? 0,
                photos: (doc.data()['photos'] as List<dynamic>? ?? <dynamic>[])
                    .whereType<Map<dynamic, dynamic>>()
                    .map(
                      (photo) => photo.map(
                        (key, value) => MapEntry(key.toString(), value),
                      ),
                    )
                    .toList(),
              ),
            )
            .toList(),
      );
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
                    email: doc.data()['email'] as String? ?? '',
                    role: doc.data()['role'] as String? ?? 'worker',
                    active: doc.data()['active'] as bool? ?? true,
                    allowedProjectIds:
                        (doc.data()['allowedProjectIds'] as List<dynamic>? ??
                                <dynamic>[])
                            .map((item) => item.toString())
                            .toList(),
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
          email: doc.data()['email'] as String? ?? '',
          role: doc.data()['role'] as String? ?? 'worker',
          active: doc.data()['active'] as bool? ?? true,
          allowedProjectIds:
              (doc.data()['allowedProjectIds'] as List<dynamic>? ?? <dynamic>[])
                  .map((item) => item.toString())
                  .toList(),
        );
      });
}

Future<AuthLoginData?> fetchAuthLoginData(String identifier) async {
  final normalizedIdentifier = identifier.trim();
  if (normalizedIdentifier.isEmpty) {
    return null;
  }

  QuerySnapshot<Map<String, dynamic>> snapshot;
  if (normalizedIdentifier.contains('@')) {
    snapshot = await firestore
        .collection('users')
        .where('email', isEqualTo: normalizedIdentifier)
        .limit(1)
        .get();
  } else {
    snapshot = await firestore
        .collection('users')
        .where('username', isEqualTo: normalizedIdentifier)
        .limit(1)
        .get();
  }

  if (snapshot.docs.isEmpty) {
    final directDoc = await firestore
        .collection('users')
        .doc(normalizedIdentifier)
        .get();
    if (!directDoc.exists) {
      return null;
    }

    final data = directDoc.data();
    final email = data?['email'] as String? ?? '';
    if (email.isEmpty) {
      return null;
    }

    return AuthLoginData(
      email: email,
      user: UserRecord(
        id: directDoc.id,
        username: data?['username'] as String? ?? directDoc.id,
        email: email,
        role: data?['role'] as String? ?? 'worker',
        active: data?['active'] as bool? ?? true,
        allowedProjectIds:
            (data?['allowedProjectIds'] as List<dynamic>? ?? <dynamic>[])
                .map((item) => item.toString())
                .toList(),
      ),
    );
  }

  final doc = snapshot.docs.first;
  final email = doc.data()['email'] as String? ?? '';
  if (email.isEmpty) {
    return null;
  }

  return AuthLoginData(
    email: email,
    user: UserRecord(
      id: doc.id,
      username: doc.data()['username'] as String? ?? doc.id,
      email: email,
      role: doc.data()['role'] as String? ?? 'worker',
      active: doc.data()['active'] as bool? ?? true,
      allowedProjectIds:
          (doc.data()['allowedProjectIds'] as List<dynamic>? ?? <dynamic>[])
              .map((item) => item.toString())
              .toList(),
    ),
  );
}

Future<void> createFirebaseUserAccount({
  required String id,
  required String username,
  required String email,
  required String password,
  required String role,
  required bool active,
  required List<String> allowedProjectIds,
}) async {
  final callable = firebaseFunctions.httpsCallable('createUserAccount');
  await callable.call(<String, dynamic>{
    'id': id,
    'username': username,
    'email': email,
    'password': password,
    'role': role,
    'active': active,
    'allowedProjectIds': allowedProjectIds,
  });
}

Future<void> updateFirebaseUserAccount({
  required String id,
  required String username,
  required String email,
  required String role,
  required bool active,
  required List<String> allowedProjectIds,
}) async {
  final callable = firebaseFunctions.httpsCallable('updateUserAccount');
  await callable.call(<String, dynamic>{
    'id': id,
    'username': username,
    'email': email,
    'role': role,
    'active': active,
    'allowedProjectIds': allowedProjectIds,
  });
}

Future<void> showProjectDialog(
  BuildContext context, {
  ProjectRecord? existingProject,
}) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  var active = existingProject?.active ?? true;
  final users = await watchUsers().first;
  final siteManagers =
      <String, UserRecord>{
        for (final user in users)
          if (user.role == 'site_manager' && user.active) user.id: user,
      }.values.toList()
        ..sort((a, b) => a.username.compareTo(b.username));
  final workerSelections = <String, bool>{};
  final siteManagerSelections = <String, bool>{};
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
  for (final user in users.where((user) => user.role == 'site_manager')) {
    siteManagerSelections[user.id] =
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
                      initialValue: selectedManagerId,
                      decoration: InputDecoration(
                        labelText: tr(context, 'select_site_manager'),
                        border: const OutlineInputBorder(),
                      ),
                      items: siteManagers
                          .map(
                            (manager) => DropdownMenuItem<String>(
                              value: manager.id,
                              child: Text('${manager.username} (${manager.email})'),
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
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Voditelji gradilišta',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Column(
                          children: users
                              .where((user) => user.role == 'site_manager')
                              .fold<Map<String, UserRecord>>(
                                <String, UserRecord>{},
                                (map, user) {
                                  map[user.id] = user;
                                  return map;
                                },
                              )
                              .values
                              .map(
                                (user) => CheckboxListTile(
                                  value: siteManagerSelections[user.id] ?? false,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(user.username),
                                  onChanged: (value) {
                                    setState(() {
                                      siteManagerSelections[user.id] =
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
                    'managerId': selectedManager?.id ?? '',
                    'managerName': selectedManager?.username ?? '',
                    'managerEmail': selectedManager?.email ?? '',
                    'active': active,
                    'createdAt': existingProject?.createdAt != null
                        ? Timestamp.fromDate(existingProject!.createdAt!)
                        : now,
                    'updatedAt': now,
                  });
                  final selectedWorkerIds = workerSelections.entries
                      .where((entry) => entry.value)
                      .map((entry) => entry.key)
                      .toSet();
                  final selectedSiteManagerIds = siteManagerSelections.entries
                      .where((entry) => entry.value)
                      .map((entry) => entry.key)
                      .toSet();

                  for (final user in users.where(
                    (user) => user.role == 'worker' || user.role == 'site_manager',
                  )) {
                    final updatedProjects = <String>{...user.allowedProjectIds};

                    if (selectedWorkerIds.contains(user.id) ||
                        selectedSiteManagerIds.contains(user.id)) {
                      updatedProjects.add(projectId);
                    } else {
                      updatedProjects.remove(projectId);
                    }

                    await firestore.collection('users').doc(user.id).set({
                      'username': user.username,
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
}) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  String? selectedProjectId =
      existingBuilding?.projectId ?? preselectedProjectId;
  var active = existingBuilding?.active ?? true;
  final projects = await watchAllProjects().first;

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
}) async {
  final idController = TextEditingController();
  final nameController = TextEditingController();
  String? selectedBuildingId =
      existingWohnung?.buildingId ?? preselectedBuildingId;
  var active = existingWohnung?.active ?? true;
  final buildings = await watchAllBuildings().first;

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
                  _dialogField(
                    emailController,
                    tr(context, 'email'),
                  ),
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
}) async {
  final idController = TextEditingController();
  final usernameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  var selectedRole = existingUser?.role ?? 'worker';
  var active = existingUser?.active ?? true;
  final projects = await watchAllProjects().first;
  final projectSelections = <String, bool>{};

  if (existingUser != null) {
    idController.text = existingUser.id;
    usernameController.text = existingUser.username;
    emailController.text = existingUser.email;
  }

  for (final project in projects) {
    projectSelections[project.id] =
        existingUser?.allowedProjectIds.contains(project.id) ?? false;
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
                    _dialogField(
                      emailController,
                      tr(context, 'email'),
                    ),
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
                    DropdownButtonFormField<String>(
                      initialValue: selectedRole,
                      decoration: InputDecoration(
                        labelText: tr(context, 'role_label'),
                        border: const OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'worker',
                          child: Text('radnik'),
                        ),
                        DropdownMenuItem(
                          value: 'site_manager',
                          child: Text('voditelj gradilišta'),
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
                  final allowedProjectIds =
                      projectSelections.entries
                          .where((entry) => entry.value)
                          .map((entry) => entry.key)
                          .toList()
                        ..sort();

                  try {
                    if (existingUser == null) {
                      await createFirebaseUserAccount(
                        id: idController.text.trim(),
                        username: usernameController.text.trim(),
                        email: emailController.text.trim(),
                        password: passwordController.text,
                        role: selectedRole,
                        active: active,
                        allowedProjectIds: allowedProjectIds,
                      );
                    } else {
                      await updateFirebaseUserAccount(
                        id: idController.text.trim(),
                        username: usernameController.text.trim(),
                        email: emailController.text.trim(),
                        role: selectedRole,
                        active: active,
                        allowedProjectIds: allowedProjectIds,
                      );
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
                  } catch (_) {
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
    required this.assignedUsers,
    required this.unmatchedUsers,
  });

  final int projects;
  final int buildings;
  final int wohnungs;
  final int assignedUsers;
  final List<String> unmatchedUsers;
}

Future<void> showStructureImportDialog(BuildContext context) async {
  final controller = TextEditingController();
  DropzoneViewController? dropzoneController;
  var isDragging = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> loadImportedText(String? importedText) async {
            if (importedText == null || importedText.trim().isEmpty) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      tr(context, 'file_import_not_supported'),
                    ),
                  ),
                );
              }
              return;
            }

            controller.text = importedText;
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                SnackBar(content: Text(tr(context, 'file_loaded'))),
              );
            }
          }

          return AlertDialog(
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          await loadImportedText(
                            await pickStructureImportFileText(),
                          );
                        },
                        icon: const Icon(Icons.upload_file_outlined),
                        label: Text(tr(context, 'upload_file')),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => downloadStructureImportTemplate(
                          LanguageScope.of(context),
                        ),
                        icon: const Icon(Icons.download_outlined),
                        label: Text(tr(context, 'download_template')),
                      ),
                    ],
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
                          color: isDragging ? Colors.teal : Colors.grey.shade400,
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
                              setState(() => isDragging = false);
                              final controller = dropzoneController;
                              if (controller == null) {
                                return;
                              }
                              final fileName = await controller.getFilename(file);
                              final bytes = await controller.getFileData(file);
                              await loadImportedText(
                                parseStructureImportBytes(fileName, bytes),
                              );
                            },
                          ),
                          Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.file_upload_outlined,
                                  color: isDragging ? Colors.teal : Colors.grey,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  tr(context, 'drop_file_here'),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    minLines: 12,
                    maxLines: 20,
                    decoration: InputDecoration(
                      labelText: tr(context, 'paste_table'),
                      hintText: tr(context, 'import_placeholder'),
                      border: const OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton.icon(
                onPressed: () async {
                  final summary = await importStructureData(controller.text);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (!context.mounted) {
                    return;
                  }

                  final message = StringBuffer(tr(context, 'import_success'))
                    ..write(
                      ' (${summary.projects} projekata, ${summary.buildings} zgrada, ${summary.wohnungs} stanova)',
                    );
                  if (summary.assignedUsers > 0) {
                    message.write(', korisnici: ${summary.assignedUsers}');
                  }
                  if (summary.unmatchedUsers.isNotEmpty) {
                    message.write(
                      '\nNeprepoznati korisnici: ${summary.unmatchedUsers.join(', ')}',
                    );
                  }
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(message.toString())));
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

Future<String?> pickStructureImportFileText() async {
  final uploadInput = html.FileUploadInputElement()
    ..accept = '.xlsx,.csv,.txt'
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
  return parseStructureImportBytes(fileName, bytes);
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

String convertExcelToImportText(Excel excel) {
  final lines = <String>[];

  for (final table in excel.tables.values) {
    for (final row in table.rows) {
      final values = row
          .map((cell) => cell?.value?.toString().trim() ?? '')
          .toList();
      final line = values.join('\t').trimRight();
      if (line.trim().isNotEmpty) {
        lines.add(line);
      }
    }
    if (lines.isNotEmpty) {
      break;
    }
  }

  return lines.join('\n');
}

String? parseStructureImportBytes(String fileName, Uint8List bytes) {
  final normalizedName = fileName.toLowerCase();

  if (normalizedName.endsWith('.xlsx')) {
    try {
      final excel = Excel.decodeBytes(bytes);
      final text = convertExcelToImportText(excel);
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  if (normalizedName.endsWith('.csv') || normalizedName.endsWith('.txt')) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.trim().isEmpty ? null : text;
  }

  return null;
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

Future<StructureImportSummary> importStructureData(String rawText) async {
  final lines = rawText
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  final projects = <String, String>{};
  final buildings = <String, Map<String, String>>{};
  final wohnungs = <String, Map<String, String>>{};
  final projectAssignments = <String, Set<String>>{};

  for (final line in lines) {
    final columns = line.contains('\t')
        ? line.split('\t')
        : line.split(',');
    if (columns.length < 3) {
      continue;
    }

    final projectName = columns[0].trim();
    final buildingName = columns[1].trim();
    final wohnungName = columns[2].trim();
    final workersRaw = columns.length > 3 ? columns[3].trim() : '';
    final checklistTypeRaw = columns.length > 4 ? columns[4].trim() : '';

    if (projectName.isEmpty || buildingName.isEmpty || wohnungName.isEmpty) {
      continue;
    }

    final lowerHeader = [
      projectName.toLowerCase(),
      buildingName.toLowerCase(),
      wohnungName.toLowerCase(),
    ];
    if (lowerHeader[0].contains('projekt') &&
        lowerHeader[1].contains('zgrada')) {
      continue;
    }

    final projectId = generateImportDocumentId(projectName);
    final buildingId =
        '${projectId}_${generateImportDocumentId(buildingName)}';
    final wohnungId =
        '${buildingId}_${generateImportDocumentId(wohnungName)}';

    projects[projectId] = projectName;
    buildings[buildingId] = <String, String>{
      'projectId': projectId,
      'name': buildingName,
    };
    wohnungs[wohnungId] = <String, String>{
      'buildingId': buildingId,
      'name': wohnungName,
      'checklistType': normalizeChecklistTypeForImport(checklistTypeRaw),
    };

    final workerNames = workersRaw
        .split(';')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    if (workerNames.isNotEmpty) {
      projectAssignments.putIfAbsent(projectId, () => <String>{}).addAll(
        workerNames,
      );
    }
  }

  for (final entry in projects.entries) {
    final now = Timestamp.now();
    await firestore.collection('projects').doc(entry.key).set({
      'name': entry.value,
      'active': true,
      'createdAt': now,
      'updatedAt': now,
    }, SetOptions(merge: true));
  }

  for (final entry in buildings.entries) {
    final now = Timestamp.now();
    await firestore.collection('buildings').doc(entry.key).set({
      'projectId': entry.value['projectId'],
      'name': entry.value['name'],
      'active': true,
      'createdAt': now,
      'updatedAt': now,
    }, SetOptions(merge: true));
  }

  for (final entry in wohnungs.entries) {
    await firestore.collection('wohnungs').doc(entry.key).set({
      'buildingId': entry.value['buildingId'],
      'name': entry.value['name'],
      'active': true,
      'checklistType': entry.value['checklistType'] ?? '',
    }, SetOptions(merge: true));
  }

  final users = await watchUsers().first;
  final userLookup = <String, UserRecord>{};
  final userCandidates = <String, List<UserRecord>>{};
  for (final user in users) {
    final keys = <String>{
      normalizeImportUserKey(user.id),
      normalizeImportUserKey(user.username),
    };
    if (user.email.isNotEmpty) {
      keys.add(normalizeImportUserKey(user.email));
    }
    keys.addAll(splitImportUserTokens(user.id));
    keys.addAll(splitImportUserTokens(user.username));

    for (final key in keys.where((key) => key.isNotEmpty)) {
      userLookup.putIfAbsent(key, () => user);
      userCandidates.putIfAbsent(key, () => <UserRecord>[]).add(user);
    }
  }

  var assignedUsers = 0;
  final unmatchedUsers = <String>{};

  for (final assignment in projectAssignments.entries) {
    for (final rawUser in assignment.value) {
      final normalized = normalizeImportUserKey(rawUser);
      UserRecord? user = userLookup[normalized];
      if (user == null) {
        final candidates = userCandidates[normalized] ?? <UserRecord>[];
        if (candidates.length == 1) {
          user = candidates.first;
        }
      }
      if (user == null) {
        final tokenMatches = splitImportUserTokens(rawUser)
            .expand((token) => userCandidates[token] ?? <UserRecord>[])
            .map((candidate) => candidate.id)
            .toSet()
            .toList();
        if (tokenMatches.length == 1) {
          user = users.firstWhere((candidate) => candidate.id == tokenMatches.first);
        }
      }
      if (user == null) {
        unmatchedUsers.add(rawUser);
        continue;
      }

      final updatedProjects = <String>{...user.allowedProjectIds}
        ..add(assignment.key);
      await firestore.collection('users').doc(user.id).set({
        'allowedProjectIds': updatedProjects.toList()..sort(),
      }, SetOptions(merge: true));
      assignedUsers++;
    }
  }

  return StructureImportSummary(
    projects: projects.length,
    buildings: buildings.length,
    wohnungs: wohnungs.length,
    assignedUsers: assignedUsers,
    unmatchedUsers: unmatchedUsers.toList()..sort(),
  );
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
    case 'admin':
      return 'admin';
    default:
      return role;
  }
}

String formatDateTime(DateTime dateTime) {
  final day = dateTime.day.toString().padLeft(2, '0');
  final month = dateTime.month.toString().padLeft(2, '0');
  final year = dateTime.year.toString();
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');

  return '$day.$month.$year $hour:$minute';
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

