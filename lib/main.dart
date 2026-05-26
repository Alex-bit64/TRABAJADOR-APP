import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:firebase_core/firebase_core.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();

  await initializeDateFormatting('es');

  runApp(const AppTrabajador());
}

class AppTrabajador extends StatelessWidget {
  const AppTrabajador({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Almacen de Remates',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(primary: Color(0xFFE63232)),
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
      ),
      home: const LoginScreen(),
    );
  }
}
