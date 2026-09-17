import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_options.dart';
import 'screens/login_screen.dart';
import 'screens/app_update_gate.dart';
import 'services/local_database_service.dart';
import 'services/theme_preference_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Inicializar Supabase
  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    anonKey: SupabaseOptions.supabaseKey,
  );

  await LocalDatabaseService.instance.inicializar();

  await initializeDateFormatting('es');

  final themeMode = await ThemePreferenceService().cargar();
  runApp(AppTrabajador(initialThemeMode: themeMode));
}

class AppTrabajador extends StatefulWidget {
  final ThemeMode initialThemeMode;

  const AppTrabajador({super.key, this.initialThemeMode = ThemeMode.dark});

  @override
  State<AppTrabajador> createState() => _AppTrabajadorState();
}

class _AppTrabajadorState extends State<AppTrabajador> {
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialThemeMode;
  }

  Future<void> _toggleTheme() async {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark
          ? ThemeMode.light
          : ThemeMode.dark;
    });
    await ThemePreferenceService().guardar(_themeMode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Marcador de Asistencias',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: AppUpdateGate(
        child: LoginScreen(themeMode: _themeMode, onThemeToggle: _toggleTheme),
      ),
    );
  }
}
