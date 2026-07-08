import 'package:flutter/material.dart';

import 'router.dart';

class ClimbTopoApp extends StatelessWidget {
  const ClimbTopoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ClimbTopo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32), // deep green — climbing vibes
        ),
      ),
      routerConfig: appRouter,
    );
  }
}
