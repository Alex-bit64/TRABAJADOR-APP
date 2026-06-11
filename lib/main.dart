import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_options.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar Supabase
  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    anonKey: SupabaseOptions.supabaseKey,
  );

  await initializeDateFormatting('es');

  runApp(const AppTrabajador());
}

class AppTrabajador extends StatefulWidget {
  const AppTrabajador({super.key});

  @override
  State<AppTrabajador> createState() => _AppTrabajadorState();
}

class _AppTrabajadorState extends State<AppTrabajador> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark
          ? ThemeMode.light
          : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Marcador de Asistencias',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: LoginScreen(themeMode: _themeMode, onThemeToggle: _toggleTheme),
    );
  }
}
